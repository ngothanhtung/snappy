import AppKit
import SnappyCore
import SnappyDisplayPrivate

/// How a display's brightness is changed.
enum BrightnessMethod: Equatable {
    /// DisplayServices — built-in and Apple displays.
    case native
    /// DDC/CI over I2C.
    case ddc
    /// Gamma-table dimming (no hardware control).
    case software
    case none
}

/// Hardware/software controls known for one display. Levels are 0…1.
struct DisplayControls: Equatable {
    var brightnessMethod: BrightnessMethod = .none
    var brightness: Double?
    var contrast: Double?
    var volume: Double?
    var muted: Bool?
    /// DDC maxima, to turn fractions back into raw values.
    var ddcMaximum: [VCPCode: UInt16] = [:]
    /// The monitor answered VCP 0x8D (otherwise mute is emulated with volume 0).
    var supportsMute = false
    /// Still reading DDC capabilities.
    var probing = false
}

/// BetterDisplay-style display controls: brightness (DisplayServices, DDC or
/// software dimming), contrast/volume/mute over DDC, resolution, refresh rate,
/// rotation, mirroring, main display and disconnect.
///
/// Safety rules, learned the hard way: never disconnect a display that is in a
/// mirror set (macOS reshuffles the set and can mirror the main display away),
/// never disconnect the last active display, ask first, disconnect for the
/// session only, and reconnect everything on quit and on the next launch.
@MainActor
final class DisplayControlCenter: ObservableObject {
    static let shared = DisplayControlCenter()

    static let softwareDimmingKey = "displaySoftwareDimming"
    static let softwareLevelsKey = "displaySoftwareBrightness"
    static let disabledKey = "displaysDisabledBySnappy"

    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var controls: [CGDirectDisplayID: DisplayControls] = [:]
    /// Displays Snappy disconnected (id → name); they vanish from the online list.
    @Published private(set) var disabled: [CGDirectDisplayID: String] = [:]
    @Published private(set) var softwareDimmingEnabled: Bool

    /// Called after any change, for views not driven by SwiftUI (menu sliders, panel sizing).
    private var observers: [() -> Void] = []

    func addObserver(_ f: @escaping () -> Void) { observers.append(f) }

    private var channels: [CGDirectDisplayID: DDCChannel] = [:]
    private let gamma = GammaDimmer()
    private var refreshPending = false
    /// Displays with a DDC probe queued or running — never queue a second one:
    /// an I2C call can block for many seconds while macOS reconfigures
    /// displays (seen when Sidecar disconnected), and probes would pile up.
    private var probesInFlight = Set<CGDirectDisplayID>()
    /// Display key → when DDC last failed; such displays aren't re-probed on
    /// every reconfiguration, only after `ddcRetryInterval`.
    private var ddcFailedAt: [String: Date] = [:]
    private static let ddcRetryInterval: TimeInterval = 120
    /// Mute emulation for monitors without VCP 0x8D: volume before muting.
    private var volumeBeforeMute: [CGDirectDisplayID: Double] = [:]

    private init() {
        softwareDimmingEnabled = UserDefaults.standard.object(forKey: Self.softwareDimmingKey) as? Bool ?? true
    }

    // MARK: Lifecycle

    func start() {
        reconnectLeftovers()
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { DisplayControlCenter.shared.scheduleRefresh() }
            }
        }, nil)
        refresh()
    }

    func shutdown() {
        for id in disabled.keys { DisplayConfigurator.setEnabled(id, true) }
        disabled.removeAll()
        saveDisabled()
        gamma.restoreAll()
    }

    /// Coalesces bursts of reconfiguration callbacks into one refresh.
    func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    func refresh() {
        displays = DisplayConfigurator.onlineDisplays()
        let ids = Set(displays.map(\.id))
        controls = controls.filter { ids.contains($0.key) }
        channels = channels.filter { ids.contains($0.key) }
        pairDDC()
        for d in displays { probe(d) }
        gamma.reapply()
        notify()
    }

    private func notify() { observers.forEach { $0() } }

    /// Re-reads brightness/volume (cheap; e.g. when the menu opens) — the
    /// user may have changed them with the monitor's own buttons or keys.
    func refreshLevels() {
        for d in displays {
            guard var c = controls[d.id], !c.probing, !probesInFlight.contains(d.id) else { continue }
            switch c.brightnessMethod {
            case .native:
                let b = SDPGetBrightness(d.id)
                if b >= 0 { c.brightness = Double(b); controls[d.id] = c }
            case .ddc:
                guard let channel = channels[d.id] else { continue }
                let codes: [VCPCode] = c.volume != nil ? [.brightness, .volume] : [.brightness]
                probesInFlight.insert(d.id)
                channel.read(codes) { [weak self] r in
                    MainActor.assumeIsolated {
                        self?.probesInFlight.remove(d.id)
                        guard let self, var c = self.controls[d.id] else { return }
                        if let b = r[.brightness], b.maximum > 0 { c.brightness = b.fraction }
                        if let v = r[.volume], v.maximum > 0, c.muted != true { c.volume = v.fraction }
                        self.controls[d.id] = c
                        self.notify()
                    }
                }
            case .software, .none:
                break
            }
        }
        notify()
    }

    // MARK: Probing

    private func pairDDC() {
        let candidates = SDPCopyI2CServices()
        let external = displays.filter { !$0.isBuiltin }
        let pairs = DisplayPairing.match(
            displays: external.map(\.identity),
            candidates: candidates.map {
                I2CCandidate(framebufferPath: $0.framebufferPath, manufacturerID: $0.manufacturerID,
                             productID: $0.productID, serialNumber: $0.serialNumber, productName: $0.productName)
            })
        var fresh: [CGDirectDisplayID: DDCChannel] = [:]
        for (d, c) in pairs {
            let display = external[d]
            fresh[display.id] = channels[display.id] ?? DDCChannel(service: candidates[c])
        }
        channels = fresh
    }

    private func probe(_ d: DisplayInfo) {
        var c = controls[d.id] ?? DisplayControls()
        if SDPCanChangeBrightness(d.id) {
            c.brightnessMethod = .native
            let b = SDPGetBrightness(d.id)
            c.brightness = b >= 0 ? Double(b) : c.brightness
            controls[d.id] = c
            return
        }
        let recentlyFailed = ddcFailedAt[d.key].map { Date().timeIntervalSince($0) < Self.ddcRetryInterval } ?? false
        guard let channel = channels[d.id], !recentlyFailed else {
            applySoftwareFallback(d, &c)
            controls[d.id] = c
            return
        }
        guard probesInFlight.insert(d.id).inserted else { return }
        // Keep what we know while re-reading after a reconfiguration.
        if c.brightnessMethod == .none { c.probing = true }
        controls[d.id] = c
        channel.read([.brightness, .contrast, .volume, .mute]) { [weak self] readings in
            MainActor.assumeIsolated { self?.finishProbe(d, readings) }
        }
    }

    private func finishProbe(_ d: DisplayInfo, _ r: [VCPCode: DDCReading]) {
        probesInFlight.remove(d.id)
        guard displays.contains(where: { $0.id == d.id }) else { return }
        var c = controls[d.id] ?? DisplayControls()
        c.probing = false
        for (code, reading) in r where reading.maximum > 0 { c.ddcMaximum[code] = reading.maximum }
        if let b = r[.brightness], b.maximum > 0 {
            ddcFailedAt[d.key] = nil
            c.brightnessMethod = .ddc
            c.brightness = b.fraction
        } else {
            NSLog("Snappy: %@ does not answer DDC brightness", d.name)
            ddcFailedAt[d.key] = Date()
            applySoftwareFallback(d, &c)
        }
        c.contrast = r[.contrast].flatMap { $0.maximum > 0 ? $0.fraction : nil }
        c.volume = r[.volume].flatMap { $0.maximum > 0 ? $0.fraction : nil }
        // VCP 0x8D: 1 = muted, 2 = unmuted.
        c.supportsMute = r[.mute] != nil
        c.muted = r[.mute].map { $0.current == 1 }
        if !c.supportsMute, c.volume != nil { c.muted = volumeBeforeMute[d.id] != nil }
        controls[d.id] = c
        notify()
    }

    private func applySoftwareFallback(_ d: DisplayInfo, _ c: inout DisplayControls) {
        if softwareDimmingEnabled && gamma.canDim(d.id) {
            c.brightnessMethod = .software
            c.brightness = softwareLevel(for: d)
            gamma.set(d.id, level: c.brightness ?? 1)
        } else {
            c.brightnessMethod = .none
            c.brightness = nil
            gamma.set(d.id, level: 1)
        }
    }

    // MARK: Brightness / contrast / volume

    func setBrightness(_ value: Double, for id: CGDirectDisplayID) {
        let v = DisplayLevel.clamp(value)
        guard var c = controls[id] else { return }
        switch c.brightnessMethod {
        case .native:
            _ = SDPSetBrightness(id, Float(v))
        case .ddc:
            channels[id]?.write(.brightness, DisplayLevel.ddcValue(v, maximum: c.ddcMaximum[.brightness] ?? 100))
        case .software:
            gamma.set(id, level: v)
            if let d = displays.first(where: { $0.id == id }) { saveSoftwareLevel(v, for: d) }
        case .none:
            return
        }
        c.brightness = v
        controls[id] = c
        notify()
    }

    func setContrast(_ value: Double, for id: CGDirectDisplayID) {
        guard var c = controls[id], c.contrast != nil, let channel = channels[id] else { return }
        let v = DisplayLevel.clamp(value)
        channel.write(.contrast, DisplayLevel.ddcValue(v, maximum: c.ddcMaximum[.contrast] ?? 100))
        c.contrast = v
        controls[id] = c
        notify()
    }

    func setVolume(_ value: Double, for id: CGDirectDisplayID) {
        guard var c = controls[id], c.volume != nil, let channel = channels[id] else { return }
        let v = DisplayLevel.clamp(value)
        channel.write(.volume, DisplayLevel.ddcValue(v, maximum: c.ddcMaximum[.volume] ?? 100))
        if c.muted == true, v > 0 { setMuted(false, for: id, current: &c) }
        c.volume = v
        controls[id] = c
        notify()
    }

    func toggleMute(for id: CGDirectDisplayID) {
        guard var c = controls[id], c.volume != nil else { return }
        setMuted(!(c.muted ?? false), for: id, current: &c)
        controls[id] = c
        notify()
    }

    private func setMuted(_ on: Bool, for id: CGDirectDisplayID, current c: inout DisplayControls) {
        guard let channel = channels[id] else { return }
        if c.supportsMute {
            channel.write(.mute, on ? 1 : 2)
        } else if on {
            // No mute feature: remember the volume and turn it down.
            volumeBeforeMute[id] = c.volume ?? 0.5
            channel.write(.volume, 0)
            c.volume = 0
        } else {
            let restore = volumeBeforeMute.removeValue(forKey: id) ?? 0.5
            channel.write(.volume, DisplayLevel.ddcValue(restore, maximum: c.ddcMaximum[.volume] ?? 100))
            c.volume = restore
        }
        c.muted = on
    }

    func setSoftwareDimmingEnabled(_ on: Bool) {
        guard on != softwareDimmingEnabled else { return }
        softwareDimmingEnabled = on
        UserDefaults.standard.set(on, forKey: Self.softwareDimmingKey)
        for d in displays {
            guard var c = controls[d.id], c.brightnessMethod == .software || c.brightnessMethod == .none,
                  !c.probing else { continue }
            applySoftwareFallback(d, &c)
            controls[d.id] = c
        }
        notify()
    }

    private func softwareLevel(for d: DisplayInfo) -> Double {
        let levels = UserDefaults.standard.dictionary(forKey: Self.softwareLevelsKey) as? [String: Double] ?? [:]
        return levels[d.key] ?? 1
    }

    private func saveSoftwareLevel(_ v: Double, for d: DisplayInfo) {
        var levels = UserDefaults.standard.dictionary(forKey: Self.softwareLevelsKey) as? [String: Double] ?? [:]
        levels[d.key] = v
        UserDefaults.standard.set(levels, forKey: Self.softwareLevelsKey)
    }

    // MARK: Hotkeys

    /// Display under the mouse pointer (where hotkeys act).
    var displayUnderMouse: DisplayInfo? {
        let p = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
        guard let id = screen?.displayID else { return displays.first }
        return displays.first { $0.id == id }
    }

    func stepBrightness(up: Bool) {
        guard let d = displayUnderMouse, let c = controls[d.id], c.brightnessMethod != .none,
              let b = c.brightness else { return NSSound.beep() }
        let v = DisplayLevel.step(b, up: up)
        setBrightness(v, for: d.id)
        DisplayOSD.shared.show(symbol: v == 0 ? "sun.min" : "sun.max.fill", level: v, on: d.id)
    }

    func stepVolume(up: Bool) {
        guard let d = displayUnderMouse, let c = controls[d.id], let vol = c.volume else { return NSSound.beep() }
        let v = DisplayLevel.step(c.muted == true ? 0 : vol, up: up)
        setVolume(v, for: d.id)
        DisplayOSD.shared.show(symbol: Self.volumeSymbol(v, muted: false), level: v, on: d.id)
    }

    func toggleMuteUnderMouse() {
        guard let d = displayUnderMouse, controls[d.id]?.volume != nil else { return NSSound.beep() }
        toggleMute(for: d.id)
        let c = controls[d.id]
        let muted = c?.muted == true
        DisplayOSD.shared.show(symbol: Self.volumeSymbol(c?.volume ?? 0, muted: muted),
                               level: muted ? 0 : (c?.volume ?? 0), on: d.id)
    }

    static func volumeSymbol(_ v: Double, muted: Bool) -> String {
        if muted || v == 0 { return "speaker.slash.fill" }
        return v < 0.34 ? "speaker.wave.1.fill" : (v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
    }

    // MARK: Configuration

    func setMode(_ modeID: Int32, for id: CGDirectDisplayID) {
        DisplayConfigurator.setMode(modeID, on: id)
        scheduleRefresh()
    }

    func mirror(_ id: CGDirectDisplayID, of master: CGDirectDisplayID?) {
        DisplayConfigurator.mirror(id, of: master)
        scheduleRefresh()
    }

    func stopMirroring(into master: CGDirectDisplayID) {
        DisplayConfigurator.stopMirroring(into: master, displays: displays)
        scheduleRefresh()
    }

    func makeMain(_ id: CGDirectDisplayID) {
        DisplayConfigurator.makeMain(id, displays: displays)
        scheduleRefresh()
    }

    func rotate(_ id: CGDirectDisplayID, to degrees: Int) {
        DisplayConfigurator.rotate(id, to: degrees)
        scheduleRefresh()
    }

    /// Why a display can't be disconnected right now, if it can't.
    func disconnectRefusal(_ d: DisplayInfo) -> String? {
        if !DisplayConfigurator.canToggleDisplays { return "Not supported on this macOS version." }
        if d.isInMirrorSet { return "Turn off mirroring for \(d.name) first." }
        if displays.filter({ $0.isActive && $0.id != d.id }).isEmpty { return "It is the only active display." }
        return nil
    }

    func disconnect(_ d: DisplayInfo) {
        if let reason = disconnectRefusal(d) {
            let alert = NSAlert()
            alert.messageText = "Can't disconnect \(d.name)"
            alert.informativeText = reason
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Disconnect \(d.name)?"
        alert.informativeText = "The display turns off until you reconnect it from the Snappy menu. "
            + "Quitting Snappy, logging out or restarting also brings it back."
        alert.addButton(withTitle: "Disconnect")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Remember first, so a crash right after still reconnects on next launch.
        disabled[d.id] = d.name
        saveDisabled()
        if !DisplayConfigurator.setEnabled(d.id, false) {
            disabled[d.id] = nil
            saveDisabled()
        }
        scheduleRefresh()
    }

    func reconnect(_ id: CGDirectDisplayID) {
        DisplayConfigurator.setEnabled(id, true)
        disabled[id] = nil
        saveDisabled()
        scheduleRefresh()
    }

    func reconnectAll() {
        for id in disabled.keys { reconnect(id) }
    }

    private func saveDisabled() {
        UserDefaults.standard.set(disabled.keys.map { Int($0) }, forKey: Self.disabledKey)
    }

    /// Displays left disconnected by a previous run (crash, force quit).
    private func reconnectLeftovers() {
        let ids = UserDefaults.standard.array(forKey: Self.disabledKey) as? [Int] ?? []
        for id in ids { DisplayConfigurator.setEnabled(CGDirectDisplayID(id), true) }
        UserDefaults.standard.removeObject(forKey: Self.disabledKey)
    }
}

/// Software dimming by scaling each display's gamma table. macOS restores the
/// tables itself when Snappy exits.
@MainActor
final class GammaDimmer {
    private struct Table { var r: [CGGammaValue]; var g: [CGGammaValue]; var b: [CGGammaValue] }
    private var originals: [CGDirectDisplayID: Table] = [:]
    private var levels: [CGDirectDisplayID: Double] = [:]

    func canDim(_ id: CGDirectDisplayID) -> Bool { CGDisplayGammaTableCapacity(id) > 0 }

    func set(_ id: CGDirectDisplayID, level: Double) {
        if level >= 0.999 {
            guard levels.removeValue(forKey: id) != nil else { return }
            originals[id] = nil
            // Restores every display's ColorSync table; re-dim the others.
            CGDisplayRestoreColorSyncSettings()
            reapply()
            return
        }
        if originals[id] == nil {
            guard let t = Self.read(id) else { return }
            originals[id] = t
        }
        levels[id] = level
        apply(id)
    }

    func reapply() {
        for id in levels.keys { apply(id) }
    }

    func restoreAll() {
        guard !levels.isEmpty else { return }
        levels.removeAll()
        originals.removeAll()
        CGDisplayRestoreColorSyncSettings()
    }

    private func apply(_ id: CGDirectDisplayID) {
        guard let t = originals[id], let level = levels[id] else { return }
        let r = SoftwareDimming.scaled(t.r, level: level)
        let g = SoftwareDimming.scaled(t.g, level: level)
        let b = SoftwareDimming.scaled(t.b, level: level)
        CGSetDisplayTransferByTable(id, UInt32(r.count), r, g, b)
    }

    private static func read(_ id: CGDirectDisplayID) -> Table? {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 0 else { return nil }
        var r = [CGGammaValue](repeating: 0, count: Int(capacity))
        var g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &count) == .success, count > 0 else { return nil }
        let n = Int(count)
        return Table(r: Array(r.prefix(n)), g: Array(g.prefix(n)), b: Array(b.prefix(n)))
    }
}
