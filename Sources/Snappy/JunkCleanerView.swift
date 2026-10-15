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
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            win.title = "Clean System Junk"
            win.contentView = NSHostingView(rootView: JunkCleanerView())
            win.contentMinSize = NSSize(width: 480, height: 420)
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

    @Published var selected: Set<JunkCategory> =
        Set(JunkCategory.allCases.filter(\.isSelectedByDefault))
    @Published var groups: [JunkGroup] = []
    /// Groups the user unticked after a scan.
    @Published var excluded: Set<String> = []
    @Published var phase: Phase = .idle
    @Published var moveToTrash =
        UserDefaults.standard.object(forKey: "junkCleanerMoveToTrash") as? Bool ?? true {
        didSet { UserDefaults.standard.set(moveToTrash, forKey: "junkCleanerMoveToTrash") }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func groups(in category: JunkCategory) -> [JunkGroup] {
        groups.filter { $0.category == category }
    }

    func bytes(in category: JunkCategory) -> Int64 {
        groups(in: category).filter { !excluded.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    var chosenGroups: [JunkGroup] {
        groups.filter { selected.contains($0.category) && !excluded.contains($0.id) }
    }

    var chosenBytes: Int64 { chosenGroups.reduce(0) { $0 + $1.bytes } }

    var isBusy: Bool { phase == .scanning || phase == .cleaning }

    func scan() {
        phase = .scanning
        excluded = []
        let categories = selected
        let running = Self.runningBundleIDs()
        Task.detached(priority: .userInitiated) {
            let found = JunkScanner.scan(categories, runningBundleIDs: running)
            await MainActor.run {
                self.groups = found
                self.phase = .scanned
            }
        }
    }

    func clean() {
        phase = .cleaning
        let chosen = chosenGroups
        let toTrash = moveToTrash
        let running = Self.runningBundleIDs()
        Task.detached(priority: .userInitiated) {
            let result = JunkScanner.clean(chosen, moveToTrash: toTrash, runningBundleIDs: running)
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
                self.excluded = []
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

struct JunkCleanerView: View {
    @StateObject private var model = JunkCleanerModel()
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                ForEach(JunkCategory.allCases, id: \.self) { category in
                    categoryRow(category)
                }
            }
            .listStyle(.inset)
            .disabled(model.isBusy)
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 420)
        .alert("Clean \(JunkCleanerModel.format(model.chosenBytes)) of junk?",
               isPresented: $confirming) {
            Button(model.moveToTrash ? "Move to Trash" : "Delete", role: .destructive) {
                model.clean()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.moveToTrash
                 ? "Items are moved to the Trash, so you can restore them if something goes wrong."
                 : "Items are deleted immediately and cannot be restored.")
        }
    }

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
        case .idle:        return "Scan for system junk"
        case .scanning:    return "Scanning\u{2026}"
        case .scanned:     return "\(JunkCleanerModel.format(model.chosenBytes)) can be cleaned"
        case .cleaning:    return "Cleaning\u{2026}"
        case .cleaned:     return "Done"
        }
    }

    private var subheadline: String {
        if case .cleaned(let summary) = model.phase { return summary }
        return "Only caches, logs and build files that are rebuilt automatically are touched. "
            + "Caches of running apps and iCloud/system state are always skipped."
    }

    @ViewBuilder
    private func categoryRow(_ category: JunkCategory) -> some View {
        let groups = model.groups(in: category)
        let isOn = Binding(
            get: { model.selected.contains(category) },
            set: { on in
                if on { model.selected.insert(category) } else { model.selected.remove(category) }
            }
        )
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: isOn) {
                    Label(category.title, systemImage: category.symbol)
                }
                Spacer()
                if model.phase == .scanned {
                    Text(groups.isEmpty ? "Nothing found"
                                        : JunkCleanerModel.format(model.bytes(in: category)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Text(category.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.phase == .scanned, !groups.isEmpty, isOn.wrappedValue {
                DisclosureGroup("\(groups.count) folders") {
                    ForEach(groups.prefix(200)) { group in
                        groupRow(group)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func groupRow(_ group: JunkGroup) -> some View {
        let isOn = Binding(
            get: { !model.excluded.contains(group.id) },
            set: { on in
                if on { model.excluded.remove(group.id) } else { model.excluded.insert(group.id) }
            }
        )
        return HStack {
            Toggle(group.name, isOn: isOn)
                .help(group.id)
            Spacer()
            Text(JunkCleanerModel.format(group.bytes))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [group.root.appendingPathComponent(group.name)])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Move to Trash (recoverable)", isOn: $model.moveToTrash)
            Spacer()
            Button(model.phase == .scanned ? "Rescan" : "Scan") { model.scan() }
                .disabled(model.isBusy || model.selected.isEmpty)
            Button("Clean") { confirming = true }
                .keyboardShortcut(.defaultAction)
                .disabled(model.phase != .scanned || model.chosenBytes == 0)
        }
        .padding(12)
    }
}
