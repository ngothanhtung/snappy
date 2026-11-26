import AppKit
import SwiftUI
import KeyboardShortcuts
import SnappyCore

/// Owns the menu bar item and its four-column drop-down panel, and hosts the settings window.
@MainActor
final class StatusMenuController: NSObject {
    private var statusItem: NSStatusItem!
    private var panel: StatusPanelController!
    private var settingsWindow: NSWindow?
    private var settingsTabs: NSTabViewController?

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarIcon.image()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel(_:))
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        panel = StatusPanelController(commands: StatusPanelCommands(
            openFileInAnnotate: { [weak self] in self?.openFileInAnnotate() },
            openSettings: { [weak self] in self?.closePanelAndShowSettings(.general) },
            showAbout: { [weak self] in self?.showAbout() },
            quit: { NSApp.terminate(nil) }
        ))
        // Keep the panel sized to its content as displays come and go.
        DisplayControlCenter.shared.addObserver { [weak self] in
            // After SwiftUI has re-rendered the new content.
            DispatchQueue.main.async { self?.panel.fitContent() }
        }
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        panel.toggle(from: sender)
    }

    private func closePanelAndShowSettings(_ tab: SettingsTab) {
        panel.close()
        showSettings(tab)
    }

    @objc private func openSettings() {
        showSettings(.general)
    }

    func showSettings(_ tab: SettingsTab) {
        if settingsWindow == nil {
            // Standard Mac settings window: tabs as toolbar items; the window
            // resizes to each tab.
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            // Keep the window titled "Settings" instead of taking each tab's (empty) title.
            tabs.canPropagateSelectedChildViewControllerTitle = false
            for t in SettingsTab.allCases {
                let host = NSHostingController(rootView: SettingsView(tab: t))
                host.sizingOptions = [.preferredContentSize]
                let item = NSTabViewItem(viewController: host)
                item.label = t.title
                item.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
                item.identifier = t.rawValue
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            settingsTabs = tabs
            settingsWindow = window
        }
        if let index = SettingsTab.allCases.firstIndex(of: tab) {
            settingsTabs?.selectedTabViewItemIndex = index
        }
        if settingsWindow?.isVisible == false { settingsWindow?.center() }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func openFileInAnnotate() {
        AnnotationEditorController.shared.chooseFileAndOpen()
    }

    private func showAbout() {
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

}
