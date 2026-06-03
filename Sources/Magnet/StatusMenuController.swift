import AppKit
import SwiftUI
import MagnetCore

/// Owns the menu bar item and its menu, and hosts the settings window.
@MainActor
final class StatusMenuController: NSObject {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.split.2x1",
                                   accessibilityDescription: "Magnet")
        }
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        for binding in LayoutBinding.all {
            let item = NSMenuItem(title: binding.title,
                                  action: #selector(triggerLayout(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = binding.layout.rawValue
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Magnet", action: #selector(quit),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func triggerLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let layout = WindowLayout(rawValue: raw) else { return }
        WindowManager.apply(layout)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.title = "Magnet Settings"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
