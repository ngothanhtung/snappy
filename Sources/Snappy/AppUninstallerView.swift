import AppKit
import SwiftUI
import SnappyCore

/// Hosts the "Uninstall Apps" window.
@MainActor
final class AppUninstallerController {
    static let shared = AppUninstallerController()
    private var window: NSWindow?
    private let model = AppUninstallerModel()

    func show() {
        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            win.title = "Uninstall Apps"
            win.contentView = NSHostingView(rootView: AppUninstallerView(model: model))
            win.contentMinSize = NSSize(width: 760, height: 480)
            win.tabbingMode = .disallowed
            win.isReleasedWhenClosed = false
            if !win.setFrameUsingName("AppUninstaller") { win.center() }
            win.setFrameAutosaveName("AppUninstaller")
            window = win
        }
        model.reloadApps()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class AppUninstallerModel: ObservableObject, JunkTreeModel {
    enum SortOrder: String, CaseIterable { case name = "Name", size = "Size" }

    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var isLoadingApps = false
    @Published var search = ""
    @Published var sortOrder: SortOrder = .name
    @Published private(set) var selectedID: String?
    /// The selected app's bundle, as a single (non-expandable) tree node.
    @Published private(set) var appNode: JunkNode?
    /// One node per ~/Library folder holding the selected app's data.
    @Published private(set) var sections: [JunkNode] = []
    @Published private(set) var isScanningLeftovers = false
    @Published private(set) var isRemoving = false
    @Published var message: String?
    @Published var loading: Set<String> = []

    private var listToken = UUID()
    private var detailToken = UUID()
    private var icons: [String: NSImage] = [:]
    private var observers: [NSObjectProtocol] = []

    init() {
        // Re-evaluate "is it running?" as apps launch and quit.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in Task { @MainActor in self?.objectWillChange.send() }
            })
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: App list

    var visibleApps: [InstalledApp] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
        switch sortOrder {
        case .name: return filtered
        case .size: return filtered.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
        }
    }

    var selectedApp: InstalledApp? { apps.first { $0.id == selectedID } }

    func icon(for app: InstalledApp) -> NSImage {
        if let cached = icons[app.id] { return cached }
        let image = NSWorkspace.shared.icon(forFile: app.url.path)
        icons[app.id] = image
        return image
    }

    func reloadApps() {
        let token = UUID()
        listToken = token
        isLoadingApps = true
        let own = Bundle.main.bundleIdentifier
        Task.detached(priority: .userInitiated) {
            let found = AppUninstaller.installedApps(ownBundleID: own)
            await MainActor.run {
                guard self.listToken == token else { return }
                // Keep sizes already measured for apps that are still there.
                let known = Dictionary(self.apps.map { ($0.id, $0.bytes) },
                                       uniquingKeysWith: { a, _ in a })
                self.apps = found.map { app in
                    var app = app
                    app.bytes = known[app.id] ?? nil
                    return app
                }
                self.isLoadingApps = false
                if let id = self.selectedID, !self.apps.contains(where: { $0.id == id }) {
                    self.clearSelection()
                }
            }
            // Measure sizes one by one so the list fills in progressively.
            for app in found {
                let bytes = AppUninstaller.size(of: app.url)
                let stillCurrent = await MainActor.run { () -> Bool in
                    guard self.listToken == token else { return false }
                    if let index = self.apps.firstIndex(where: { $0.id == app.id }) {
                        self.apps[index].bytes = bytes
                    }
                    if self.appNode?.url == app.url, self.appNode?.bytes == 0 {
                        self.appNode = JunkNode(url: app.url, isDirectory: false, bytes: bytes,
                                                isSelected: self.appNode?.isSelected ?? true)
                    }
                    return true
                }
                if !stillCurrent { return }
            }
        }
    }

    // MARK: Selection

    func select(_ id: String?) {
        guard id != selectedID else { return }
        message = nil
        guard let id, let app = apps.first(where: { $0.id == id }) else {
            clearSelection()
            return
        }
        selectedID = id
        appNode = JunkNode(url: app.url, isDirectory: false, bytes: app.bytes ?? 0)
        sections = []
        scanLeftovers(for: app)
    }

    private func clearSelection() {
        selectedID = nil
        appNode = nil
        sections = []
        detailToken = UUID()
    }

    private func scanLeftovers(for app: InstalledApp) {
        let token = UUID()
        detailToken = token
        isScanningLeftovers = true
        let others = apps.filter { $0.id != app.id }
        Task.detached(priority: .userInitiated) {
            let found = AppUninstaller.leftovers(for: app, otherApps: others)
            found.forEach { $0.isExpanded = true }
            await MainActor.run {
                guard self.detailToken == token else { return }
                self.sections = found
                self.isScanningLeftovers = false
            }
        }
    }

    // MARK: Running state

    func isRunning(_ app: InstalledApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    }

    func quit(_ app: InstalledApp) {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            .forEach { $0.terminate() }
    }

    // MARK: Removal

    private var allNodes: [JunkNode] { (appNode.map { [$0] } ?? []) + sections }

    var chosen: [(url: URL, bytes: Int64)] {
        allNodes.flatMap { $0.removalTargets() }.map { ($0.url, $0.bytes) }
    }

    var chosenBytes: Int64 { allNodes.reduce(0) { $0 + $1.selectedBytes } }
    var removesApp: Bool { appNode?.check == .on }
    var leftoverBytes: Int64 { sections.reduce(0) { $0 + $1.bytes } }

    func uninstall() {
        guard let app = selectedApp, !isRunning(app) else { return }
        let items = chosen
        let removingApp = removesApp
        isRemoving = true
        message = nil
        Task.detached(priority: .userInitiated) {
            let result = AppUninstaller.remove(items, appURL: app.url)
            await MainActor.run {
                self.isRemoving = false
                var text = "Moved \(result.removedCount) items to the Trash ("
                    + Self.format(result.freedBytes) + ")."
                if !result.failures.isEmpty {
                    text += " \(result.failures.count) couldn't be removed: "
                        + result.failures.prefix(3).joined(separator: "; ")
                    result.failures.forEach { NSLog("Snappy: uninstall failed: \($0)") }
                }
                self.message = text
                let appGone = !FileManager.default.fileExists(atPath: app.url.path)
                if removingApp, appGone {
                    self.apps.removeAll { $0.id == app.id }
                    self.clearSelection()
                } else {
                    self.scanLeftovers(for: app)
                }
            }
        }
    }
}

struct AppUninstallerView: View {
    @ObservedObject var model: AppUninstallerModel
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 290)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert(confirmTitle, isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { model.uninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.chosen.count) items (\(AppUninstallerModel.format(model.chosenBytes))) "
                 + "will be moved to the Trash. You can put them back from the Trash if needed.")
        }
    }

    private var confirmTitle: String {
        guard let app = model.selectedApp else { return "" }
        return model.removesApp ? "Uninstall \(app.name)?" : "Remove \(app.name)'s selected files?"
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Search apps", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                Picker("Sort", selection: $model.sortOrder) {
                    ForEach(AppUninstallerModel.SortOrder.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
            }
            .padding([.horizontal, .top], 10)

            List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                ForEach(model.visibleApps) { app in
                    appRow(app).tag(app.id)
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if model.isLoadingApps && model.apps.isEmpty {
                    ProgressView("Finding apps\u{2026}")
                } else if !model.isLoadingApps && model.visibleApps.isEmpty {
                    Text(model.search.isEmpty ? "No removable apps found" : "No matches")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("\(model.apps.count) apps")
                Spacer()
                Button {
                    model.reloadApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh the app list")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding([.horizontal, .bottom], 10)
        }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: model.icon(for: app))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).lineLimit(1)
                if let version = app.version {
                    Text(version)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(app.bytes.map(AppUninstallerModel.format) ?? "\u{2026}")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let app = model.selectedApp {
            VStack(spacing: 0) {
                appHeader(app)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let node = model.appNode {
                            sectionTitle("Application")
                            JunkNodeRow(node: node, model: model, showsPath: true,
                                        icon: model.icon(for: app))
                        }
                        sectionTitle("Related Files in ~/Library")
                        if model.isScanningLeftovers {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Looking for related files\u{2026}").foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        } else if model.sections.isEmpty {
                            Text("No related files found.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(model.sections) { section in
                                JunkNodeRow(node: section, model: model, showsPath: true)
                            }
                            Text("Items that may belong to another app from the same developer "
                                 + "start unticked. Unfold any folder to choose exactly what to "
                                 + "remove.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                    }
                    .padding(16)
                }
                .disabled(model.isRemoving)
                Divider()
                footer(app)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "trash.square")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("Select an app to uninstall")
                    .foregroundStyle(.secondary)
                if let message = model.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
        }
    }

    private func appHeader(_ app: InstalledApp) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: model.icon(for: app))
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.title3).fontWeight(.semibold)
                Text([app.version.map { "Version \($0)" }, app.bundleID]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(app.bytes.map(AppUninstallerModel.format) ?? "\u{2026}")
                    .font(.headline)
                    .monospacedDigit()
                if model.leftoverBytes > 0 {
                    Text("+ \(AppUninstallerModel.format(model.leftoverBytes)) related files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func footer(_ app: InstalledApp) -> some View {
        let running = model.isRunning(app)
        return HStack(spacing: 10) {
            if running {
                Label("\(app.name) is running. Quit it before uninstalling.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                Button("Quit \(app.name)") { model.quit(app) }
            } else if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if model.isRemoving { ProgressView().controlSize(.small) }
            Button(model.removesApp ? "Uninstall\u{2026}" : "Remove Selected\u{2026}") {
                confirming = true
            }
            .keyboardShortcut(.defaultAction)
            .disabled(running || model.isRemoving || model.isScanningLeftovers
                      || model.chosen.isEmpty)
        }
        .padding(12)
    }
}
