import AppKit
import Security
import SnappyCore

/// An app found in /Applications or ~/Applications that Snappy may remove.
struct InstalledApp: Identifiable, Sendable {
    let url: URL
    let bundleID: String
    let name: String
    let version: String?
    var bytes: Int64?

    var id: String { url.path }
}

struct UninstallResult: Sendable {
    var removedCount = 0
    var freedBytes: Int64 = 0
    var skippedCount = 0
    var failures: [String] = []
}

/// Finds installed apps and their leftovers, and removes them. Blocking file
/// I/O — call off the main thread. Every removal is checked against
/// `AppLeftoverRules.isRemovable` immediately beforehand.
enum AppUninstaller {

    private static let fm = FileManager.default

    // MARK: - Installed apps

    /// Removable apps (Apple system apps and Snappy itself are left out),
    /// sorted by name. Sizes are filled in separately (`size(of:)`).
    static func installedApps(ownBundleID: String?) -> [InstalledApp] {
        let home = fm.homeDirectoryForCurrentUser
        var apps: [String: InstalledApp] = [:]
        for root in AppLeftoverRules.applicationFolders(home: home) {
            guard let walker = fm.enumerator(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                // Apps live at the top level or one folder down (e.g. Utilities).
                if walker.level > 2 { walker.skipDescendants(); continue }
                guard url.pathExtension.lowercased() == "app",
                      (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                        .isSymbolicLink != true,
                      let bundle = Bundle(url: url),
                      let bundleID = bundle.bundleIdentifier,
                      AppLeftoverRules.refusal(appURL: url, bundleID: bundleID, home: home,
                                               ownBundleID: ownBundleID) == nil else { continue }
                let info = bundle.infoDictionary ?? [:]
                let name = (info["CFBundleDisplayName"] as? String)
                    ?? (info["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                apps[url.path] = InstalledApp(
                    url: url, bundleID: bundleID,
                    name: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name,
                    version: info["CFBundleShortVersionString"] as? String)
            }
        }
        return apps.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func size(of url: URL) -> Int64 { JunkScanner.allocatedSize(of: url) }

    /// The code-signing team ID, used to spot data shared by one developer's apps.
    static func teamID(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Bundle IDs of helpers, extensions and XPC services shipped inside the
    /// app (e.g. widgets, login items); their data belongs to the app.
    static func embeddedBundleIDs(of appURL: URL) -> Set<String> {
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        var ids = Set<String>()
        for folder in ["PlugIns", "Library", "XPCServices", "Helpers", "MacOS", "Frameworks"] {
            guard let walker = fm.enumerator(
                at: contents.appendingPathComponent(folder, isDirectory: true),
                includingPropertiesForKeys: nil,
                options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                if walker.level > 6 { walker.skipDescendants(); continue }
                guard ["app", "appex", "xpc", "systemextension"]
                        .contains(url.pathExtension.lowercased()),
                      let id = Bundle(url: url)?.bundleIdentifier else { continue }
                ids.insert(id)
            }
        }
        return ids
    }

    // MARK: - Leftovers

    /// One `.contents` node per ~/Library folder that holds data for `app`
    /// (ticking it removes the matched items, never the folder itself).
    /// Items that may belong to something else start unticked.
    static func leftovers(for app: InstalledApp, otherApps: [InstalledApp]) -> [JunkNode] {
        let home = fm.homeDirectoryForCurrentUser
        let identity = AppIdentity(bundleID: app.bundleID, name: app.name,
                                   teamID: teamID(of: app.url),
                                   embeddedBundleIDs: embeddedBundleIDs(of: app.url))
        let otherBundleIDs = Set(otherApps.map(\.bundleID))
        // Only needed to decide whether vendor-shared data is still in use.
        let otherTeamIDs: Set<String> = identity.teamID == nil
            ? [] : Set(otherApps.compactMap { teamID(of: $0.url) })

        var sections: [JunkNode] = []
        for location in AppLeftoverRules.locations {
            let folder = AppLeftoverRules.locationURL(location, home: home)
            guard let entries = try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []) else { continue }
            var items: [JunkNode] = entries.compactMap { url in
                AppLeftoverRules.match(name: url.lastPathComponent, in: location, app: identity,
                                       otherBundleIDs: otherBundleIDs,
                                       otherTeamIDs: otherTeamIDs)
                    .map { node(for: url, selected: $0.isSelectedByDefault) }
            }
            if location.matchesAppName {
                items += nestedAppFolders(in: entries, appName: app.name)
                    .filter { found in !items.contains { $0.url == found } }
                    .map { node(for: $0, selected: true) }
            }
            guard !items.isEmpty else { continue }
            sections.append(JunkNode(url: folder, isDirectory: true, bytes: 0,
                                     removal: .contents, children: items))
        }
        return sections
    }

    /// e.g. "Application Support/Google/Chrome" for "Google Chrome".
    private static func nestedAppFolders(in entries: [URL], appName: String) -> [URL] {
        var found: [URL] = []
        for candidate in AppLeftoverRules.nestedFolderCandidates(appName: appName) {
            guard let vendor = entries.first(where: {
                $0.lastPathComponent.caseInsensitiveCompare(candidate.vendor) == .orderedSame
            }), let inner = try? fm.contentsOfDirectory(at: vendor, includingPropertiesForKeys: nil,
                                                        options: []) else { continue }
            found += inner.filter {
                $0.lastPathComponent.caseInsensitiveCompare(candidate.child) == .orderedSame
            }
        }
        return found
    }

    private static func node(for url: URL, selected: Bool) -> JunkNode {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let isRealDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
        return JunkNode(url: url, isDirectory: isRealDirectory,
                        bytes: JunkScanner.allocatedSize(of: url), isSelected: selected)
    }

    // MARK: - Remove

    /// Moves each path to the Trash. The app bundle falls back to Finder when
    /// it isn't writable (e.g. installed by a .pkg), so macOS can ask for an
    /// administrator password the same way dragging it to the Trash does.
    static func remove(_ items: [(url: URL, bytes: Int64)], appURL: URL) -> UninstallResult {
        let home = fm.homeDirectoryForCurrentUser
        var result = UninstallResult()
        for item in items {
            guard AppLeftoverRules.isRemovable(item.url, appURL: appURL, home: home) else {
                result.skippedCount += 1
                continue
            }
            do {
                try fm.trashItem(at: item.url, resultingItemURL: nil)
                result.removedCount += 1
                result.freedBytes += item.bytes
            } catch CocoaError.fileNoSuchFile {
                result.skippedCount += 1
            } catch {
                let isAppBundle = item.url.standardizedFileURL == appURL.standardizedFileURL
                if isAppBundle, let finderError = trashWithFinder(item.url) {
                    result.failures.append("\(item.url.lastPathComponent): \(finderError)")
                } else if isAppBundle {
                    result.removedCount += 1
                    result.freedBytes += item.bytes
                } else {
                    result.failures.append("\(item.url.path): \(error.localizedDescription)")
                }
            }
        }
        NSLog("Snappy: uninstall removed \(result.removedCount) items, "
              + "\(result.freedBytes) bytes, \(result.failures.count) failures")
        return result
    }

    /// Asks Finder to move `url` to the Trash; returns an error message or nil.
    private static func trashWithFinder(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // The path is passed as an argument, never spliced into the script.
        process.arguments = [
            "-e", "on run argv",
            "-e", "tell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)",
            "-e", "end run",
            url.path,
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        guard process.terminationStatus != 0 else { return nil }
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.contains("-128") ? "Cancelled." : (message.isEmpty ? "Finder refused." : message)
    }
}
