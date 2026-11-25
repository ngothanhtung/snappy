import AppKit
import SwiftUI

/// Owns the mini-display engine (Jungle Leopard USB panel dashboard), its
/// persisted settings, and the menu items shown in the status menu.
/// Settings: `miniDisplayEnabled` (default on), `miniDisplayBrightness` (0–100)
/// and `miniDisplayPhotosEnabled` (default off: a Photos slideshow in a 4:3 panel on the right),
/// with `miniDisplayPhotosAlbum` (PhotoKit album id, "" = All Photos) and
/// `miniDisplayPhotosInterval` (seconds between photos) and `miniDisplayPhotosAspect`
/// (card shape, e.g. "4:3").
@MainActor
final class MiniDisplayController: ObservableObject {
    static let shared = MiniDisplayController()

    static let enabledKey = "miniDisplayEnabled"
    static let brightnessKey = "miniDisplayBrightness"
    static let photosKey = "miniDisplayPhotosEnabled"
    static let photosAlbumKey = "miniDisplayPhotosAlbum"
    static let photosIntervalKey = "miniDisplayPhotosInterval"
    static let photosAspectKey = "miniDisplayPhotosAspect"

    /// Choices for the seconds between photos.
    static let photoIntervals: [Int] = [5, 10, 15, 30, 60, 120, 300]

    static func intervalLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) seconds" : (seconds == 60 ? "1 minute" : "\(seconds / 60) minutes")
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var brightness: Int
    @Published private(set) var state: MiniDisplayEngine.State = .stopped

    @Published private(set) var showsPhotos: Bool
    @Published private(set) var photoAlbumID: String
    @Published private(set) var photoInterval: Int
    @Published private(set) var photoAspect: MiniDisplayPhotoAspect

    private let engine: MiniDisplayEngine
    private let photos = MiniDisplayPhotoSource()
    private let photosItem = NSMenuItem()
    private let photosSwitch = NSSwitch()
    private let albumItem = NSMenuItem(title: "Album", action: nil, keyEquivalent: "")
    private let intervalItem = NSMenuItem(title: "Change Every", action: nil, keyEquivalent: "")
    private let aspectItem = NSMenuItem(title: "Frame", action: nil, keyEquivalent: "")
    private let albumMenuDelegate = MenuOpenHandler()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let syncItem = NSMenuItem()
    private let syncSwitch = NSSwitch()
    private let brightnessLabel = NSTextField(labelWithString: "")
    private let brightnessSlider = NSSlider(value: 80, minValue: 0, maxValue: 100, target: nil, action: nil)

    private init() {
        let defaults = UserDefaults.standard
        let savedBrightness = defaults.object(forKey: Self.brightnessKey) as? Int ?? 80
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        showsPhotos = defaults.bool(forKey: Self.photosKey)
        photoAlbumID = defaults.string(forKey: Self.photosAlbumKey) ?? MiniDisplayPhotoAlbum.allPhotosID
        let savedInterval = defaults.integer(forKey: Self.photosIntervalKey)
        photoInterval = Self.photoIntervals.contains(savedInterval) ? savedInterval : 15
        photoAspect = defaults.string(forKey: Self.photosAspectKey).flatMap(MiniDisplayPhotoAspect.init)
            ?? .standard
        brightness = savedBrightness
        engine = MiniDisplayEngine(brightness: savedBrightness)
        engine.onState = { [weak self] s in
            MainActor.assumeIsolated { self?.apply(state: s) }
        }
        photos.onChange = { [weak self] in
            self?.objectWillChange.send()
            self?.refreshMenuItems()
        }
    }

    // MARK: Lifecycle

    func startIfEnabled() {
        if isEnabled {
            engine.start()
            if showsPhotos { startPhotos() }
        }
        refreshMenuItems()
    }

    func shutdown() {
        stopPhotos()
        engine.stop()
    }

    // MARK: Photos panel

    /// Shows a slideshow from the Photos library in a 4:3 card on the right of the panel.
    func setShowsPhotos(_ on: Bool) {
        guard on != showsPhotos else { return }
        showsPhotos = on
        UserDefaults.standard.set(on, forKey: Self.photosKey)
        if on && isEnabled { startPhotos() } else { stopPhotos() }
        refreshMenuItems()
    }

    func setPhotoAlbum(_ id: String) {
        guard id != photoAlbumID else { return }
        photoAlbumID = id
        UserDefaults.standard.set(id, forKey: Self.photosAlbumKey)
        photos.albumID = id
        refreshMenuItems()
    }

    func setPhotoInterval(_ seconds: Int) {
        guard seconds != photoInterval else { return }
        photoInterval = seconds
        UserDefaults.standard.set(seconds, forKey: Self.photosIntervalKey)
        photos.interval = TimeInterval(seconds)
        refreshMenuItems()
    }

    func setPhotoAspect(_ a: MiniDisplayPhotoAspect) {
        guard a != photoAspect else { return }
        photoAspect = a
        UserDefaults.standard.set(a.id, forKey: Self.photosAspectKey)
        photos.aspect = a
        refreshMenuItems()
    }

    /// Albums to choose from (empty until Photos access is granted).
    func photoAlbums() -> [MiniDisplayPhotoAlbum] { MiniDisplayPhotoSource.albums() }

    private func startPhotos() {
        photos.albumID = photoAlbumID
        photos.interval = TimeInterval(photoInterval)
        photos.aspect = photoAspect
        photos.start()
        if MiniDisplayLog.debugDir != nil {
            MiniDisplayLog.log("photos: albums: " + photoAlbums().map { "\($0.title) (\($0.count))" }
                .joined(separator: ", "))
        }
        let current = photos.current
        engine.setPhotoSource { current.frame() }
    }

    private func stopPhotos() {
        engine.setPhotoSource(nil)
        photos.stop()
    }

    /// Photos problem worth showing (no access, empty library), if any.
    var photosProblem: String? { showsPhotos && isEnabled ? photos.problem : nil }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            engine.start()
            if showsPhotos { startPhotos() }
        } else {
            stopPhotos()
            engine.stop()
        }
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
        brightnessSlider.frame = NSRect(x: 18, y: 4, width: 250 - 18 - 14, height: 24)
        brightnessSlider.isContinuous = true
        brightnessSlider.target = self
        brightnessSlider.action = #selector(sliderChanged(_:))
        // Menus resize width-flexible item views to the menu's width, so the
        // slider stretches to the right edge instead of stopping at 250pt.
        view.autoresizingMask = [.width]
        brightnessLabel.autoresizingMask = [.width]
        brightnessSlider.autoresizingMask = [.width]
        view.addSubview(brightnessLabel)
        view.addSubview(brightnessSlider)
        sliderItem.view = view

        syncItem.view = makeSwitchRow("Sync", symbol: "arrow.triangle.2.circlepath",
                                      syncSwitch, action: #selector(syncSwitched(_:)))
        photosItem.view = makeSwitchRow("Photos", symbol: "photo.on.rectangle",
                                        photosSwitch, action: #selector(photosSwitched(_:)))

        // Album list is built each time the submenu opens (albums change).
        let albumMenu = NSMenu()
        albumMenuDelegate.onOpen = { [weak self] menu in
            MainActor.assumeIsolated { self?.fillAlbumMenu(menu) }
        }
        albumMenu.delegate = albumMenuDelegate
        albumItem.submenu = albumMenu
        albumItem.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Album")

        let intervalMenu = NSMenu()
        for sec in Self.photoIntervals {
            let item = NSMenuItem(title: Self.intervalLabel(sec), action: #selector(pickInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = sec
            intervalMenu.addItem(item)
        }
        intervalItem.submenu = intervalMenu
        intervalItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Change every")

        let aspectMenu = NSMenu()
        for a in MiniDisplayPhotoAspect.all {
            let item = NSMenuItem(title: a.id, action: #selector(pickAspect(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = a.id
            aspectMenu.addItem(item)
        }
        aspectItem.submenu = aspectMenu
        aspectItem.image = NSImage(systemSymbolName: "aspectratio", accessibilityDescription: "Frame")

        refreshMenuItems()
        return [statusLine, syncItem, sliderItem, photosItem, albumItem, intervalItem, aspectItem]
    }

    private func refreshMenuItems() {
        syncSwitch.state = isEnabled ? .on : .off
        brightnessLabel.stringValue = "Brightness: \(brightness)%"
        brightnessSlider.integerValue = brightness
        brightnessSlider.isEnabled = isEnabled
        photosSwitch.state = showsPhotos ? .on : .off
        photosSwitch.isEnabled = isEnabled
        photosSwitch.toolTip = photosProblem
        albumItem.isHidden = !showsPhotos
        intervalItem.isHidden = !showsPhotos
        albumItem.title = "Album: " + currentAlbumTitle
        intervalItem.title = "Change Every: " + Self.intervalLabel(photoInterval)
        intervalItem.submenu?.items.forEach { $0.state = $0.tag == photoInterval ? .on : .off }
        aspectItem.isHidden = !showsPhotos
        aspectItem.title = "Frame: " + photoAspect.id
        aspectItem.submenu?.items.forEach {
            $0.state = ($0.representedObject as? String) == photoAspect.id ? .on : .off
        }
        statusLine.title = photosProblem.map { "\(statusText) \u{00B7} \($0)" } ?? statusText
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        setBrightness(Int(sender.doubleValue.rounded()))
    }

    /// Icon + label with an ON/OFF switch pinned to the right edge.
    private func makeSwitchRow(_ title: String, symbol: String, _ toggle: NSSwitch, action: Selector) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 30))
        let icon = NSImageView(frame: NSRect(x: 14, y: 7, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.contentTintColor = .labelColor
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 38, y: (30 - label.frame.height) / 2)
        toggle.controlSize = .small
        toggle.sizeToFit()
        toggle.frame.origin = NSPoint(x: 250 - 14 - toggle.frame.width,
                                      y: (30 - toggle.frame.height) / 2)
        // Pin the switch to the right edge when the menu is wider than 250pt.
        v.autoresizingMask = [.width]
        toggle.autoresizingMask = [.minXMargin]
        toggle.target = self
        toggle.action = action
        v.addSubview(icon)
        v.addSubview(label)
        v.addSubview(toggle)
        return v
    }

    @objc private func syncSwitched(_ sender: NSSwitch) {
        setEnabled(sender.state == .on)
    }

    @objc private func photosSwitched(_ sender: NSSwitch) {
        setShowsPhotos(sender.state == .on)
    }

    /// Title of the chosen album, cached so the menu doesn't hit PhotoKit on every refresh.
    private var albumTitleCache: (id: String, title: String)?
    private var currentAlbumTitle: String {
        if photoAlbumID.isEmpty { return "All Photos" }
        if let c = albumTitleCache, c.id == photoAlbumID { return c.title }
        let title = photoAlbums().first { $0.id == photoAlbumID }?.title ?? "All Photos"
        albumTitleCache = (photoAlbumID, title)
        return title
    }

    private func fillAlbumMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let albums = photoAlbums()
        if albums.isEmpty {
            let none = NSMenuItem(title: "Allow Photos access first", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for (i, album) in albums.enumerated() {
            // Separator after All Photos.
            if i == 1 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: "\(album.title)  (\(album.count))",
                                  action: #selector(pickAlbum(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [album.id, album.title]
            item.state = album.id == photoAlbumID ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func pickAlbum(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        albumTitleCache = (pair[0], pair[1])
        setPhotoAlbum(pair[0])
    }

    @objc private func pickAspect(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let a = MiniDisplayPhotoAspect(id) else { return }
        setPhotoAspect(a)
    }

    @objc private func pickInterval(_ sender: NSMenuItem) {
        setPhotoInterval(sender.tag)
    }
}

/// NSMenuDelegate that calls back right before a menu opens.
private final class MenuOpenHandler: NSObject, NSMenuDelegate {
    var onOpen: ((NSMenu) -> Void)?
    func menuNeedsUpdate(_ menu: NSMenu) { onOpen?(menu) }
}
