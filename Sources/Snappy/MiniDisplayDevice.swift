import Foundation
import SnappyCore

/// Logging for the mini display. Goes to NSLog with the usual `Snappy:` prefix;
/// when `SNAPPY_MINIDISPLAY_DEBUG_DIR` is set (dev runs), also to a file there,
/// next to a periodically saved `preview.jpg` of the frame being sent.
enum MiniDisplayLog {
    static let debugDir: URL? = ProcessInfo.processInfo.environment["SNAPPY_MINIDISPLAY_DEBUG_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    private static let queue = DispatchQueue(label: "snappy.minidisplay.log")
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func log(_ message: String) {
        NSLog("Snappy: MiniDisplay: %@", message)
        guard let dir = debugDir else { return }
        let line = "[\(timeFormat.string(from: Date()))] \(message)\n"
        queue.async {
            let url = dir.appendingPathComponent("minidisplay.log")
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

/// One open session with a Jungle Leopard panel over its serial port.
final class MiniDisplayDevice {
    let port: MiniDisplaySerialPort
    private(set) var info = MiniDisplayInfo()
    private(set) var rawInfo = ""
    private var lastKeepAlive = Date.distantPast

    init(path: String) { port = MiniDisplaySerialPort(path: path) }

    func connect(brightness: Int?) throws {
        try port.open()
        try send(.getInfo)
        if let body = readReply() {
            rawInfo = String(decoding: body, as: UTF8.self)
            if let parsed = MiniDisplayInfo(json: body) { info = parsed }
        }
        if let brightness { try setBrightness(brightness) }
        try keepAlive()
        usleep(100_000)
    }

    /// Accepted by the panel; on the 9.16" fw 5.3 it does not dim the backlight,
    /// so the renderer also dims in software.
    func setBrightness(_ percent: Int) throws {
        try send(.setLight, payload: [UInt8(max(0, min(100, percent)))])
        usleep(100_000)
    }

    func keepAlive() throws {
        try send(.live)
        lastKeepAlive = Date()
    }

    func send(jpeg: Data) throws {
        try port.write(Data(MiniDisplayProtocol.imageFrame(jpeg: [UInt8](jpeg))))
        if Date().timeIntervalSince(lastKeepAlive) >= MiniDisplayProtocol.keepAliveInterval {
            try keepAlive()
        }
    }

    func disconnect() {
        if port.isOpen { try? send(.close) }
        port.close()
    }

    private func send(_ c: MiniDisplayProtocol.Command, payload: [UInt8] = []) throws {
        try port.write(Data(MiniDisplayProtocol.command(c, payload: payload)))
    }

    private func readReply(timeout: TimeInterval = 1.5) -> [UInt8]? {
        var buf: [UInt8] = []
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            buf += [UInt8](port.read(timeout: 0.1))
            if let payload = MiniDisplayProtocol.replyPayload(in: buf) { return payload }
        }
        return nil
    }
}
