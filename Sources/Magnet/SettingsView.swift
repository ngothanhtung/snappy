import SwiftUI
import ServiceManagement
import KeyboardShortcuts

/// Settings window: record a shortcut per layout + toggle launch at login.
struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Shortcuts") {
                ForEach(LayoutBinding.all, id: \.name) { binding in
                    KeyboardShortcuts.Recorder(binding.title, name: binding.name)
                }
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

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Magnet: launch-at-login change failed: \(error)")
            // Reflect the real state if the change didn't take.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// Allow ForEach over bindings keyed by the shortcut name.
extension KeyboardShortcuts.Name: @retroactive Identifiable {
    public var id: String { rawValue }
}
