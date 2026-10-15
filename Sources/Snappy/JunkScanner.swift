import Foundation
import SnappyCore

/// One removable file or folder found by a scan.
struct JunkItem: Sendable {
    let url: URL
    let bytes: Int64
}

/// Everything a scan found under one top-level folder of a category root
/// (e.g. one app's folder in ~/Library/Caches).
struct JunkGroup: Identifiable, Sendable {
    let category: JunkCategory
    let root: URL
    let name: String
    let items: [JunkItem]

    var id: String { root.appendingPathComponent(name).path }
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

struct JunkCleanResult: Sendable {
    var removedCount = 0
    var freedBytes: Int64 = 0
    var skippedCount = 0
    var failures: [String] = []
}

/// Finds and removes junk on disk. Blocking file I/O — call off the main thread.
/// Every removal is re-checked against `JunkSafety` immediately beforehand.
enum JunkScanner {

    private static let fm = FileManager.default
    private static let sizeKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey,
    ]

    // MARK: - Scan

    static func scan(_ categories: Set<JunkCategory>, runningBundleIDs: Set<String>,
                     now: Date = Date()) -> [JunkGroup] {
        let home = fm.homeDirectoryForCurrentUser
        let tmp = fm.temporaryDirectory
        var groups: [JunkGroup] = []
        for category in JunkCategory.allCases where categories.contains(category) {
            for root in category.roots(home: home, temporaryDirectory: tmp) {
                groups += scan(root: root, category: category,
                               runningBundleIDs: runningBundleIDs, now: now)
            }
        }
        return groups.sorted { $0.bytes > $1.bytes }
    }

    private static func scan(root rawRoot: URL, category: JunkCategory,
                             runningBundleIDs: Set<String>, now: Date) -> [JunkGroup] {
        // Resolve symlinks once (e.g. /var → /private/var) so containment
        // checks compare real paths, and refuse a root that is itself a link
        // somewhere else entirely.
        let root = rawRoot.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
              let children = try? fm.contentsOfDirectory(at: root,
                                                         includingPropertiesForKeys: Array(sizeKeys),
                                                         options: []) else { return [] }

        var groups: [JunkGroup] = []
        for child in children {
            guard JunkSafety.canRemove(child, root: root, runningBundleIDs: runningBundleIDs) else {
                continue
            }
            let items = removableItems(in: child, category: category, now: now)
            guard !items.isEmpty else { continue }
            groups.append(JunkGroup(category: category, root: root,
                                    name: child.lastPathComponent, items: items))
        }
        return groups
    }

    private static func removableItems(in child: URL, category: JunkCategory,
                                       now: Date) -> [JunkItem] {
        let values = try? child.resourceValues(forKeys: sizeKeys)
        let isRealDirectory = values?.isDirectory == true && values?.isSymbolicLink != true

        switch category.strategy {
        case .topLevelItems:
            return [JunkItem(url: child, bytes: allocatedSize(of: child))]

        case .contentsOfItems:
            guard isRealDirectory else {
                return [JunkItem(url: child, bytes: allocatedSize(of: child))]
            }
            let inner = (try? fm.contentsOfDirectory(at: child, includingPropertiesForKeys: nil,
                                                     options: [])) ?? []
            return inner.map { JunkItem(url: $0, bytes: allocatedSize(of: $0)) }

        case .oldFiles:
            guard isRealDirectory else {
                guard values?.isRegularFile == true,
                      JunkSafety.isOldEnough(modified: values?.contentModificationDate, now: now,
                                             minimumAge: category.minimumAge) else { return [] }
                return [JunkItem(url: child, bytes: fileSize(values))]
            }
            var items: [JunkItem] = []
            forEachFile(under: child) { url, values in
                guard values.isRegularFile == true,
                      JunkSafety.isOldEnough(modified: values.contentModificationDate, now: now,
                                             minimumAge: category.minimumAge) else { return }
                items.append(JunkItem(url: url, bytes: fileSize(values)))
            }
            return items
        }
    }

    // MARK: - Clean

    static func clean(_ groups: [JunkGroup], moveToTrash: Bool,
                      runningBundleIDs: Set<String>, now: Date = Date()) -> JunkCleanResult {
        var result = JunkCleanResult()
        for group in groups {
            for item in group.items {
                // Re-check right before removal: an app may have launched
                // since the scan, or the file may have been touched again.
                guard JunkSafety.canRemove(item.url, root: group.root,
                                           runningBundleIDs: runningBundleIDs),
                      stillOldEnough(item.url, category: group.category, now: now) else {
                    result.skippedCount += 1
                    continue
                }
                do {
                    if moveToTrash {
                        try fm.trashItem(at: item.url, resultingItemURL: nil)
                    } else {
                        try fm.removeItem(at: item.url)
                    }
                    result.removedCount += 1
                    result.freedBytes += item.bytes
                } catch CocoaError.fileNoSuchFile {
                    result.skippedCount += 1 // already gone (app cleaned it up)
                } catch {
                    result.failures.append("\(item.url.path): \(error.localizedDescription)")
                }
            }
        }
        NSLog("Snappy: junk clean removed \(result.removedCount) items, "
              + "\(result.freedBytes) bytes, \(result.failures.count) failures")
        return result
    }

    private static func stillOldEnough(_ url: URL, category: JunkCategory, now: Date) -> Bool {
        guard category.minimumAge > 0 else { return true }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        return JunkSafety.isOldEnough(modified: modified, now: now,
                                      minimumAge: category.minimumAge)
    }

    // MARK: - Sizes

    private static func fileSize(_ values: URLResourceValues?) -> Int64 {
        Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }

    private static func allocatedSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: sizeKeys)
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            return fileSize(values)
        }
        var total: Int64 = 0
        forEachFile(under: url) { _, values in total += fileSize(values) }
        return total
    }

    /// Walks `url` recursively without following symlinks, skipping
    /// unreadable entries instead of failing the whole scan.
    private static func forEachFile(under url: URL, _ body: (URL, URLResourceValues) -> Void) {
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(sizeKeys),
                                             options: [], errorHandler: { _, _ in true }) else {
            return
        }
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: sizeKeys),
                  values.isDirectory != true else { continue }
            body(file, values)
        }
    }
}
