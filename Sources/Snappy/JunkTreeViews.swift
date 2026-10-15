import AppKit
import Combine
import SwiftUI
import SnappyCore

/// A model that owns `JunkNode` trees shown with `JunkNodeRow`. Tree nodes
/// are classes, so every change goes through these helpers to refresh views.
@MainActor
protocol JunkTreeModel: ObservableObject
    where ObjectWillChangePublisher == ObservableObjectPublisher {
    /// Nodes whose children are being listed in the background.
    var loading: Set<String> { get set }
}

extension JunkTreeModel {
    func toggle(_ node: JunkNode) {
        node.toggle()
        objectWillChange.send()
    }

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
}

/// A checkbox that can show a mixed ("some selected") state.
struct TriStateCheckbox: View {
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

/// A chevron that unfolds/folds a row. Hand-rolled (instead of
/// `DisclosureGroup`) because nested disclosure groups inside a macOS `List`
/// row never grow the row, so their children stay invisible.
struct DisclosureChevron: View {
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse" : "Expand")
    }
}

/// One file/folder in the review tree; unfolds into its children, which are
/// listed on demand, so any level can be ticked or unticked.
struct JunkNodeRow<Model: JunkTreeModel>: View {
    let node: JunkNode
    @ObservedObject var model: Model
    /// Nesting level below the category, used for indentation.
    var depth = 0
    /// Show the full path under the name (top-level folders only).
    var showsPath = false
    /// Replaces the folder/file glyph (e.g. an app's own icon).
    var icon: NSImage? = nil

    /// Children listed per folder; the rest follow the folder's checkbox.
    private let childLimit = 300
    private let indent: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if node.isExpandable {
                    DisclosureChevron(isExpanded: node.isExpanded) {
                        model.setExpanded(node, !node.isExpanded)
                    }
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
                label
            }
            .padding(.leading, CGFloat(depth) * indent)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if node.isExpandable { model.setExpanded(node, !node.isExpanded) }
            }

            if node.isExpanded {
                if model.loading.contains(node.id) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Loading\u{2026}").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.leading, CGFloat(depth + 1) * indent + 20)
                    .padding(.vertical, 3)
                }
                if let children = node.children {
                    ForEach(children.prefix(childLimit)) { child in
                        JunkNodeRow(node: child, model: model, depth: depth + 1)
                    }
                    if children.count > childLimit {
                        Text("\u{2026} and \(children.count - childLimit) smaller items, "
                             + "ticked or unticked together with this folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, CGFloat(depth + 1) * indent + 20)
                            .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    private var label: some View {
        let state = node.check
        return HStack(spacing: 8) {
            TriStateCheckbox(state: state) { model.toggle(node) }
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: node.isDirectory ? "folder" : "doc")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
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
