import SwiftUI
import ServiceManagement
import KeyboardShortcuts
import SnappyCore

/// Tabs of the Settings window (toolbar-style, like System Settings panes of other Mac apps).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, shortcuts, displays, miniDisplay, cloud
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .displays: return "Displays"
        case .miniDisplay: return "Mini Display"
        case .cloud: return "Cloud"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .displays: return "display.2"
        case .miniDisplay: return "rectangle.inset.filled"
        case .cloud: return "icloud.and.arrow.up"
        }
    }

    /// Content size; the window resizes to it when the tab is picked.
    var size: CGSize {
        switch self {
        case .general: return CGSize(width: 520, height: 96)
        case .shortcuts: return CGSize(width: 520, height: 560)
        case .displays: return CGSize(width: 520, height: 360)
        case .miniDisplay: return CGSize(width: 520, height: 640)
        case .cloud: return CGSize(width: 520, height: 520)
        }
    }
}

/// One tab of the Settings window; `StatusMenuController` hosts one per toolbar item.
struct SettingsView: View {
    let tab: SettingsTab
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(GoogleDriveClient.clientIDDefaultsKey) private var driveClientID = ""
    @AppStorage(GoogleDriveClient.clientSecretDefaultsKey) private var driveClientSecret = ""
    @State private var driveSignedIn = GoogleDriveClient.shared.isSignedIn
    @AppStorage(GitHubUploader.repoDefaultsKey) private var githubRepo = ""
    @AppStorage(GitHubUploader.branchDefaultsKey) private var githubBranch = ""
    @AppStorage(GitHubUploader.folderDefaultsKey) private var githubFolder = "snappy"
    @State private var githubTokenInput = ""
    @State private var githubHasToken = GitHubUploader.shared.hasToken
    @ObservedObject private var miniDisplay = MiniDisplayController.shared
    @State private var photoAlbums: [MiniDisplayPhotoAlbum] = []

    var body: some View {
        Group {
            switch tab {
            case .general: generalTab
            case .shortcuts: shortcutsTab
            case .displays: DisplaySettingsView()
            case .miniDisplay: miniDisplayTab
            case .cloud: cloudTab
            }
        }
        .frame(width: tab.size.width, height: tab.size.height)
    }

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
            }
        }
        .formStyle(.grouped)
    }

    private var shortcutsTab: some View {
        Form {
            Section("Snap") {
                ForEach(Bindings.layouts + Bindings.displays, id: \.name) { binding in
                    recorderRow(for: binding)
                }
            }
            Section("Display Controls") {
                ForEach(Bindings.displayControls, id: \.name) { binding in
                    recorderRow(for: binding)
                }
            }
            Section("Capture") {
                ForEach(Bindings.capture, id: \.name) { binding in
                    recorderRow(for: binding)
                }
            }
            Section("Maintenance") {
                ForEach(Bindings.maintenance, id: \.name) { binding in
                    recorderRow(for: binding)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var miniDisplayTab: some View {
        Form {
            Section {
                Toggle("Sync", isOn: Binding(
                    get: { miniDisplay.isEnabled },
                    set: { miniDisplay.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                LabeledContent("Brightness") {
                    Slider(value: Binding(
                        get: { Double(miniDisplay.brightness) },
                        set: { miniDisplay.setBrightness(Int($0.rounded())) }
                    ), in: 0...100)
                    .disabled(!miniDisplay.isEnabled)
                }
                Picker("Theme", selection: Binding(
                    get: { miniDisplay.theme.id },
                    set: { miniDisplay.setTheme(MiniDisplayTheme.named($0)) }
                )) {
                    ForEach(MiniDisplayTheme.all) { t in
                        Text(t.name).tag(t.id)
                    }
                }
                ThemeSwatches(theme: miniDisplay.theme)
                LabeledContent("Status", value: miniDisplay.photosProblem.map {
                    "\(miniDisplay.statusText) \u{00B7} \($0)"
                } ?? miniDisplay.statusText)
            } header: {
                Text("Mini Display")
            }
            Section {
                SlotGridEditor(layout: miniDisplay.layout) { widget, column, top in
                    miniDisplay.setWidget(widget, column: column, top: top)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                Stepper(value: Binding(
                    get: { miniDisplay.layout.columns.count },
                    set: { miniDisplay.setColumnCount($0) }
                ), in: 1...MiniDisplayLayout.maxColumns) {
                    Text("Columns: \(miniDisplay.layout.columns.count)")
                }
                Button("Reset to Default") { miniDisplay.setLayout(.standard) }
            } header: {
                Text("Widgets")
            } footer: {
                Text("Click a slot to choose its widget. The mini display is a grid of columns with two rows; every widget takes one slot. "
                     + "A widget alone in its column fills the full height, empty columns are skipped, and Photos "
                     + "always takes a whole column shaped by its frame. Claude Usage shows the Session (5hr) and "
                     + "Weekly (7 day) usage of the account Claude Code is signed in to (macOS asks once for Keychain access).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!miniDisplay.isEnabled)
            if miniDisplay.showsPhotos {
                Section("Photos") {
                    Picker("Album", selection: Binding(
                        get: { miniDisplay.photoAlbumID },
                        set: { miniDisplay.setPhotoAlbum($0) }
                    )) {
                        if photoAlbums.isEmpty {
                            Text("All Photos").tag(MiniDisplayPhotoAlbum.allPhotosID)
                        }
                        ForEach(photoAlbums) { album in
                            Text("\(album.title) (\(album.count))").tag(album.id)
                        }
                    }
                    .onAppear { photoAlbums = miniDisplay.photoAlbums() }
                    Picker("Frame", selection: Binding(
                        get: { miniDisplay.photoAspect },
                        set: { miniDisplay.setPhotoAspect($0) }
                    )) {
                        ForEach(MiniDisplayPhotoAspect.all) { a in Text(a.id).tag(a) }
                    }
                    Picker("Change every", selection: Binding(
                        get: { miniDisplay.photoInterval },
                        set: { miniDisplay.setPhotoInterval($0) }
                    )) {
                        ForEach(MiniDisplayController.photoIntervals, id: \.self) { sec in
                            Text(MiniDisplayController.intervalLabel(sec)).tag(sec)
                        }
                    }
                }
                .disabled(!miniDisplay.isEnabled)
            }
        }
        .formStyle(.grouped)
    }

    private var cloudTab: some View {
        Form {
            Section {
                if !GoogleDriveClient.hasBundledCredentials {
                    TextField("Client ID", text: $driveClientID)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Client Secret", text: $driveClientSecret)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text(driveSignedIn ? "Connected" : "Not connected")
                        .foregroundStyle(driveSignedIn ? .green : .secondary)
                    Spacer()
                    if driveSignedIn {
                        Button("Sign Out") {
                            GoogleDriveClient.shared.signOut()
                            driveSignedIn = false
                        }
                    }
                }
            } header: {
                Text("Google Drive")
            } footer: {
                Text(GoogleDriveClient.hasBundledCredentials
                     ? "Using the app's built-in OAuth credentials. "
                       + "The Drive button in Annotate signs in on first use."
                     : "Create an OAuth client (type: Desktop app) in Google Cloud Console "
                       + "with the Drive API enabled, then paste its ID and secret here. "
                       + "The Drive button in Annotate signs in on first use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Repository (owner/name)", text: $githubRepo)
                    .textFieldStyle(.roundedBorder)
                TextField("Branch (empty = default branch)", text: $githubBranch)
                    .textFieldStyle(.roundedBorder)
                TextField("Folder in repository", text: $githubFolder)
                    .textFieldStyle(.roundedBorder)
                if githubHasToken {
                    HStack {
                        Text("Token saved")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Remove Token") {
                            GitHubUploader.shared.clearToken()
                            githubHasToken = false
                        }
                    }
                } else {
                    HStack {
                        SecureField("Personal Access Token", text: $githubTokenInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            GitHubUploader.shared.setToken(githubTokenInput)
                            githubTokenInput = ""
                            githubHasToken = GitHubUploader.shared.hasToken
                        }
                        .disabled(githubTokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } header: {
                Text("GitHub")
            } footer: {
                Text("Uploads commit the image into the folder above. Use a fine-grained "
                     + "personal access token limited to this repository with Contents "
                     + "read & write permission. The token is stored in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Same symbol + title as the status menu, sourced from `Bindings`.
    private func recorderRow(for binding: ActionBinding) -> some View {
        KeyboardShortcuts.Recorder(for: binding.name) {
            Label {
                Text(binding.title)
            } icon: {
                Image(systemName: binding.symbol)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Snappy: launch-at-login change failed: \(error)")
            // Reflect the real state if the change didn't take.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// Allow ForEach over bindings keyed by the shortcut name.
extension KeyboardShortcuts.Name: @retroactive Identifiable {
    public var id: String { rawValue }
}

/// The n × 2 slot grid of the mini display; click a slot to pick its widget.
private struct SlotGridEditor: View {
    let layout: MiniDisplayLayout
    let onPick: (MiniDisplayWidget?, Int, Bool) -> Void

    private struct Slot: Hashable { let column: Int; let top: Bool }
    @State private var editing: Slot?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(layout.columns.indices, id: \.self) { c in
                VStack(spacing: 6) {
                    if layout.isPhotoColumn(c) {
                        cell(Slot(column: c, top: true), widget: .photo)
                    } else {
                        cell(Slot(column: c, top: true), widget: layout.columns[c].top)
                        cell(Slot(column: c, top: false), widget: layout.columns[c].bottom)
                    }
                }
            }
        }
        .frame(height: 150)
    }

    private func cell(_ slot: Slot, widget: MiniDisplayWidget?) -> some View {
        Button {
            editing = slot
        } label: {
            VStack(spacing: 4) {
                Image(systemName: widget?.symbol ?? "plus")
                    .font(.system(size: 15))
                Text(widget?.title ?? "Empty")
                    .font(.system(size: 10))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(widget == nil ? Color.secondary : Color.primary)
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(widget == nil ? Color.secondary.opacity(0.08) : Color.accentColor.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(editing == slot ? Color.accentColor : Color.secondary.opacity(0.3),
                              style: StrokeStyle(lineWidth: editing == slot ? 2 : 1,
                                                 dash: widget == nil ? [4, 3] : [])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(widget.map { "\($0.title) \u{2014} click to change" } ?? "Click to add a widget")
        .popover(isPresented: Binding(get: { editing == slot }, set: { if !$0 { editing = nil } }),
                 arrowEdge: .bottom) {
            WidgetChooser(current: widget) { picked in
                onPick(picked, slot.column, slot.top)
                editing = nil
            }
        }
    }
}

/// Popover list: every widget plus "Empty"; the current one is checked.
private struct WidgetChooser: View {
    let current: MiniDisplayWidget?
    let onPick: (MiniDisplayWidget?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(nil, title: "Empty", symbol: "square.dashed")
            Divider().padding(.vertical, 2)
            ForEach(MiniDisplayWidget.allCases) { w in
                row(w, title: w.spansColumn ? w.title + " (whole column)" : w.title, symbol: w.symbol)
            }
        }
        .padding(8)
        .frame(width: 230)
    }

    private func row(_ w: MiniDisplayWidget?, title: String, symbol: String) -> some View {
        Button {
            onPick(w)
        } label: {
            HStack {
                Image(systemName: symbol).frame(width: 20)
                Text(title)
                Spacer()
                if w == current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(w == current ? Color.accentColor.opacity(0.15) : Color.clear))
    }
}

/// Strip of the theme's background, card and accent colours.
private struct ThemeSwatches: View {
    let theme: MiniDisplayTheme

    private func color(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }

    var body: some View {
        let t = theme
        HStack(spacing: 6) {
            Text("Aa")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(color(t.text))
            ForEach(Array([t.cpu, t.gpu, t.memory, t.network, t.storage, t.claude, t.lunar].enumerated()),
                    id: \.offset) { _, c in
                Circle().fill(color(c)).frame(width: 12, height: 12)
            }
            Spacer(minLength: 0)
            Text("CPU 23%")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color(t.textDim))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [color(t.backgroundTop), color(t.backgroundBottom)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color(t.tint, t.strokeAlpha * 2)))
    }
}
