import AppKit
import SnappyCore

/// Builds the pop-up menus behind the status panel's display rows: per display
/// (contrast/volume, resolution, refresh rate, rotation, mirroring, main
/// display, disconnect).
@MainActor
final class DisplaysMenu: NSObject {
    private enum Kind { case brightness, contrast, volume }
    private var sliders: [(id: CGDirectDisplayID, kind: Kind, view: MenuSliderView)] = []
    private var muteItems: [(id: CGDirectDisplayID, item: NSMenuItem)] = []

    private var center: DisplayControlCenter { .shared }

    override init() {
        super.init()
        DisplayControlCenter.shared.addObserver { [weak self] in self?.updateValues() }
    }

    /// Submenu with everything about one display (popped up from the status panel).
    func menu(for d: DisplayInfo) -> NSMenu {
        muteItems.removeAll { $0.id == d.id }
        sliders.removeAll { $0.id == d.id }
        let menu = submenu(for: d)
        updateValues()
        return menu
    }

    func subtitle(for d: DisplayInfo) -> String {
        var parts: [String] = []
        if let master = d.mirrorMaster {
            parts.append("Mirroring \(center.displays.first { $0.id == master }?.name ?? "another display")")
        } else if let m = DisplayConfigurator.currentMode(of: d.id) {
            parts.append("\(m.width) \u{00D7} \(m.height)\(m.isHiDPI ? " HiDPI" : "") \u{00B7} \(m.roundedRefreshRate) Hz")
        }
        if d.isMain { parts.append("Main") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func submenu(for d: DisplayInfo) -> NSMenu {
        let menu = NSMenu()
        let c = center.controls[d.id]

        var hasLevels = false
        if c?.contrast != nil, let row = sliderRow(.contrast, for: d) { menu.addItem(row); hasLevels = true }
        if c?.volume != nil, let row = sliderRow(.volume, for: d) {
            menu.addItem(row)
            let mute = ActionItem("Mute", symbol: "speaker.slash") { [weak self] in self?.center.toggleMute(for: d.id) }
            muteItems.append((d.id, mute))
            menu.addItem(mute)
            hasLevels = true
        }
        if let method = c?.brightnessMethod, method != .none {
            let note = NSMenuItem(title: Self.methodLabel(method), action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            hasLevels = true
        }
        if hasLevels { menu.addItem(.separator()) }

        if !d.isMirroring {
            addModeItems(for: d, to: menu)
        }
        if DisplayConfigurator.canRotate(d.id) {
            menu.addItem(rotationItem(d))
        }
        menu.addItem(mirrorItem(d))
        menu.addItem(.separator())

        let main = ActionItem("Set as Main Display", symbol: "menubar.rectangle") { [weak self] in
            self?.center.makeMain(d.id)
        }
        main.isEnabled = !d.isMain && !d.isMirroring
        menu.addItem(main)

        if DisplayConfigurator.canToggleDisplays {
            menu.addItem(ActionItem("Disconnect\u{2026}", symbol: "eject") { [weak self] in
                self?.center.disconnect(d)
            })
        }
        return menu
    }

    private static func methodLabel(_ m: BrightnessMethod) -> String {
        switch m {
        case .native: return "Brightness: built-in control"
        case .ddc: return "Brightness: hardware (DDC/CI)"
        case .software: return "Brightness: software dimming"
        case .none: return ""
        }
    }

    // MARK: Resolution / refresh rate

    private func addModeItems(for d: DisplayInfo, to menu: NSMenu) {
        let modes = DisplayConfigurator.modes(of: d.id).map(\.info)
        let current = DisplayConfigurator.currentMode(of: d.id)
        let resolutions = DisplayModeCatalog.resolutions(modes)
        guard !resolutions.isEmpty else { return }

        let resMenu = NSMenu()
        let currentRes = current.map(DisplayResolution.init)
        for (title, hiDPI) in [("HiDPI", true), ("Low Resolution", false)] {
            let group = resolutions.filter { $0.isHiDPI == hiDPI }
            guard !group.isEmpty else { continue }
            resMenu.addItem(.sectionHeader(title: title))
            for r in group {
                let item = ActionItem(r.label, symbol: nil) { [weak self] in
                    guard let m = DisplayModeCatalog.mode(for: r, keepingRateOf: current, in: modes) else { return }
                    self?.center.setMode(m.id, for: d.id)
                }
                item.state = r == currentRes ? .on : .off
                resMenu.addItem(item)
            }
        }
        let resItem = NSMenuItem(title: "Resolution", action: nil, keyEquivalent: "")
        resItem.image = NSImage(systemSymbolName: "rectangle.arrowtriangle.2.outward", accessibilityDescription: nil)
        if #available(macOS 14.4, *), let currentRes {
            resItem.subtitle = currentRes.label + (currentRes.isHiDPI ? " HiDPI" : "")
        }
        resItem.submenu = resMenu
        menu.addItem(resItem)

        guard let current, let currentRes else { return }
        let rates = DisplayModeCatalog.refreshRates(for: currentRes, in: modes)
        guard rates.count > 1 else { return }
        let rateMenu = NSMenu()
        for rate in rates {
            let item = ActionItem("\(rate) Hz", symbol: nil) { [weak self] in
                guard let m = DisplayModeCatalog.mode(forRate: rate, at: current, in: modes) else { return }
                self?.center.setMode(m.id, for: d.id)
            }
            item.state = rate == current.roundedRefreshRate ? .on : .off
            rateMenu.addItem(item)
        }
        let rateItem = NSMenuItem(title: "Refresh Rate", action: nil, keyEquivalent: "")
        rateItem.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: nil)
        if #available(macOS 14.4, *) { rateItem.subtitle = "\(current.roundedRefreshRate) Hz" }
        rateItem.submenu = rateMenu
        menu.addItem(rateItem)
    }

    // MARK: Rotation / mirroring

    private func rotationItem(_ d: DisplayInfo) -> NSMenuItem {
        let current = DisplayConfigurator.rotation(of: d.id)
        let sub = NSMenu()
        for deg in DisplayRotation.all {
            let item = ActionItem(DisplayRotation.label(deg), symbol: nil) { [weak self] in
                self?.center.rotate(d.id, to: deg)
            }
            item.state = deg == current ? .on : .off
            sub.addItem(item)
        }
        let item = NSMenuItem(title: "Rotation", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "rotate.right", accessibilityDescription: nil)
        item.submenu = sub
        return item
    }

    private func mirrorItem(_ d: DisplayInfo) -> NSMenuItem {
        let sub = NSMenu()
        let isMaster = center.displays.contains { $0.mirrorMaster == d.id }
        let off = ActionItem("Off", symbol: nil) { [weak self] in
            if d.isMirroring { self?.center.mirror(d.id, of: nil) } else { self?.center.stopMirroring(into: d.id) }
        }
        off.state = d.isInMirrorSet ? .off : .on
        sub.addItem(off)
        if isMaster {
            let note = NSMenuItem(title: "Other displays mirror \(d.name)", action: nil, keyEquivalent: "")
            note.isEnabled = false
            sub.addItem(note)
        } else {
            let targets = DisplayConfigurator.topLevel(center.displays).filter { $0.id != d.id }
            if !targets.isEmpty { sub.addItem(.separator()) }
            for t in targets {
                let item = ActionItem("Mirror \(t.name)", symbol: nil) { [weak self] in
                    self?.center.mirror(d.id, of: t.id)
                }
                item.state = d.mirrorMaster == t.id ? .on : .off
                sub.addItem(item)
            }
        }
        let item = NSMenuItem(title: "Mirror", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
        item.submenu = sub
        return item
    }

    // MARK: Sliders

    private func sliderRow(_ kind: Kind, for d: DisplayInfo) -> NSMenuItem? {
        let c = center.controls[d.id]
        if kind == .brightness, c?.brightnessMethod == BrightnessMethod.none, c?.probing != true { return nil }
        let symbol: String
        switch kind {
        case .brightness: symbol = "sun.max"
        case .contrast: symbol = "circle.lefthalf.filled"
        case .volume: symbol = "speaker.wave.2"
        }
        let view = MenuSliderView(symbol: symbol) { [weak self] v in
            guard let self else { return }
            switch kind {
            case .brightness: self.center.setBrightness(v, for: d.id)
            case .contrast: self.center.setContrast(v, for: d.id)
            case .volume: self.center.setVolume(v, for: d.id)
            }
        }
        sliders.append((d.id, kind, view))
        let item = NSMenuItem()
        item.view = view
        return item
    }

    /// Pushes current levels into the visible sliders (after a DDC read finishes, a hotkey, …).
    func updateValues() {
        let controls = center.controls
        for s in sliders {
            let c = controls[s.id]
            let value: Double?
            switch s.kind {
            case .brightness: value = c?.brightnessMethod == BrightnessMethod.none ? nil : c?.brightness
            case .contrast: value = c?.contrast
            case .volume: value = c?.muted == true ? 0 : c?.volume
            }
            s.view.update(value: value)
        }
        for m in muteItems { m.item.state = controls[m.id]?.muted == true ? .on : .off }
    }
}

/// Menu item running a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String?, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

/// Icon + continuous slider + percentage, for use as a menu item's view.
final class MenuSliderView: NSView {
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let label = NSTextField(labelWithString: "")
    private let onChange: (Double) -> Void

    init(symbol: String, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        autoresizingMask = [.width]

        let icon = NSImageView(frame: NSRect(x: 14, y: 6, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)

        slider.frame = NSRect(x: 38, y: 4, width: 260 - 38 - 54, height: 20)
        slider.autoresizingMask = [.width]
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        addSubview(slider)

        label.frame = NSRect(x: 260 - 48, y: 6, width: 38, height: 16)
        label.autoresizingMask = [.minXMargin]
        label.alignment = .right
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(value: Double?) {
        slider.isEnabled = value != nil
        if let value {
            slider.doubleValue = value
            label.stringValue = DisplayLevel.percent(value)
        } else {
            label.stringValue = "\u{2026}"
        }
    }

    @objc private func changed() {
        label.stringValue = DisplayLevel.percent(slider.doubleValue)
        onChange(slider.doubleValue)
    }
}
