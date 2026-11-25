import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuController = StatusMenuController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuController.install()
        HotkeyManager.registerAll()
        // Prompt with the system dialog on first launch if not yet trusted.
        AccessibilityPermission.ensure(showSystemPrompt: true)
        MiniDisplayController.shared.startIfEnabled()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Close the panel session so it doesn't freeze on the last frame.
        MiniDisplayController.shared.shutdown()
    }
}
