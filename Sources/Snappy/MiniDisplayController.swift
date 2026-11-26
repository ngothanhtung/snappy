import AppKit
import SwiftUI
import SnappyCore

/// Owns the mini-display engine (Jungle Leopard USB panel dashboard), its
/// persisted settings, and the menu items shown in the status menu.
/// Settings: `miniDisplayEnabled` (default on), `miniDisplayBrightness` (0–100)
/// and `miniDisplayPhotosEnabled` (default off: a Photos slideshow in a 4:3 panel on the right),
/// with `miniDisplayPhotosAlbum` (PhotoKit album id, "" = All Photos) and
/// `miniDisplayPhotosInterval` (seconds between photos) and `miniDisplayPhotosAspect`
/// (card shape, e.g. "4:3"). `miniDisplayTheme` (theme id, default "midnight"). `miniDisplayLayout` (JSON `MiniDisplayLayout`) says which
/// widget sits in which slot; data sources (Photos, EventKit, Claude, process scan)
/// run only for the widgets placed. The older per-card switches
/// (`miniDisplayPhotosEnabled`, `…CalendarEnabled`, …) are only read once to migrate.
@MainActor
final class MiniDisplayController: ObservableObject {
    static let shared = MiniDisplayController()

    static let enabledKey = "miniDisplayEnabled"
    static let brightnessKey = "miniDisplayBrightness"
    static let photosKey = "miniDisplayPhotosEnabled"
    static let photosAlbumKey = "miniDisplayPhotosAlbum"
    static let photosIntervalKey = "miniDisplayPhotosInterval"
    static let photosAspectKey = "miniDisplayPhotosAspect"
    static let calendarKey = "miniDisplayCalendarEnabled"
    static let remindersKey = "miniDisplayRemindersEnabled"
    static let claudeKey = "miniDisplayClaudeEnabled"
    static let topAppsKey = "miniDisplayTopAppsEnabled"
    static let layoutKey = "miniDisplayLayout"
    static let themeKey = "miniDisplayTheme"

    /// Choices for the seconds between photos.
    static let photoIntervals: [Int] = [5, 10, 15, 30, 60, 120, 300]

    static func intervalLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) seconds" : (seconds == 60 ? "1 minute" : "\(seconds / 60) minutes")
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var brightness: Int
    @Published private(set) var state: MiniDisplayEngine.State = .stopped

    @Published private(set) var layout: MiniDisplayLayout
    @Published private(set) var theme: MiniDisplayTheme
    @Published private(set) var photoAlbumID: String
    @Published private(set) var photoInterval: Int
    @Published private(set) var photoAspect: MiniDisplayPhotoAspect

    var showsPhotos: Bool { layout.contains(.photo) }
    var showsCalendar: Bool { layout.contains(.calendar) }
    var showsReminders: Bool { layout.contains(.reminders) }
    var showsClaude: Bool { layout.contains(.claude) }

    private let engine: MiniDisplayEngine
    private let photos = MiniDisplayPhotoSource()
    private let agenda = MiniDisplayAgendaSource()
    private var claudeRetained = false
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let syncItem = NSMenuItem()
    private let syncSwitch = NSSwitch()

    private init() {
        let defaults = UserDefaults.standard
        let savedBrightness = defaults.object(forKey: Self.brightnessKey) as? Int ?? 80
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        layout = MiniDisplayLayout.decode(defaults.data(forKey: Self.layoutKey))
            ?? .migrated(photos: defaults.bool(forKey: Self.photosKey),
                         topApps: defaults.bool(forKey: Self.topAppsKey),
                         calendar: defaults.bool(forKey: Self.calendarKey),
                         reminders: defaults.bool(forKey: Self.remindersKey),
                         claude: defaults.bool(forKey: Self.claudeKey))
        photoAlbumID = defaults.string(forKey: Self.photosAlbumKey) ?? MiniDisplayPhotoAlbum.allPhotosID
        let savedInterval = defaults.integer(forKey: Self.photosIntervalKey)
        photoInterval = Self.photoIntervals.contains(savedInterval) ? savedInterval : 15
        photoAspect = defaults.string(forKey: Self.photosAspectKey).flatMap(MiniDisplayPhotoAspect.init)
            ?? .standard
        theme = MiniDisplayTheme.named(defaults.string(forKey: Self.themeKey))
        brightness = savedBrightness
        engine = MiniDisplayEngine(brightness: savedBrightness)
        engine.setLayout(layout)
        engine.setTheme(theme)
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
            startSources()
        }
        refreshMenuItems()
    }

    func shutdown() {
        stopSources()
        engine.stop()
    }

    // MARK: Layout

    /// Puts widgets in slots and starts/stops the data sources that are now (not) needed.
    func setLayout(_ l: MiniDisplayLayout) {
        guard l != layout else { return }
        layout = l
        if let data = l.encoded() { UserDefaults.standard.set(data, forKey: Self.layoutKey) }
        engine.setLayout(l)
        if isEnabled { startSources() }
        refreshMenuItems()
    }

    /// Colour theme of the whole mini display.
    func setTheme(_ t: MiniDisplayTheme) {
        guard t != theme else { return }
        theme = t
        UserDefaults.standard.set(t.id, forKey: Self.themeKey)
        engine.setTheme(t)
    }

    /// Changes one slot (`top` = upper row) of column `column`.
    func setWidget(_ w: MiniDisplayWidget?, column: Int, top: Bool) {
        var l = layout
        l.set(w, column: column, top: top)
        setLayout(l)
    }

    func setColumnCount(_ n: Int) {
        var l = layout
        l.setColumnCount(n)
        setLayout(l)
    }

    /// Runs exactly the sources the placed widgets need.
    private func startSources() {
        if showsPhotos { startPhotos() } else { stopPhotos() }
        startAgenda()
        if showsClaude { startClaude() } else { stopClaude() }
    }

    private func stopSources() {
        stopClaude()
        stopAgenda()
        stopPhotos()
    }

    // MARK: Photos widget

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

    // MARK: Agenda (Calendar + Reminders)

    /// Loads events / reminders if a Calendar / Reminders widget is placed.
    private func startAgenda() {
        agenda.showsEvents = showsCalendar
        agenda.showsReminders = showsReminders
        if agenda.isActive {
            let box = agenda.current
            engine.setAgendaSource { box.get() }
        } else {
            stopAgenda()
        }
    }

    private func stopAgenda() {
        engine.setAgendaSource(nil)
        agenda.showsEvents = false
        agenda.showsReminders = false
    }

    // MARK: Claude plan usage

    private func startClaude() {
        let monitor = ClaudeLimitsMonitor.shared
        if !claudeRetained { monitor.retain(); claudeRetained = true }
        let box = monitor.box
        engine.setClaudeSource { box.get() }
    }

    private func stopClaude() {
        engine.setClaudeSource(nil)
        if claudeRetained { ClaudeLimitsMonitor.shared.release(); claudeRetained = false }
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
            startSources()
        } else {
            stopSources()
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

    /// Items for the "Mini Display" section of the status menu: connection status and Sync.
    func makeMenuItems() -> [NSMenuItem] {
        statusLine.isEnabled = false
        statusLine.image = NSImage(systemSymbolName: "rectangle.inset.filled",
                                   accessibilityDescription: "Mini display status")

        syncItem.view = makeSwitchRow("Sync", symbol: "arrow.triangle.2.circlepath",
                                      syncSwitch, action: #selector(syncSwitched(_:)))
        refreshMenuItems()
        // Brightness, theme and widgets live in Settings ▸ Mini Display.
        return [statusLine, syncItem]
    }

    private func refreshMenuItems() {
        syncSwitch.state = isEnabled ? .on : .off
        statusLine.title = photosProblem.map { "\(statusText) \u{00B7} \($0)" } ?? statusText
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
}
