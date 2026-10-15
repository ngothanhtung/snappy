import Foundation

/// A family of regenerable files the junk cleaner may remove. Every category
/// only ever points at caches, logs or build products that apps and the system
/// recreate on demand — never documents, preferences or app data.
public enum JunkCategory: String, CaseIterable, Sendable {
    case userCaches
    case userLogs
    case temporaryFiles
    case xcodeDerivedData
    case simulatorCaches
    case xcodeDeviceSupport
    case packageManagerCaches

    /// How the scanner turns a category root into deletable items.
    public enum Strategy: Sendable {
        /// Remove each top-level child of the root as a whole.
        case topLevelItems
        /// Keep each top-level child (e.g. an app's cache folder) but remove
        /// everything inside it, so folder ownership/permissions survive.
        case contentsOfItems
        /// Remove only regular files older than `minimumAge`, anywhere below
        /// the root; directories are left in place.
        case oldFiles
    }

    public var title: String {
        switch self {
        case .userCaches:           return "User Caches"
        case .userLogs:             return "User Logs & Crash Reports"
        case .temporaryFiles:       return "Temporary Files"
        case .xcodeDerivedData:     return "Xcode Derived Data"
        case .simulatorCaches:      return "Simulator Caches"
        case .xcodeDeviceSupport:   return "Xcode Device Support"
        case .packageManagerCaches: return "Package Manager Caches"
        }
    }

    public var detail: String {
        switch self {
        case .userCaches:
            return "App caches in ~/Library/Caches. Apps rebuild them as needed."
        case .userLogs:
            return "Logs and crash reports older than 7 days in ~/Library/Logs."
        case .temporaryFiles:
            return "Your temporary folder's files untouched for over 3 days."
        case .xcodeDerivedData:
            return "Xcode build products and indexes. Projects rebuild on next build."
        case .simulatorCaches:
            return "CoreSimulator caches. Simulators recreate them on launch."
        case .xcodeDeviceSupport:
            return "Debug symbols for connected devices. Re-downloaded when a device reconnects."
        case .packageManagerCaches:
            return "npm and Gradle download caches. Re-downloaded on next install."
        }
    }

    /// SF Symbol shown next to the category.
    public var symbol: String {
        switch self {
        case .userCaches:           return "archivebox"
        case .userLogs:             return "doc.text"
        case .temporaryFiles:       return "clock.arrow.circlepath"
        case .xcodeDerivedData:     return "hammer"
        case .simulatorCaches:      return "iphone"
        case .xcodeDeviceSupport:   return "cable.connector"
        case .packageManagerCaches: return "shippingbox"
        }
    }

    /// Selected by default. Categories that cost a slow re-download stay opt-in.
    public var isSelectedByDefault: Bool {
        switch self {
        case .xcodeDeviceSupport, .packageManagerCaches: return false
        default: return true
        }
    }

    public var strategy: Strategy {
        switch self {
        case .userCaches:                         return .contentsOfItems
        case .userLogs, .temporaryFiles:          return .oldFiles
        case .xcodeDerivedData, .simulatorCaches,
             .xcodeDeviceSupport, .packageManagerCaches:
            return .topLevelItems
        }
    }

    /// Files modified more recently than this are never touched.
    public var minimumAge: TimeInterval {
        let day: TimeInterval = 24 * 60 * 60
        switch self {
        case .userLogs:       return 7 * day
        case .temporaryFiles: return 3 * day
        default:              return 0
        }
    }

    /// Directories scanned for this category. Missing ones are simply skipped.
    public func roots(home: URL, temporaryDirectory: URL) -> [URL] {
        func h(_ path: String) -> URL { home.appendingPathComponent(path, isDirectory: true) }
        switch self {
        case .userCaches:       return [h("Library/Caches")]
        case .userLogs:         return [h("Library/Logs")]
        case .temporaryFiles:   return [temporaryDirectory]
        case .xcodeDerivedData: return [h("Library/Developer/Xcode/DerivedData")]
        case .simulatorCaches:  return [h("Library/Developer/CoreSimulator/Caches")]
        case .xcodeDeviceSupport:
            return ["iOS", "watchOS", "tvOS", "visionOS", "macOS"].map {
                h("Library/Developer/Xcode/\($0) DeviceSupport")
            }
        case .packageManagerCaches:
            return [h(".npm/_cacache"), h(".gradle/caches")]
        }
    }
}

/// Pure safety rules the cleaner checks before removing anything.
public enum JunkSafety {

    /// Top-level cache folder names that hold state rather than disposable
    /// cache (iCloud sync, in-flight downloads, account/keychain helpers,
    /// Spotlight metadata…). Removing them can force re-syncs or lose work.
    public static let protectedNames: Set<String> = [
        "CloudKit",
        "com.apple.bird",
        "com.apple.cloudd",
        "com.apple.CloudDocs",
        "com.apple.nsurlsessiond",
        "com.apple.akd",
        "com.apple.ak",
        "com.apple.accountsd",
        "com.apple.containermanagerd",
        "com.apple.passd",
        "com.apple.iCloudHelper",
        "com.apple.homed",
        "com.apple.HomeKit",
        "com.apple.amsengagementd",
        "com.apple.appstoreagent",
        "com.apple.softwareupdate",
        "com.apple.SoftwareUpdate",
        "FamilyCircle",
        "Metadata",
        "TemporaryItems",
        "Cleanup At Startup",
    ]

    /// Whether a top-level item name is on the protected list.
    public static func isProtected(name: String) -> Bool {
        protectedNames.contains(name)
    }

    /// Whether a top-level cache folder belongs to an app that's running now.
    /// Matches the bundle ID exactly or as a dotted prefix
    /// (`com.foo.app` owns `com.foo.app.helper`), case-insensitively.
    public static func belongsToRunningApp(name: String, runningBundleIDs: Set<String>) -> Bool {
        let lower = name.lowercased()
        return runningBundleIDs.contains { id in
            let bundle = id.lowercased()
            return !bundle.isEmpty && (lower == bundle || lower.hasPrefix(bundle + "."))
        }
    }

    /// Whether `url` lies strictly inside `root` (never the root itself),
    /// compared component-wise after resolving `.` and `..`.
    public static func isStrictlyInside(_ url: URL, root: URL) -> Bool {
        let item = url.standardizedFileURL.pathComponents
        let base = root.standardizedFileURL.pathComponents
        guard item.count > base.count else { return false }
        return Array(item.prefix(base.count)) == base
    }

    /// A file qualifies if it was last modified at least `minimumAge` ago.
    /// Unknown dates only qualify when no age limit applies.
    public static func isOldEnough(modified: Date?, now: Date, minimumAge: TimeInterval) -> Bool {
        guard minimumAge > 0 else { return true }
        guard let modified else { return false }
        return now.timeIntervalSince(modified) >= minimumAge
    }

    /// Name of the first path component below `root`, if `url` is inside it.
    public static func topLevelName(of url: URL, root: URL) -> String? {
        guard isStrictlyInside(url, root: root) else { return nil }
        let base = root.standardizedFileURL.pathComponents.count
        return url.standardizedFileURL.pathComponents[base]
    }

    /// The final gate before removal: inside the root, not protected,
    /// not owned by a running app (or by Snappy itself).
    public static func canRemove(_ url: URL, root: URL, runningBundleIDs: Set<String>) -> Bool {
        guard let top = topLevelName(of: url, root: root) else { return false }
        return !isProtected(name: top)
            && !belongsToRunningApp(name: top, runningBundleIDs: runningBundleIDs)
    }
}
