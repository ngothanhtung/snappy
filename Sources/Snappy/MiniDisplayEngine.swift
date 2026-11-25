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
    /// Frames per second. The panel needs a still re-sent ~4x/s anyway.
    let fps = 4.0

    private let lock = NSLock()
    private var running = false
    private var brightness: Int
    private var brightnessDirty = false
    private var lastState: State = .stopped
    private var done = DispatchSemaphore(value: 0)

    init(brightness: Int) { self.brightness = brightness }

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
                let interval = 1.0 / fps

                while isRunning {
                    let t0 = Date()
                    if let b = takeBrightness() {
                        try device.setBrightness(b)
                        try device.keepAlive()
                    }
                    renderer.brightness = Double(currentBrightness) / 100
                    if t0.timeIntervalSince(lastSample) >= 1 {
                        snap = sensors.sample()
                        lastSample = t0
                    }
                    guard let img = renderer.render(snap, now: t0),
                          let jpeg = MiniDisplayJPEG.encode(img, maxBytes: info.maxJpegBytes) else {
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
