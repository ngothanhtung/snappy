import AppKit

@main
enum Main {
    @MainActor
    static func main() {
        // Agent app: no Dock icon, lives only in the menu bar.
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
