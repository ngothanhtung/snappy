import AppKit
import SwiftUI
import KeyboardShortcuts
import SnappyCore

/// Things the status panel's buttons do besides `AppAction`s.
@MainActor
struct StatusPanelCommands {
    var openFileInAnnotate: () -> Void
    var openSettings: () -> Void
    var showAbout: () -> Void
    var quit: () -> Void
}

/// Borderless panel that can take key status without activating Snappy, so
/// the app the user was in stays frontmost (window snapping acts on it).
private final class StatusPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The status item's drop-down: a four-column, menu-like panel
/// (Snap · Displays · Capture · Maintenance & the rest).
@MainActor
final class StatusPanelController {
    private let panel: StatusPanelWindow
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private let displaysMenu = DisplaysMenu()
    private var monitors: [Any] = []
    private weak var anchor: NSStatusBarButton?
    let commands: StatusPanelCommands

    var isShown: Bool { panel.isVisible }

    init(commands: StatusPanelCommands) {
        self.commands = commands
        panel = StatusPanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let fx = NSVisualEffectView()
        fx.material = .menu
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 10
        fx.layer?.masksToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            host.topAnchor.constraint(equalTo: fx.topAnchor),
            host.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        panel.contentView = fx
    }

    func toggle(from button: NSStatusBarButton) {
        isShown ? close() : show(from: button)
    }

    func show(from button: NSStatusBarButton) {
        anchor = button
        DisplayControlCenter.shared.refreshLevels()
        // Fresh view each time: shortcut labels may have changed in Settings.
        host.rootView = AnyView(StatusPanelView(displaysMenu: displaysMenu, commands: commands,
                                                close: { [weak self] in self?.close() }))
        let size = host.fittingSize
        panel.setContentSize(size)
        position(size: size)
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        installMonitors()
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        anchor?.highlight(false)
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    /// Keeps the panel the right size when its content grows (e.g. a display appears).
    func fitContent() {
        guard panel.isVisible else { return }
        let size = host.fittingSize
        guard size != panel.frame.size else { return }
        panel.setContentSize(size)
        position(size: size)
    }

    private func position(size: NSSize) {
        guard let button = anchor, let window = button.window else { return }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? buttonFrame
        var x = buttonFrame.midX - size.width / 2
        x = min(max(x, visible.minX + 6), visible.maxX - size.width - 6)
        let y = buttonFrame.minY - 4 - size.height
        panel.setFrameOrigin(NSPoint(x: x, y: max(y, visible.minY + 6)))
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        // Clicks in other apps / the desktop close it, like a menu.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            let command = e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            return MainActor.assumeIsolated {
                guard let self, self.isShown else { return e }
                if e.keyCode == 53 { // Escape
                    self.close()
                } else if command, e.charactersIgnoringModifiers == "," {
                    self.commands.openSettings()
                } else if command, e.charactersIgnoringModifiers == "q" {
                    self.commands.quit()
                } else {
                    return e
                }
                return nil
            }
        }) { monitors.append(m) }
    }
}

// MARK: - Content

private struct StatusPanelView: View {
    let displaysMenu: DisplaysMenu
    let commands: StatusPanelCommands
    let close: () -> Void

    @ObservedObject private var center = DisplayControlCenter.shared
    @ObservedObject private var miniDisplay = MiniDisplayController.shared

    private static let columnWidth: CGFloat = 270

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            column("Snap") {
                actionRows(Bindings.layouts)
                actionRows(Bindings.displays)
            }
            Divider()
            column("Displays") {
                displaysSection
            }
            Divider()
            column("Capture") {
                actionRows(Bindings.capture)
                PanelRow(symbol: "photo.badge.arrow.down", title: "Open File in Annotate\u{2026}") {
                    run(commands.openFileInAnnotate)
                }
            }
            Divider()
            column("Maintenance") {
                actionRows(Bindings.maintenance)
                SectionHeader("Mini Display")
                miniDisplaySection
                Divider().padding(.vertical, 5).padding(.horizontal, 10)
                PanelRow(symbol: "gearshape", title: "Settings\u{2026}", shortcut: "\u{2318},") {
                    run(commands.openSettings)
                }
                PanelRow(symbol: "info.circle", title: "About Snappy") { run(commands.showAbout) }
                Divider().padding(.vertical, 5).padding(.horizontal, 10)
                PanelRow(symbol: "power", title: "Quit Snappy", shortcut: "\u{2318}Q") { commands.quit() }
            }
        }
        .padding(.vertical, 6)
        .fixedSize()
    }

    private func column<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title)
            content()
        }
        .frame(width: Self.columnWidth, alignment: .topLeading)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func actionRows(_ bindings: [ActionBinding]) -> some View {
        ForEach(bindings, id: \.name) { b in
            PanelRow(symbol: b.symbol, title: b.title,
                     shortcut: KeyboardShortcuts.getShortcut(for: b.name)?.description) {
                let action = b.action
                run { WindowManager.perform(action) }
            }
        }
    }

    /// Closes first so window actions hit the user's window and captures don't include the panel.
    private func run(_ action: @escaping () -> Void) {
        close()
        DispatchQueue.main.async(execute: action)
    }

    // MARK: Displays

    @ViewBuilder
    private var displaysSection: some View {
        ForEach(center.displays) { d in
            DisplayBlock(display: d, controls: center.controls[d.id],
                         subtitle: displaysMenu.subtitle(for: d),
                         makeMenu: { displaysMenu.menu(for: d) },
                         setBrightness: { center.setBrightness($0, for: d.id) })
        }
        ForEach(center.disabled.sorted(by: { $0.key < $1.key }), id: \.key) { id, name in
            PanelRow(symbol: "display.trianglebadge.exclamationmark", title: "Reconnect \(name)") {
                center.reconnect(id)
            }
        }
    }

    // MARK: Mini display

    @ViewBuilder
    private var miniDisplaySection: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.inset.filled").frame(width: 18)
            Text(miniDisplay.photosProblem.map { "\(miniDisplay.statusText) \u{00B7} \($0)" } ?? miniDisplay.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath").frame(width: 18)
            Text("Sync")
            Spacer()
            Toggle("", isOn: Binding(get: { miniDisplay.isEnabled }, set: { miniDisplay.setEnabled($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }
}

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 3)
    }
}

/// Menu-item-like row: icon, title, shortcut; highlights on hover.
private struct PanelRow: View {
    let symbol: String
    let title: String
    var shortcut: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18)
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut).foregroundStyle(hovering ? Color.white.opacity(0.85) : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Row that pops up an AppKit menu below itself.
private struct PopupRow: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    let makeMenu: () -> NSMenu

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption).lineLimit(1)
                        .foregroundStyle(hovering ? Color.white.opacity(0.85) : .secondary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(hovering ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.accentColor : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .overlay(MenuPopupTrigger(makeMenu: makeMenu))
    }
}

/// One display: name row (pops its menu) and brightness slider.
private struct DisplayBlock: View {
    let display: DisplayInfo
    let controls: DisplayControls?
    let subtitle: String
    let makeMenu: () -> NSMenu
    let setBrightness: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopupRow(symbol: display.isBuiltin ? "laptopcomputer" : "display",
                     title: display.name, subtitle: subtitle.isEmpty ? nil : subtitle, makeMenu: makeMenu)
            if let c = controls, c.brightnessMethod != .none || c.probing {
                HStack(spacing: 8) {
                    Image(systemName: "sun.max").foregroundStyle(.secondary).frame(width: 18)
                    Slider(value: Binding(get: { c.brightness ?? 0 }, set: setBrightness), in: 0...1)
                        .controlSize(.small)
                        .disabled(c.brightness == nil)
                    Text(c.brightness.map(DisplayLevel.percent) ?? "\u{2026}")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }
        }
    }
}

/// Transparent click target that pops up an NSMenu under the row.
private struct MenuPopupTrigger: NSViewRepresentable {
    let makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> TriggerView {
        let v = TriggerView()
        v.makeMenu = makeMenu
        return v
    }

    func updateNSView(_ v: TriggerView, context: Context) { v.makeMenu = makeMenu }

    final class TriggerView: NSView {
        var makeMenu: (() -> NSMenu)?
        override func mouseDown(with event: NSEvent) {
            guard let menu = makeMenu?() else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX, y: bounds.maxY), in: self)
        }
        // Clicks reach this view, hover still reaches SwiftUI underneath.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
