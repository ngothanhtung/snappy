import AppKit
import SwiftUI
import KeyboardShortcuts
import SnappyCore

/// Owns the menu bar item and its menu, and hosts the settings window.
@MainActor
final class StatusMenuController: NSObject {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let claudeHeader = NSMenuItem.sectionHeader(title: "Claude Code")
    private var claudeItems: [NSMenuItem] = []

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarIcon.image()
        statusItem.menu = buildMenu()
        // Claude plan usage (Session / Weekly %) of the signed-in Claude Code account.
        let monitor = ClaudeLimitsMonitor.shared
        monitor.onChange = { [weak self] in self?.refreshClaudeItems() }
        monitor.retain()
        refreshClaudeItems()
    }

    /// Rebuilds the "Claude Code" section's lines in place.
    private func refreshClaudeItems() {
        guard let menu = statusItem.menu else { return }
        claudeItems.forEach { menu.removeItem($0) }
        claudeItems = makeClaudeItems()
        guard var index = menu.items.firstIndex(of: claudeHeader) else { return }
        for item in claudeItems {
            index += 1
            menu.insertItem(item, at: index)
        }
    }

    private func makeClaudeItems() -> [NSMenuItem] {
        let monitor = ClaudeLimitsMonitor.shared
        let now = Date()
        var items: [NSMenuItem] = []
        func info(_ title: String, symbol: String? = nil, indent: Int = 0) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = indent
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            items.append(item)
        }
        func line(_ name: String, _ w: ClaudeLimits.Window?) -> String? {
            guard let w else { return nil }
            let reset = ClaudeLimits.resetText(w.resetsAt, now: now)
            return "\(name) \(ClaudeLimits.percentText(w))" + (reset.isEmpty ? "" : " \u{00B7} \(reset)")
        }
        if let a = monitor.current {
            info([a.email, a.plan].compactMap { $0 }.joined(separator: " \u{00B7} "), symbol: "person.crop.circle")
            if let s = line("Session (5hr)", a.usage.session) { info(s, symbol: "gauge.with.needle") }
            if let w = line("Weekly (7 day)", a.usage.weekly) { info(w, symbol: "calendar") }
        }
        if let note = monitor.note { info(note, symbol: "exclamationmark.triangle") }
        else if monitor.current == nil { info("Loading Claude usage\u{2026}", symbol: "hourglass") }
        // Other accounts you rotate: last values seen while each was signed in.
        let tf = DateFormatter()
        tf.dateFormat = "dd/MM HH:mm"
        for o in monitor.others {
            let parts = [line("Session", o.usage.session), line("Weekly", o.usage.weekly)].compactMap { $0 }
            info("\(o.email ?? "Other account"): " + parts.joined(separator: " \u{00B7} ")
                 + " (as of \(tf.string(from: o.fetchedAt)))", symbol: "person.2")
        }
        let refresh = NSMenuItem(title: "Refresh Claude Usage", action: #selector(refreshClaude), keyEquivalent: "")
        refresh.target = self
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        items.append(refresh)
        return items
    }

    @objc private func refreshClaude() { ClaudeLimitsMonitor.shared.refresh() }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Same grouping as the Settings sections.
        menu.addItem(.sectionHeader(title: "Snap"))
        addActionItems(Bindings.layouts, to: menu)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Displays"))
        addActionItems(Bindings.displays, to: menu)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Capture"))
        addActionItems(Bindings.capture, to: menu)

        let openForEditing = NSMenuItem(
            title: "Open File in Annotate\u{2026}",
            action: #selector(openFileInAnnotate),
            keyEquivalent: ""
        )
        openForEditing.target = self
        openForEditing.image = NSImage(
            systemSymbolName: "photo.badge.arrow.down",
            accessibilityDescription: "Open File in Annotate"
        )
        menu.addItem(openForEditing)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Mini Display"))
        MiniDisplayController.shared.makeMenuItems().forEach(menu.addItem)

        menu.addItem(.separator())
        menu.addItem(claudeHeader)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Maintenance"))
        addActionItems(Bindings.maintenance, to: menu)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings),
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
            item.representedObject = binding.name.rawValue
            item.setShortcut(for: binding.name)
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

    @objc private func openFileInAnnotate() {
        AnnotationEditorController.shared.chooseFileAndOpen()
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
