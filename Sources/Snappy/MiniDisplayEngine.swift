import CoreGraphics
import Foundation
import SnappyCore

/// Background loop that finds the panel, renders the dashboard and streams it.
/// Runs on its own thread; all shared state is behind `lock`. State changes are
/// reported on the main queue.
final class MiniDisplayEngine: @unchecked Sendable {
    enum State: Equatable {
        case stopped
        case waiting
        case connected(model: String, firmware: String)
        case error(String)
    }

    var onState: ((State) -> Void)?
    /// Frames per second. The panel needs a still re-sent ~4x/s anyway;
    /// photo crossfades briefly run faster so they look smooth.
    let fps = 4.0
    let transitionFps = 20.0

    private let lock = NSLock()
    private var running = false
    private var brightness: Int
    private var brightnessDirty = false
    private var lastState: State = .stopped
    private var done = DispatchSemaphore(value: 0)

    private var photoSource: (() -> MiniDisplayPhotoFrame)?

    init(brightness: Int) { self.brightness = brightness }

    /// Supplies the photo shown in the right-hand 4:3 panel, or nil for the
    /// plain full-width dashboard. Called from the engine thread every frame.
    func setPhotoSource(_ source: (() -> MiniDisplayPhotoFrame)?) {
        locked { photoSource = source }
    }

    private var currentPhotoSource: (() -> MiniDisplayPhotoFrame)? { locked { photoSource } }

    private var agendaSource: (() -> MiniDisplayAgenda?)?

    /// Supplies the agenda card (calendar events / reminders), or nil to hide it.
    func setAgendaSource(_ source: (() -> MiniDisplayAgenda?)?) {
        locked { agendaSource = source }
    }

    private var currentAgendaSource: (() -> MiniDisplayAgenda?)? { locked { agendaSource } }

    private var topApps = false

    /// Shows the TOP APPS card (top CPU / memory apps); process scanning runs only while on.
    func setShowsTopApps(_ on: Bool) { locked { topApps = on } }

    private var showsTopApps: Bool { locked { topApps } }

    private var claudeSource: (() -> ClaudeLimitsMonitor.Snapshot?)?

    /// Supplies the Claude plan usage card, or nil to hide it.
    func setClaudeSource(_ source: (() -> ClaudeLimitsMonitor.Snapshot?)?) {
        locked { claudeSource = source }
    }

    private var currentClaudeSource: (() -> ClaudeLimitsMonitor.Snapshot?)? { locked { claudeSource } }

    private func locked<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }

    private var isRunning: Bool { locked { running } }
    var currentBrightness: Int { locked { brightness } }

    func setBrightness(_ v: Int) {
        locked {
            brightness = max(0, min(100, v))
            brightnessDirty = true
        }
    }

    func start() {
        let shouldStart: Bool = locked {
            if running { return false }
            running = true
            return true
        }
        guard shouldStart else { return }
        done = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in self?.loop() }
        t.name = "snappy.minidisplay"
        t.qualityOfService = .utility
        t.start()
    }

    /// Stops the loop and closes the panel session; waits up to 3 s.
    func stop() {
        let wasRunning: Bool = locked {
            let r = running
            running = false
            return r
        }
        if wasRunning { _ = done.wait(timeout: .now() + 3) }
        post(.stopped)
    }

    private func takeBrightness() -> Int? {
        locked {
            guard brightnessDirty else { return nil }
            brightnessDirty = false
            return brightness
        }
    }

    private func post(_ s: State) {
        let changed: Bool = locked {
            guard s != lastState else { return false }
            lastState = s
            return true
        }
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in self?.onState?(s) }
    }

    private func nap(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while isRunning && Date() < end { usleep(100_000) }
    }

    private func loop() {
        defer { done.signal() }
        let sensors = MiniDisplaySensors()
        sensors.logThermalSensors()
        var waitingLogged = false

        while isRunning {
            guard let path = MiniDisplaySerialPort.findPorts().first else {
                if !waitingLogged {
                    MiniDisplayLog.log("waiting for panel (/dev/cu.usbmodem*)")
                    waitingLogged = true
                }
                post(.waiting)
                nap(2)
                continue
            }
            waitingLogged = false

            let device = MiniDisplayDevice(path: path)
            do {
                _ = takeBrightness()
                try device.connect(brightness: currentBrightness)
                let info = device.info
                MiniDisplayLog.log("connected \(path): \(info.model) fw \(info.version) "
                                   + "\(info.width)x\(info.height) angle \(info.angle) "
                                   + "maxJPEG \(info.maxJpegBytes / 1024) KB")
                MiniDisplayLog.log("info: \(device.rawInfo)")
                post(.connected(model: info.shortModel, firmware: info.version))

                let renderer = MiniDisplayRenderer(width: info.width, height: info.height)
                // The firmware rotates every frame by `angle`; pre-rotating by the
                // same angle comes out upright (verified on the 9.16", angle 270).
                renderer.rotation = info.angle

                var snap = sensors.sample()
                var lastSample = Date()
                var lastPreview = Date.distantPast
                var checkedJpeg = false
                var jpegQuality: CGFloat = 0.85
                while isRunning {
                    let t0 = Date()
                    let photo = currentPhotoSource?()
                    let interval = 1.0 / (photo?.isTransitioning == true ? transitionFps : fps)
                    if let b = takeBrightness() {
                        try device.setBrightness(b)
                        try device.keepAlive()
                    }
                    renderer.brightness = Double(currentBrightness) / 100
                    let wantsTop = showsTopApps
                    sensors.wantsTopApps = wantsTop
                    if t0.timeIntervalSince(lastSample) >= 1 {
                        snap = sensors.sample()
                        lastSample = t0
                    }
                    guard let img = renderer.render(snap, now: t0, photoPanel: photo != nil, photo: photo,
                                                    agenda: currentAgendaSource?() ?? nil,
                                                    claude: currentClaudeSource?() ?? nil,
                                                    topApps: wantsTop),
                          let jpeg = MiniDisplayJPEG.encode(img, maxBytes: info.maxJpegBytes, quality: &jpegQuality) else {
                        MiniDisplayLog.log("render/encode failed")
                        nap(1)
                        continue
                    }
                    if !checkedJpeg {
                        MiniDisplayLog.log("JPEG \(jpeg.count / 1024) KB: \(MiniDisplayJPEG.describe(jpeg))")
                        checkedJpeg = true
                    }
                    try device.send(jpeg: jpeg)

                    if let dir = MiniDisplayLog.debugDir, t0.timeIntervalSince(lastPreview) >= 5 {
                        try? jpeg.write(to: dir.appendingPathComponent("preview.jpg"))
                        lastPreview = t0
                    }
                    let spent = Date().timeIntervalSince(t0)
                    if spent < interval { usleep(useconds_t((interval - spent) * 1_000_000)) }
                }
                device.disconnect()
                MiniDisplayLog.log("disconnected")
            } catch {
                MiniDisplayLog.log("connection error on \(path): \(error) - retrying in 2 s")
                post(.error("\(error)"))
                device.disconnect()
                nap(2)
            }
        }
        MiniDisplayLog.log("engine stopped")
    }
}
