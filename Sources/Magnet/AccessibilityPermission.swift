import AppKit
import ApplicationServices

/// Centralizes the Accessibility (TCC) permission check + prompt.
///
/// Window control via the Accessibility API only works once the user grants
/// Magnet access under System Settings ▸ Privacy & Security ▸ Accessibility.
/// Note: the grant is tied to the app's code signature — an ad-hoc rebuild
/// changes the signature and revokes it, so re-granting may be required.
@MainActor
enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Checks trust; if missing, shows a prompt (optionally the system one)
    /// and offers to open System Settings. Returns the current trust state.
    @discardableResult
    static func ensure(showSystemPrompt: Bool = false) -> Bool {
        if showSystemPrompt {
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
            if AXIsProcessTrustedWithOptions(options as CFDictionary) { return true }
        } else if isTrusted {
            return true
        }
        presentAlert()
        return false
    }

    private static func presentAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility permission needed"
        alert.informativeText = """
        Magnet needs Accessibility access to move and resize windows.

        Open System Settings ▸ Privacy & Security ▸ Accessibility and enable \
        Magnet. If Magnet is already listed, remove it with “–” and add this \
        build again — a rebuilt app must be re-granted.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }
}
