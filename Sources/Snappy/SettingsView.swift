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
