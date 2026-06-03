import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuController = StatusMenuController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuController.install()
        HotkeyManager.registerAll()
        ensureAccessibilityPermission()
    }

    /// Window control via the Accessibility API requires the user to grant
    /// permission in System Settings ▸ Privacy & Security ▸ Accessibility.
    /// Prompt once on first launch.
    private func ensureAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !trusted {
            let alert = NSAlert()
            alert.messageText = "Accessibility permission needed"
            alert.informativeText = """
            Magnet needs Accessibility access to move and resize windows.
            Enable Magnet under System Settings ▸ Privacy & Security ▸ \
            Accessibility, then the shortcuts will work.
            """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                NSWorkspace.shared.open(url)
            }
        }
    }
}
