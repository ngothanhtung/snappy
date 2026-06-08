import AppKit
import SwiftUI

/// Owns the menu bar item and its menu, and hosts the settings window.
@MainActor
final class StatusMenuController: NSObject {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarIcon.image()
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        addActionItems(Bindings.layouts, to: menu)
        menu.addItem(.separator())
        addActionItems(Bindings.displays, to: menu)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        menu.addItem(settings)

        let about = NSMenuItem(title: "About Snappy", action: #selector(showAbout),
                               keyEquivalent: "")
        about.target = self
        about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About Snappy")
        menu.addItem(about)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Snappy", action: #selector(quit),
                                  keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit Snappy")
        menu.addItem(quitItem)
        return menu
    }

    private func addActionItems(_ bindings: [ActionBinding], to menu: NSMenu) {
        for binding in bindings {
            let item = NSMenuItem(title: binding.title,
                                  action: #selector(triggerAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: binding.symbol,
                                 accessibilityDescription: binding.title)
            // Look the binding up again at click time via its shortcut name.
            item.representedObject = binding.name.rawValue
            menu.addItem(item)
        }
    }

    @objc private func triggerAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let binding = Bindings.all.first(where: { $0.name.rawValue == raw }) else { return }
        WindowManager.perform(binding.action)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.title = "Snappy Settings"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(
            string: "Author: Tony Woo (ngothanhtung.it@gmail.com)",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Snappy",
            .credits: credits,
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
