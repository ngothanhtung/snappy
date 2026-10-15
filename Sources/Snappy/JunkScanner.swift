import Foundation
import SnappyCore

/// One top-level folder of a category root (e.g. one app's folder in
/// ~/Library/Caches) with the review tree the user ticks inside it.
struct JunkGroup: Identifiable, Sendable {
    let category: JunkCategory
    let root: URL
    let node: JunkNode

    var id: String { node.id }

    /// Concrete removals for whatever is currently ticked in the tree.
    var removals: [JunkRemoval] {
        node.removalTargets().map {
            JunkRemoval(url: $0.url, bytes: $0.bytes, root: root, category: category)
        }
    }
}

/// One path the cleaner will remove.
struct JunkRemoval: Sendable {
    let url: URL
    let bytes: Int64
    let root: URL
    let category: JunkCategory
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
        return groups.sorted { $0.node.bytes > $1.node.bytes }
    }

    private static func scan(root rawRoot: URL, category: JunkCategory,
                             runningBundleIDs: Set<String>, now: Date) -> [JunkGroup] {
        // Resolve symlinks once (e.g. /var → /private/var) so containment
        // checks compare real paths.
        let root = rawRoot.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
              let children = try? fm.contentsOfDirectory(at: root,
                                                         includingPropertiesForKeys: Array(sizeKeys),
                                                         options: []) else { return [] }

        return children.compactMap { child in
            guard JunkSafety.canRemove(child, root: root, runningBundleIDs: runningBundleIDs),
                  let node = topNode(for: child, category: category, now: now) else { return nil }
            return JunkGroup(category: category, root: root, node: node)
        }
    }

    /// The review tree for one top-level item, or nil if nothing qualifies.
    private static func topNode(for child: URL, category: JunkCategory, now: Date) -> JunkNode? {
        let values = try? child.resourceValues(forKeys: sizeKeys)
        let isRealDirectory = values?.isDirectory == true && values?.isSymbolicLink != true

        switch category.strategy {
        case .topLevelItems:
            // Ticking the whole folder removes it; its first level is listed
            // up front so the user can pick parts instead.
            guard isRealDirectory else { return leaf(child, values) }
            let kids = loadChildren(of: child)
            return JunkNode(url: child, isDirectory: true,
                            bytes: kids.reduce(0) { $0 + $1.bytes }, children: kids)

        case .contentsOfItems:
            // Keep the app's folder itself; only its contents are removable.
            guard isRealDirectory else { return leaf(child, values) }
            let kids = loadChildren(of: child)
            guard !kids.isEmpty else { return nil }
            return JunkNode(url: child, isDirectory: true, bytes: 0, removal: .contents,
                            children: kids)

        case .oldFiles:
            guard isRealDirectory else {
                guard values?.isRegularFile == true,
                      JunkSafety.isOldEnough(modified: values?.contentModificationDate, now: now,
                                             minimumAge: category.minimumAge) else { return nil }
                return leaf(child, values)
            }
            var files: [(url: URL, bytes: Int64)] = []
            forEachFile(under: child) { url, values in
                guard values.isRegularFile == true,
                      JunkSafety.isOldEnough(modified: values.contentModificationDate, now: now,
                                             minimumAge: category.minimumAge) else { return }
                files.append((url, fileSize(values)))
            }
            return files.isEmpty ? nil : JunkNode.fileTree(folder: child, files: files)
        }
    }

    /// Lists a real folder's direct children as `.whole` nodes with sizes.
    /// Used at scan time for the first level and lazily when a node unfolds.
    static func loadChildren(of folder: URL) -> [JunkNode] {
        let inner = (try? fm.contentsOfDirectory(at: folder,
                                                 includingPropertiesForKeys: Array(sizeKeys),
                                                 options: [])) ?? []
        return inner.map { url in
            let values = try? url.resourceValues(forKeys: sizeKeys)
            let isRealDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
            return JunkNode(url: url, isDirectory: isRealDirectory, bytes: allocatedSize(of: url))
        }
    }

    private static func leaf(_ url: URL, _ values: URLResourceValues?) -> JunkNode {
        JunkNode(url: url, isDirectory: false, bytes: fileSize(values))
    }

    // MARK: - Clean

    static func clean(_ removals: [JunkRemoval], moveToTrash: Bool,
                      runningBundleIDs: Set<String>, now: Date = Date()) -> JunkCleanResult {
        var result = JunkCleanResult()
        for item in removals {
            // Re-check right before removal: an app may have launched since
            // the scan, or the file may have been touched again.
            guard JunkSafety.canRemove(item.url, root: item.root,
                                       runningBundleIDs: runningBundleIDs),
                  stillOldEnough(item.url, category: item.category, now: now) else {
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
