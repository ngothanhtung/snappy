import KeyboardShortcuts

/// Wires each global shortcut to its action.
@MainActor
enum HotkeyManager {
    static func registerAll() {
        for binding in Bindings.all {
            KeyboardShortcuts.onKeyDown(for: binding.name) {
                WindowManager.perform(binding.action)
            }
        }
    }
}
