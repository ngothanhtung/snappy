import Foundation

/// Tri-state checkbox value: everything, part, or nothing selected.
public enum JunkCheck: Sendable {
    case on, mixed, off
}

/// One file or folder in the junk cleaner's review tree. The user ticks nodes
/// at any depth; `removalTargets()` then resolves the ticks into the smallest
/// set of paths to remove. Not thread-safe: build it on one thread, then hand
/// it over and mutate it only on the main thread.
public final class JunkNode: Identifiable, @unchecked Sendable {

    /// What "remove this node" means once it is fully ticked.
    public enum Removal: Sendable {
        /// Remove the file/folder itself.
        case whole
        /// Keep the folder; remove its children instead. Used for an app's
        /// cache folder and for folders that only group old log/temp files.
        case contents
    }

    public let url: URL
    public let isDirectory: Bool
    public let removal: Removal
    public private(set) var children: [JunkNode]?
    /// Your own tick; only shown when there are no children to derive from.
    public private(set) var isSelected: Bool
    public var isExpanded = false
    private let ownBytes: Int64

    public init(url: URL, isDirectory: Bool, bytes: Int64, removal: Removal = .whole,
                children: [JunkNode]? = nil, isSelected: Bool = true) {
        self.url = url
        self.isDirectory = isDirectory
        self.removal = removal
        self.ownBytes = bytes
        self.isSelected = isSelected
        self.children = children.map(Self.sortedBySize)
    }

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    /// Size on disk. A `.contents` folder is exactly the sum of its children.
    public var bytes: Int64 {
        guard removal == .contents, let children else { return ownBytes }
        return children.reduce(0) { $0 + $1.bytes }
    }

    /// A real folder whose children haven't been listed yet.
    public var canLoadChildren: Bool { isDirectory && removal == .whole && children == nil }

    /// Whether the UI should offer to unfold this node.
    public var isExpandable: Bool { canLoadChildren || !(children ?? []).isEmpty }

    /// Attaches lazily listed children; they inherit this node's tick.
    public func setChildren(_ list: [JunkNode]) {
        list.forEach { $0.setSelected(isSelected) }
        children = Self.sortedBySize(list)
    }

    public var check: JunkCheck {
        guard let children, !children.isEmpty else { return isSelected ? .on : .off }
        let states = children.map(\.check)
        if states.allSatisfy({ $0 == .on }) { return .on }
        if states.allSatisfy({ $0 == .off }) { return .off }
        return .mixed
    }

    /// Ticks or unticks this node and everything below it.
    public func setSelected(_ on: Bool) {
        isSelected = on
        children?.forEach { $0.setSelected(on) }
    }

    /// Flips the checkbox: anything not fully ticked becomes fully ticked.
    public func toggle() { setSelected(check != .on) }

    public var selectedBytes: Int64 {
        switch check {
        case .on:    return bytes
        case .off:   return 0
        case .mixed: return (children ?? []).reduce(0) { $0 + $1.selectedBytes }
        }
    }

    /// The highest fully-ticked `.whole` nodes at or below this one — i.e.
    /// exactly what must be removed, with no path listed twice.
    public func removalTargets() -> [JunkNode] {
        switch check {
        case .off:
            return []
        case .on where removal == .whole:
            return [self]
        case .on, .mixed:
            return (children ?? []).flatMap { $0.removalTargets() }
        }
    }

    /// Builds a `.contents` folder tree under `folder` from a flat list of
    /// files somewhere below it (e.g. old logs). Intermediate folders only
    /// group files, so ticking one removes its files, never the folder.
    public static func fileTree(folder: URL, files: [(url: URL, bytes: Int64)]) -> JunkNode {
        final class Builder {
            var dirs: [String: Builder] = [:]
            var files: [JunkNode] = []
        }
        let base = folder.standardizedFileURL.pathComponents
        let top = Builder()
        for file in files {
            let parts = file.url.standardizedFileURL.pathComponents
            guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { continue }
            var node = top
            for dir in parts[base.count..<(parts.count - 1)] {
                if node.dirs[dir] == nil { node.dirs[dir] = Builder() }
                node = node.dirs[dir]!
            }
            node.files.append(JunkNode(url: file.url, isDirectory: false, bytes: file.bytes))
        }
        func make(_ builder: Builder, at url: URL) -> JunkNode {
            let subdirs = builder.dirs.map { name, sub in
                make(sub, at: url.appendingPathComponent(name, isDirectory: true))
            }
            return JunkNode(url: url, isDirectory: true, bytes: 0, removal: .contents,
                            children: subdirs + builder.files)
        }
        return make(top, at: folder)
    }

    private static func sortedBySize(_ list: [JunkNode]) -> [JunkNode] {
        list.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
    }
}
