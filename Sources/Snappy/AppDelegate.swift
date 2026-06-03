import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuController = StatusMenuController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuController.install()
        HotkeyManager.registerAll()
        // Prompt with the system dialog on first launch if not yet trusted.
        AccessibilityPermission.ensure(showSystemPrompt: true)
    }
}
