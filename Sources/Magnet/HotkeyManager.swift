import KeyboardShortcuts

/// Wires each global shortcut to its layout action.
@MainActor
enum HotkeyManager {
    static func registerAll() {
        for binding in LayoutBinding.all {
            KeyboardShortcuts.onKeyDown(for: binding.name) {
                WindowManager.apply(binding.layout)
            }
        }
    }
}
