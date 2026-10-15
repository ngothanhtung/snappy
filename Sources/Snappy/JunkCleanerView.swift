import AppKit
import SwiftUI
import SnappyCore

/// Hosts the "Clean System Junk" window.
@MainActor
final class JunkCleanerController {
    static let shared = JunkCleanerController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 680),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            win.title = "Clean System Junk"
            win.contentView = NSHostingView(rootView: JunkCleanerView())
            win.contentMinSize = NSSize(width: 540, height: 460)
            win.isReleasedWhenClosed = false
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class JunkCleanerModel: ObservableObject {
    enum Phase: Equatable {
        case idle, scanning, scanned, cleaning
        case cleaned(String)
    }

    /// Categories to scan (and, before a scan, the category checkboxes).
    @Published var selected: Set<JunkCategory> =
        Set(JunkCategory.allCases.filter(\.isSelectedByDefault))
    /// Scan results. Ticks live in each group's `JunkNode` tree; mutate it
    /// only through this model so the view refreshes.
    @Published var groups: [JunkGroup] = []
    /// Categories whose folder tree is unfolded.
    @Published var expandedCategories: Set<JunkCategory> = []
    /// Nodes whose children are being listed in the background.
    @Published var loading: Set<String> = []
    @Published var phase: Phase = .idle
    @Published var moveToTrash =
        UserDefaults.standard.object(forKey: "junkCleanerMoveToTrash") as? Bool ?? true {
        didSet { UserDefaults.standard.set(moveToTrash, forKey: "junkCleanerMoveToTrash") }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Path with the home folder shortened to `~`.
    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let path = url.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    func groups(in category: JunkCategory) -> [JunkGroup] {
        groups.filter { $0.category == category }
    }

    var isBusy: Bool { phase == .scanning || phase == .cleaning }

    // MARK: Ticks

    func toggle(_ node: JunkNode) {
        node.toggle()
        objectWillChange.send()
    }

    func check(for category: JunkCategory) -> JunkCheck {
        let found = groups(in: category)
        guard phase == .scanned, !found.isEmpty else {
            return selected.contains(category) ? .on : .off
        }
        let states = found.map(\.node.check)
        if states.allSatisfy({ $0 == .on }) { return .on }
        if states.allSatisfy({ $0 == .off }) { return .off }
        return .mixed
    }

    /// Ticks/unticks a category. After a scan this applies to its whole tree.
    func toggle(_ category: JunkCategory) {
        let turnOn = check(for: category) != .on
        if turnOn { selected.insert(category) } else { selected.remove(category) }
        groups(in: category).forEach { $0.node.setSelected(turnOn) }
        objectWillChange.send()
    }

    func setAll(_ on: Bool) {
        groups.forEach { $0.node.setSelected(on) }
        if on { selected.formUnion(Set(groups.map(\.category))) }
        objectWillChange.send()
    }

    func bytes(in category: JunkCategory) -> Int64 {
        groups(in: category).reduce(0) { $0 + $1.node.selectedBytes }
    }

    var chosenBytes: Int64 { groups.reduce(0) { $0 + $1.node.selectedBytes } }
    var chosenRemovals: [JunkRemoval] { groups.flatMap(\.removals) }

    // MARK: Tree

    /// Unfolds/folds a node, listing a real folder's children on first open.
    func setExpanded(_ node: JunkNode, _ open: Bool) {
        node.isExpanded = open
        objectWillChange.send()
        guard open, node.canLoadChildren, !loading.contains(node.id) else { return }
        loading.insert(node.id)
        let folder = node.url
        Task.detached(priority: .userInitiated) {
            let children = JunkScanner.loadChildren(of: folder)
            await MainActor.run {
                node.setChildren(children)
                self.loading.remove(node.id)
            }
        }
    }

    // MARK: Scan / clean

    func scan() {
        phase = .scanning
        let categories = selected
        let running = Self.runningBundleIDs()
        Task.detached(priority: .userInitiated) {
            let found = JunkScanner.scan(categories, runningBundleIDs: running)
            await MainActor.run {
                self.groups = found
                // Unfold every category that found something so its folders
                // are reviewed before cleaning.
                self.expandedCategories = Set(found.map(\.category))
                self.phase = .scanned
            }
        }
    }

    func clean() {
        phase = .cleaning
        let removals = chosenRemovals
        let toTrash = moveToTrash
        let running = Self.runningBundleIDs()
        Task.detached(priority: .userInitiated) {
            let result = JunkScanner.clean(removals, moveToTrash: toTrash,
                                           runningBundleIDs: running)
            await MainActor.run {
                var summary = "Removed \(result.removedCount) items, freed "
                    + Self.format(result.freedBytes)
                if toTrash { summary += " (in Trash — empty it to reclaim the space)" }
                summary += "."
                if result.skippedCount > 0 {
                    summary += " Skipped \(result.skippedCount) in use or changed."
                }
                if !result.failures.isEmpty {
                    summary += " \(result.failures.count) couldn't be removed (see Console)."
                    result.failures.prefix(50).forEach { NSLog("Snappy: junk clean failed: \($0)") }
                }
                self.groups = []
                self.expandedCategories = []
                self.phase = .cleaned(summary)
            }
        }
    }

    /// Bundle IDs of running apps — their caches are left alone.
    private static func runningBundleIDs() -> Set<String> {
        var ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if let own = Bundle.main.bundleIdentifier { ids.insert(own) }
        return ids
    }
}

/// A checkbox that can show a mixed ("some selected") state.
private struct TriStateCheckbox: View {
    let state: JunkCheck
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(state == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .font(.system(size: 14))
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        switch state {
        case .on:    return "checkmark.square.fill"
        case .mixed: return "minus.square.fill"
        case .off:   return "square"
        }
    }
}

/// One file/folder in the review tree; unfolds into its children, which are
/// listed on demand, so any level can be ticked or unticked.
private struct JunkNodeRow: View {
    let node: JunkNode
    @ObservedObject var model: JunkCleanerModel
    /// Show the full path under the name (top-level folders only).
    var showsPath = false

    /// Children listed per folder; the rest follow the folder's checkbox.
    private let childLimit = 300

    var body: some View {
        if node.isExpandable {
            DisclosureGroup(isExpanded: Binding(get: { node.isExpanded },
                                                set: { model.setExpanded(node, $0) })) {
                if model.loading.contains(node.id) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Loading\u{2026}").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let children = node.children {
                    ForEach(children.prefix(childLimit)) { child in
                        JunkNodeRow(node: child, model: model)
                    }
                    if children.count > childLimit {
                        Text("\u{2026} and \(children.count - childLimit) smaller items, "
                             + "ticked or unticked together with this folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } label: {
                label
            }
        } else {
            // Line up with rows that have a disclosure chevron.
            label.padding(.leading, 18)
        }
    }

    private var label: some View {
        let state = node.check
        return HStack(spacing: 8) {
            TriStateCheckbox(state: state) { model.toggle(node) }
            Image(systemName: node.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(node.url.path)
                if showsPath {
                    Text(JunkCleanerModel.displayPath(node.url))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            Text(sizeText(state))
                .font(showsPath ? .body : .caption)
                .foregroundStyle(showsPath ? .primary : .secondary)
                .monospacedDigit()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .opacity(state == .off ? 0.55 : 1)
    }

    private func sizeText(_ state: JunkCheck) -> String {
        let total = JunkCleanerModel.format(node.bytes)
        guard state == .mixed else { return total }
        return "\(JunkCleanerModel.format(node.selectedBytes)) of \(total)"
    }
}

struct JunkCleanerView: View {
    @StateObject private var model = JunkCleanerModel()
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                ForEach(JunkCategory.allCases, id: \.self) { category in
                    categorySection(category)
                }
            }
            .listStyle(.inset)
            .disabled(model.isBusy)
            Divider()
            footer
        }
        .frame(minWidth: 540, minHeight: 460)
        .alert("Clean \(JunkCleanerModel.format(model.chosenBytes)) of junk?",
               isPresented: $confirming) {
            Button(model.moveToTrash ? "Move to Trash" : "Delete", role: .destructive) {
                model.clean()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.chosenRemovals.count) files and folders. "
                 + (model.moveToTrash
                    ? "They are moved to the Trash, so you can restore them if something goes wrong."
                    : "They are deleted immediately and cannot be restored."))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.headline)
                Text(subheadline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.isBusy { ProgressView().controlSize(.small) }
        }
        .padding(16)
    }

    private var headline: String {
        switch model.phase {
        case .idle:     return "Scan for system junk"
        case .scanning: return "Scanning\u{2026}"
        case .scanned:
            let count = model.chosenRemovals.count
            return "\(JunkCleanerModel.format(model.chosenBytes)) selected · "
                + "\(count) \(count == 1 ? "item" : "items") to remove"
        case .cleaning: return "Cleaning\u{2026}"
        case .cleaned:  return "Done"
        }
    }

    private var subheadline: String {
        switch model.phase {
        case .cleaned(let summary):
            return summary
        case .scanned:
            return "Unfold any folder to browse the tree inside it and tick or untick "
                + "items at any level. Only ticked items are cleaned."
        default:
            return "Only caches, logs and build files that are rebuilt automatically are touched. "
                + "Caches of running apps and iCloud/system state are always skipped."
        }
    }

    // MARK: - Categories

    @ViewBuilder
    private func categorySection(_ category: JunkCategory) -> some View {
        let groups = model.groups(in: category)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TriStateCheckbox(state: model.check(for: category)) { model.toggle(category) }
                Label(category.title, systemImage: category.symbol)
                    .fontWeight(.medium)
                Spacer()
                if model.phase == .scanned {
                    Text(groups.isEmpty
                         ? "Nothing found"
                         : "\(groups.count) folders · "
                           + JunkCleanerModel.format(model.bytes(in: category)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Text(category.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
            if model.phase == .scanned, !groups.isEmpty {
                DisclosureGroup(isExpanded: expandedBinding(category)) {
                    ForEach(groups) { group in
                        JunkNodeRow(node: group.node, model: model, showsPath: true)
                    }
                } label: {
                    Text(model.expandedCategories.contains(category)
                         ? "Hide folders" : "Show folders")
                        .font(.caption)
                }
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, 4)
    }

    private func expandedBinding(_ category: JunkCategory) -> Binding<Bool> {
        Binding(
            get: { model.expandedCategories.contains(category) },
            set: { open in
                if open { model.expandedCategories.insert(category) }
                else { model.expandedCategories.remove(category) }
            }
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Toggle("Move to Trash (recoverable)", isOn: $model.moveToTrash)
            Spacer()
            if model.phase == .scanned {
                Button("Select All") { model.setAll(true) }
                Button("Deselect All") { model.setAll(false) }
            }
            Button(model.phase == .scanned ? "Rescan" : "Scan") { model.scan() }
                .disabled(model.isBusy || model.selected.isEmpty)
            Button("Clean") { confirming = true }
                .keyboardShortcut(.defaultAction)
                .disabled(model.phase != .scanned || model.chosenRemovals.isEmpty)
        }
        .padding(12)
    }
}
