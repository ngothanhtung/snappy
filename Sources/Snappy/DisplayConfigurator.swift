import AppKit
import SnappyCore
import SnappyDisplayPrivate

/// A display as seen by CoreGraphics (CG global coordinates, top-left origin).
struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    let isMain: Bool
    let isActive: Bool
    /// The display this one mirrors (shows the same picture as), if any.
    let mirrorMaster: CGDirectDisplayID?
    let bounds: CGRect
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    /// Stable across reconnects/reboots (CGDirectDisplayIDs are not).
    var key: String { "\(vendor)-\(model)-\(serial)" }
    var isMirroring: Bool { mirrorMaster != nil }
    var isInMirrorSet: Bool { CGDisplayIsInMirrorSet(id) != 0 }

    var identity: DisplayIdentity {
        DisplayIdentity(location: SDPDisplayLocation(id), vendor: vendor, model: model, serial: serial, name: name)
    }
}

/// Reads and changes the display configuration: modes, mirroring, main
/// display, rotation and enable/disable.
@MainActor
enum DisplayConfigurator {

    // MARK: Inventory

    /// All online displays (mirrored ones included; disabled ones are gone).
    static func onlineDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        let screenNames = Dictionary(NSScreen.screens.compactMap { s in s.displayID.map { ($0, s.localizedName) } },
                                     uniquingKeysWith: { a, _ in a })
        return ids.prefix(Int(count)).map { id in
            let master = CGDisplayMirrorsDisplay(id)
            return DisplayInfo(
                id: id,
                name: screenNames[id] ?? SDPDisplayName(id) ?? "Display \(id)",
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                isMain: CGDisplayIsMain(id) != 0,
                isActive: CGDisplayIsActive(id) != 0,
                mirrorMaster: master == kCGNullDirectDisplay ? nil : master,
                bounds: CGDisplayBounds(id),
                vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id)
            )
        }
        .sorted { ($0.isMain ? 0 : 1, $0.bounds.minX, $0.bounds.minY) < ($1.isMain ? 0 : 1, $1.bounds.minX, $1.bounds.minY) }
    }

    /// Displays with their own place on the desktop (not mirroring another).
    static func topLevel(_ displays: [DisplayInfo]) -> [DisplayInfo] {
        displays.filter { !$0.isMirroring }
    }

    // MARK: Modes

    static func modes(of id: CGDirectDisplayID) -> [(info: DisplayModeInfo, mode: CGDisplayMode)] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let all = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else { return [] }
        return all.map { (info($0), $0) }
    }

    static func currentMode(of id: CGDirectDisplayID) -> DisplayModeInfo? {
        CGDisplayCopyDisplayMode(id).map(info)
    }

    private static func info(_ m: CGDisplayMode) -> DisplayModeInfo {
        DisplayModeInfo(id: m.ioDisplayModeID, width: m.width, height: m.height,
                        pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight,
                        refreshRate: m.refreshRate, isUsableForDesktop: m.isUsableForDesktopGUI())
    }

    @discardableResult
    static func setMode(_ modeID: Int32, on id: CGDirectDisplayID) -> Bool {
        guard let mode = modes(of: id).first(where: { $0.info.id == modeID })?.mode else { return false }
        return configure { CGConfigureDisplayWithDisplayMode($0, id, mode, nil) }
    }

    // MARK: Arrangement

    /// Makes `id` mirror `master` (nil = stop mirroring).
    @discardableResult
    static func mirror(_ id: CGDirectDisplayID, of master: CGDirectDisplayID?) -> Bool {
        configure { CGConfigureDisplayMirrorOfDisplay($0, id, master ?? kCGNullDirectDisplay) }
    }

    /// Stops every display mirroring `master`.
    @discardableResult
    static func stopMirroring(into master: CGDirectDisplayID, displays: [DisplayInfo]) -> Bool {
        let slaves = displays.filter { $0.mirrorMaster == master }
        guard !slaves.isEmpty else { return true }
        return configure { config in
            for s in slaves {
                let e = CGConfigureDisplayMirrorOfDisplay(config, s.id, kCGNullDirectDisplay)
                if e != .success { return e }
            }
            return .success
        }
    }

    /// Moves the menu bar (the (0,0) display) to `id`, keeping the arrangement.
    @discardableResult
    static func makeMain(_ id: CGDirectDisplayID, displays: [DisplayInfo]) -> Bool {
        let bounds = Dictionary(uniqueKeysWithValues: topLevel(displays).map { ($0.id, $0.bounds) })
        guard let origins = DisplayArrangement.originsMakingMain(id, bounds: bounds) else { return false }
        return configure { config in
            for (d, o) in origins {
                let e = CGConfigureDisplayOrigin(config, d, Int32(o.x.rounded()), Int32(o.y.rounded()))
                if e != .success { return e }
            }
            return .success
        }
    }

    // MARK: Rotation

    static func canRotate(_ id: CGDirectDisplayID) -> Bool { SDPCanRotate(id) }
    static func rotation(of id: CGDirectDisplayID) -> Int { Int(SDPRotation(id)) }
    @discardableResult
    static func rotate(_ id: CGDirectDisplayID, to degrees: Int) -> Bool { SDPSetRotation(id, Int32(degrees)) }

    // MARK: Enable / disable

    static var canToggleDisplays: Bool { SDPCanToggleDisplays() }

    /// Disconnects (or reconnects) a display for this login session only, so a
    /// reboot always brings every display back.
    @discardableResult
    static func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> Bool {
        configure(.forSession) { SDPConfigureDisplayEnabled($0, id, enabled) }
    }

    // MARK: Plumbing

    private static func configure(_ option: CGConfigureOption = .permanently,
                                  _ body: (CGDisplayConfigRef) -> CGError) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        let e = body(config)
        guard e == .success else {
            NSLog("Snappy: display configuration failed: %d", e.rawValue)
            CGCancelDisplayConfiguration(config)
            return false
        }
        let done = CGCompleteDisplayConfiguration(config, option)
        if done != .success { NSLog("Snappy: display configuration not applied: %d", done.rawValue) }
        return done == .success
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
