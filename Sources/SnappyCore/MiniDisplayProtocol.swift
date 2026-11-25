import Foundation

/// Wire protocol for the Jungle Leopard USB mini display (e.g. the 9.16" 1920x462
/// panel). The panel is a USB CDC-ACM serial device (VID 0x33C3) that takes
/// baseline 4:2:0 JPEG frames. Pure and unit tested; the serial I/O lives in the app.
///
///   Command frame: 55 AA | length u16 LE (= payload + 7) | cmd | payload | sum16 LE
///   Image frame:   length u32 LE | JPEG bytes | sum16 LE (sum covers the length too)
public enum MiniDisplayProtocol {

    public enum Command: UInt8, Sendable {
        case setLight = 0x03   // accepted by fw 5.3 but does not change the backlight
        case getInfo = 0x06    // replies with a JSON body
        case live = 0x11       // enter / hold live mode; resend every ~1.5 s
        case close = 0x21      // end the session (fw >= 3.1)
    }

    /// Keep-alive interval for `.live` while streaming.
    public static let keepAliveInterval: TimeInterval = 1.5

    /// Plain 16-bit sum of all bytes.
    public static func sum16<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var s: UInt32 = 0
        for b in bytes { s &+= UInt32(b) }
        return UInt16(truncatingIfNeeded: s)
    }

    public static func command(_ c: Command, payload: [UInt8] = []) -> [UInt8] {
        let total = payload.count + 7
        var f: [UInt8] = [0x55, 0xAA, UInt8(total & 0xFF), UInt8((total >> 8) & 0xFF), c.rawValue]
        f += payload
        let s = sum16(f)
        f += [UInt8(s & 0xFF), UInt8(s >> 8)]
        return f
    }

    public static func imageFrame(jpeg: [UInt8]) -> [UInt8] {
        let n = UInt32(jpeg.count)
        var f: [UInt8] = [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8(n >> 24)]
        f += jpeg
        let s = sum16(f)
        f += [UInt8(s & 0xFF), UInt8(s >> 8)]
        return f
    }

    /// Finds one complete reply frame in `buffer` and returns its payload
    /// (between the command byte and the checksum). Leading noise is skipped.
    public static func replyPayload(in buffer: [UInt8]) -> [UInt8]? {
        guard let start = (0..<max(0, buffer.count - 1)).first(where: { buffer[$0] == 0x55 && buffer[$0 + 1] == 0xAA })
        else { return nil }
        let b = Array(buffer[start...])
        guard b.count >= 7 else { return nil }
        let n = Int(b[2]) | (Int(b[3]) << 8)
        guard n >= 7, b.count >= n else { return nil }
        return Array(b[5..<(n - 2)])
    }

    /// Reads the SOF marker: baseline (SOF0) with 2x2,1x1,1x1 sampling is what the panel needs.
    public static func isBaseline420(_ jpeg: [UInt8]) -> Bool {
        var i = 2
        while i + 9 < jpeg.count {
            guard jpeg[i] == 0xFF else { i += 1; continue }
            let marker = jpeg[i + 1]
            let len = Int(jpeg[i + 2]) << 8 | Int(jpeg[i + 3])
            if marker == 0xC0 || marker == 0xC2 {
                guard marker == 0xC0, jpeg[i + 9] == 3, i + 17 < jpeg.count else { return false }
                return jpeg[i + 11] == 0x22 && jpeg[i + 14] == 0x11 && jpeg[i + 17] == 0x11
            }
            i += 2 + len
        }
        return false
    }
}

/// What the panel reports for `getInfo`.
public struct MiniDisplayInfo: Equatable, Sendable {
    public var model: String
    public var version: String
    public var width: Int
    public var height: Int
    /// Rotation the firmware applies to every frame; we pre-rotate by the same angle.
    public var angle: Int

    public init(model: String = "?", version: String = "0", width: Int = 1920, height: Int = 480, angle: Int = 0) {
        self.model = model
        self.version = version
        self.width = width
        self.height = height
        self.angle = angle
    }

    /// Parses the JSON reply body (`{"cmd":"info","data":{...}}` or a bare object).
    public init?(json: [UInt8]) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json)) as? [String: Any] else { return nil }
        let d = (obj["data"] as? [String: Any]) ?? obj
        func int(_ k: String) -> Int? { Int("\(d[k] ?? "")") }
        self.init(model: "\(d["model"] ?? "?")", version: "\(d["version"] ?? "0")",
                  width: int("width") ?? 1920, height: int("height") ?? 480,
                  angle: ((int("angle") ?? 0) % 360 + 360) % 360)
        if height > width { swap(&width, &height) }  // some panels report portrait
    }

    /// Firmware newer than 2.8 accepts larger frames and 60 fps.
    public var isNewerFirmware: Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        let major = parts.first ?? 0, minor = parts.count > 1 ? parts[1] : 0
        return major > 2 || (major == 2 && minor > 8)
    }

    /// Largest JPEG to send, with ~4 KB headroom (90 KB / 120 KB for the 9.16").
    public var maxJpegBytes: Int { (isNewerFirmware ? 120 : 90) * 1024 - 4096 }

    /// "AW_F101-NOR-FL7707N-9.16inch-hor" -> "9.16\""
    public var shortModel: String {
        guard let r = model.range(of: #"\d+(\.\d+)?inch"#, options: .regularExpression) else { return model }
        return model[r].replacingOccurrences(of: "inch", with: "\"")
    }
}

/// Number formatting for the dashboard (one decimal everywhere, English labels).
public enum MiniDisplayFormat {
    public static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", max(0, min(1, fraction)) * 100)
    }

    public static func temperature(_ celsius: Double?) -> String {
        celsius.map { String(format: "%.1f°C", $0) } ?? "--.-°C"
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        let v = max(0, bytesPerSecond)
        if v >= 1_048_576 { return String(format: "%.1f MB/s", v / 1_048_576) }
        return String(format: "%.1f KB/s", v / 1024)
    }

    /// Decimal (Finder-style) size number and its unit: (494.4, "GB"), (1.2, "TB").
    public static func size(_ bytes: Double) -> (number: String, unit: String) {
        let gb = bytes / 1_000_000_000
        return gb >= 1000 ? (String(format: "%.1f", gb / 1000), "TB") : (String(format: "%.1f", gb), "GB")
    }
}
