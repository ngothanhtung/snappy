import Foundation

/// What the uninstaller knows about an installed app.
public struct AppIdentity: Equatable, Sendable {
    public var bundleID: String
    public var name: String
    /// Code-signing team (e.g. "UBF8T346G9"); nil for unsigned/ad-hoc apps.
    public var teamID: String?
    /// Bundle IDs of helpers/extensions shipped inside the app
    /// (e.g. `com.foo.app.widget`); their data belongs to the app too.
    public var embeddedBundleIDs: Set<String>

    public init(bundleID: String, name: String, teamID: String? = nil,
                embeddedBundleIDs: Set<String> = []) {
        self.bundleID = bundleID
        self.name = name
        self.teamID = teamID
        self.embeddedBundleIDs = embeddedBundleIDs
    }
}

/// A folder under ~/Library that apps leave data in, and how to match it.
public struct LeftoverLocation: Equatable, Sendable {
    /// Path relative to ~/Library, e.g. "Application Support".
    public let path: String
    public let title: String
    /// Whether a folder named exactly like the app (e.g. "Slack") counts.
    public let matchesAppName: Bool
    /// Whether vendor-shared items (team ID prefix, `*.bundleID` suffix) count.
    public let matchesGroups: Bool

    public init(path: String, title: String, matchesAppName: Bool = false,
                matchesGroups: Bool = false) {
        self.path = path
        self.title = title
        self.matchesAppName = matchesAppName
        self.matchesGroups = matchesGroups
    }
}

/// How sure we are that an item belongs to the app being removed.
public enum LeftoverMatch: Equatable, Sendable {
    /// Named after the app's (or an embedded helper's) bundle ID — ticked.
    case bundleID
    /// Named after the app's display name — ticked.
    case appName
    /// Starts with the app's bundle ID but isn't a bundled helper (e.g.
    /// `com.google.chrome.for.testing`) — likely related, but may be a
    /// different product, so it starts unticked.
    case relatedBundleID
    /// Under the developer's team prefix, not obviously this app's — unticked.
    case sharedWithVendor

    public var isSelectedByDefault: Bool {
        switch self {
        case .bundleID, .appName:                 return true
        case .relatedBundleID, .sharedWithVendor: return false
        }
    }
}

/// Why an app can't be uninstalled by Snappy.
public enum UninstallRefusal: Equatable, Sendable {
    case notAnApp
    case systemApp
    case outsideApplicationsFolders
    case snappyItself

    public var message: String {
        switch self {
        case .notAnApp:                   return "This isn't an app bundle."
        case .systemApp:                  return "Apple system apps can't be removed."
        case .outsideApplicationsFolders: return "Only apps in /Applications or ~/Applications can be removed."
        case .snappyItself:               return "Snappy can't uninstall itself."
        }
    }
}

/// Pure rules for finding and safely removing an app's leftover files.
public enum AppLeftoverRules {

    /// Places under ~/Library searched for an app's data.
    public static let locations: [LeftoverLocation] = [
        .init(path: "Application Support", title: "Application Support", matchesAppName: true),
        .init(path: "Caches", title: "Caches", matchesAppName: true),
        .init(path: "Preferences", title: "Preferences"),
        .init(path: "Preferences/ByHost", title: "Preferences (ByHost)"),
        .init(path: "Saved Application State", title: "Saved Application State"),
        .init(path: "Containers", title: "Containers"),
        .init(path: "Group Containers", title: "Group Containers", matchesGroups: true),
        .init(path: "Application Scripts", title: "Application Scripts", matchesGroups: true),
        .init(path: "Logs", title: "Logs", matchesAppName: true),
        .init(path: "HTTPStorages", title: "HTTP Storage"),
        .init(path: "WebKit", title: "WebKit Data"),
        .init(path: "Cookies", title: "Cookies"),
        .init(path: "LaunchAgents", title: "Launch Agents"),
    ]

    /// Folder names too generic to treat as "belongs to this app".
    static let genericNames: Set<String> = [
        "adobe", "apple", "google", "microsoft", "mozilla", "jetbrains", "oracle",
        "cache", "caches", "data", "logs", "temp", "tmp", "default", "app", "helper",
    ]

    /// Extensions apps add to their bundle ID in these folders.
    static let knownSuffixes = [".plist", ".savedState", ".binarycookies"]

    /// Whether `name` (an entry directly inside `location`) belongs to `app`.
    /// `otherBundleIDs` are the other installed apps, so `com.foo.app` never
    /// claims the data of a separately installed `com.foo.app.beta`.
    /// `otherTeamIDs` are their signing teams: vendor-shared items are only
    /// offered when no other installed app from that developer may use them.
    public static func match(name: String, in location: LeftoverLocation, app: AppIdentity,
                             otherBundleIDs: Set<String> = [],
                             otherTeamIDs: Set<String> = []) -> LeftoverMatch? {
        let bundle = app.bundleID.lowercased()
        guard !bundle.isEmpty else { return nil }
        var stem = name.lowercased()
        for suffix in knownSuffixes where stem.hasSuffix(suffix.lowercased()) {
            stem = String(stem.dropLast(suffix.count))
        }

        // Group-style folders: "TEAMID.<id>", "group.<id>", "TEAMID.group.<id>".
        var underTeamPrefix = false
        let team = app.teamID?.lowercased() ?? ""
        if location.matchesGroups {
            if !team.isEmpty, stem.hasPrefix(team + ".") {
                stem = String(stem.dropFirst(team.count + 1))
                underTeamPrefix = true
            }
            if stem.hasPrefix("group.") { stem = String(stem.dropFirst("group.".count)) }
        }

        if stem == bundle { return .bundleID }
        // Bundled components named under the app's own ID are the app's; ones
        // from elsewhere (a vendor updater, Sparkle…) are often shared by
        // other apps that embed the same component, so they start unticked.
        for id in app.embeddedBundleIDs.map({ $0.lowercased() })
        where stem == id || stem.hasPrefix(id + ".") {
            return id.hasPrefix(bundle + ".") ? .bundleID : .relatedBundleID
        }
        if stem.hasPrefix(bundle + ".") {
            return claimedByOtherApp(stem, bundle: bundle, others: otherBundleIDs)
                ? nil : .relatedBundleID
        }
        if underTeamPrefix {
            let vendorShared = otherTeamIDs.contains { $0.lowercased() == team }
            return vendorShared ? nil : .sharedWithVendor
        }
        if location.matchesAppName, isDistinctiveName(app.name),
           stem == app.name.lowercased().trimmingCharacters(in: .whitespaces) {
            return .appName
        }
        return nil
    }

    /// Vendor/app folder pairs to look for one level down, e.g. "Google
    /// Chrome" keeps its data in "Application Support/Google/Chrome".
    public static func nestedFolderCandidates(appName: String) -> [(vendor: String, child: String)] {
        let words = appName.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 2, words[0].count >= 3 else { return [] }
        let rest = words.dropFirst().joined(separator: " ")
        let full = words.joined(separator: " ")
        return [rest, full].filter(isDistinctiveName).map { (words[0], $0) }
    }

    static func isDistinctiveName(_ name: String) -> Bool {
        let lower = name.lowercased().trimmingCharacters(in: .whitespaces)
        return lower.count >= 3 && !genericNames.contains(lower)
    }

    private static func claimedByOtherApp(_ stem: String, bundle: String,
                                          others: Set<String>) -> Bool {
        others.contains { other in
            let o = other.lowercased()
            return o != bundle && o.hasPrefix(bundle + ".")
                && (stem == o || stem.hasPrefix(o + "."))
        }
    }

    /// Whether Snappy may uninstall the app at `appURL`; nil means it may.
    public static func refusal(appURL: URL, bundleID: String, home: URL,
                               ownBundleID: String?) -> UninstallRefusal? {
        let url = appURL.standardizedFileURL
        guard url.pathExtension.lowercased() == "app" else { return .notAnApp }
        if let own = ownBundleID, own.caseInsensitiveCompare(bundleID) == .orderedSame {
            return .snappyItself
        }
        if bundleID.lowercased().hasPrefix("com.apple.") || url.path.hasPrefix("/System/") {
            return .systemApp
        }
        let roots = applicationFolders(home: home)
        guard roots.contains(where: { JunkSafety.isStrictlyInside(url, root: $0) }) else {
            return .outsideApplicationsFolders
        }
        return nil
    }

    public static func applicationFolders(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         home.appendingPathComponent("Applications", isDirectory: true)]
    }

    public static func locationURL(_ location: LeftoverLocation, home: URL) -> URL {
        home.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(location.path, isDirectory: true)
    }

    /// The final gate before removing `url` during an uninstall: it must be
    /// the app bundle itself, or strictly inside one of the leftover folders.
    public static func isRemovable(_ url: URL, appURL: URL, home: URL) -> Bool {
        if url.standardizedFileURL == appURL.standardizedFileURL { return true }
        return locations.contains {
            JunkSafety.isStrictlyInside(url, root: locationURL($0, home: home))
        }
    }
}
