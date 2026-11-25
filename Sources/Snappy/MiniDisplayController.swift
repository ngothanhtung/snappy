import AppKit
import SwiftUI

/// Owns the mini-display engine (Jungle Leopard USB panel dashboard), its
/// persisted settings, and the menu items shown in the status menu.
/// Settings: `miniDisplayEnabled` (default on) and `miniDisplayBrightness` (0–100).
@MainActor
final class MiniDisplayController: ObservableObject {
    static let shared = MiniDisplayController()

    static let enabledKey = "miniDisplayEnabled"
    static let brightnessKey = "miniDisplayBrightness"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var brightness: Int
    @Published private(set) var state: MiniDisplayEngine.State = .stopped

    private let engine: MiniDisplayEngine
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Sync", action: nil, keyEquivalent: "")
    private let brightnessLabel = NSTextField(labelWithString: "")
    private let brightnessSlider = NSSlider(value: 80, minValue: 0, maxValue: 100, target: nil, action: nil)

    private init() {
        let defaults = UserDefaults.standard
        let savedBrightness = defaults.object(forKey: Self.brightnessKey) as? Int ?? 80
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        brightness = savedBrightness
        engine = MiniDisplayEngine(brightness: savedBrightness)
        engine.onState = { [weak self] s in
            MainActor.assumeIsolated { self?.apply(state: s) }
        }
    }

    // MARK: Lifecycle

    func startIfEnabled() {
        if isEnabled { engine.start() }
        refreshMenuItems()
    }

    func shutdown() {
        engine.stop()
    }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { engine.start() } else { engine.stop() }
        refreshMenuItems()
    }

    func setBrightness(_ value: Int) {
        let v = max(0, min(100, value))
        guard v != brightness else { return }
        brightness = v
        UserDefaults.standard.set(v, forKey: Self.brightnessKey)
        engine.setBrightness(v)
        refreshMenuItems()
    }

    var statusText: String {
        guard isEnabled else { return "Off" }
        switch state {
        case .stopped: return "Starting\u{2026}"
        case .waiting: return "Waiting for display\u{2026}"
        case .connected(let model, let fw): return "Connected \u{00B7} \(model) \u{00B7} fw \(fw)"
        case .error(let msg): return "Error: \(msg.prefix(40))"
        }
    }

    private func apply(state s: MiniDisplayEngine.State) {
        state = s
        refreshMenuItems()
    }

    // MARK: Status menu

    /// Items for the "Mini Display" section of the status menu.
    func makeMenuItems() -> [NSMenuItem] {
        statusLine.isEnabled = false
        statusLine.image = NSImage(systemSymbolName: "rectangle.inset.filled",
                                   accessibilityDescription: "Mini display status")

        let sliderItem = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 50))
        brightnessLabel.frame = NSRect(x: 20, y: 29, width: 210, height: 16)
        brightnessLabel.font = .menuFont(ofSize: 12)
        brightnessLabel.textColor = .secondaryLabelColor
        brightnessSlider.frame = NSRect(x: 18, y: 4, width: 214, height: 24)
        brightnessSlider.isContinuous = true
        brightnessSlider.target = self
        brightnessSlider.action = #selector(sliderChanged(_:))
        view.addSubview(brightnessLabel)
        view.addSubview(brightnessSlider)
        sliderItem.view = view

        enabledItem.target = self
        enabledItem.action = #selector(toggleEnabled)
        enabledItem.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent",
                                    accessibilityDescription: "Sync")

        refreshMenuItems()
        return [statusLine, sliderItem, enabledItem]
    }

    private func refreshMenuItems() {
        statusLine.title = statusText
        enabledItem.state = isEnabled ? .on : .off
        brightnessLabel.stringValue = "Brightness: \(brightness)%"
        brightnessSlider.integerValue = brightness
        brightnessSlider.isEnabled = isEnabled
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        setBrightness(Int(sender.doubleValue.rounded()))
    }

    @objc private func toggleEnabled() {
        setEnabled(!isEnabled)
    }
}
