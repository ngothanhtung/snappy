import SwiftUI
import ServiceManagement
import KeyboardShortcuts

/// Settings window: record a shortcut per layout + toggle launch at login.
struct SettingsView: View {
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
        Form {
            Section("Snap") {
                ForEach(Bindings.layouts, id: \.name) { binding in
                    recorderRow(for: binding)
                }
            }
            Section("Displays") {
                ForEach(Bindings.displays, id: \.name) { binding in
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
                Toggle("Photos panel", isOn: Binding(
                    get: { miniDisplay.showsPhotos },
                    set: { miniDisplay.setShowsPhotos($0) }
                ))
                .toggleStyle(.switch)
                .disabled(!miniDisplay.isEnabled)
                if miniDisplay.showsPhotos {
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
                LabeledContent("Status", value: miniDisplay.photosProblem.map {
                    "\(miniDisplay.statusText) \u{00B7} \($0)"
                } ?? miniDisplay.statusText)
            } header: {
                Text("Mini Display")
            } footer: {
                Text("Streams CPU, GPU, RAM, storage, network and a clock to a Jungle Leopard "
                     + "USB screen (e.g. 9.16\"). The photos panel shows a random photo from your "
                     + "Photos library from the chosen album in a panel on the right (frame shape selectable), crossfading between them. Brightness is applied in software because the "
                     + "panel's firmware ignores backlight commands.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
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
