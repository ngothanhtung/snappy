import Foundation

/// MCCS VCP codes Snappy reads/writes over DDC/CI.
public enum VCPCode: UInt8, CaseIterable, Sendable {
    case brightness = 0x10
    case contrast = 0x12
    case volume = 0x62
    /// 1 = muted, 2 = not muted.
    case mute = 0x8D
}

/// A VCP feature's current and maximum value, as the monitor reports it.
public struct DDCReading: Equatable, Sendable {
    public let current: UInt16
    public let maximum: UInt16

    public init(current: UInt16, maximum: UInt16) {
        self.current = current
        self.maximum = maximum
    }

    /// Current value as a 0…1 fraction of the maximum (0 when the maximum is 0).
    public var fraction: Double {
        maximum == 0 ? 0 : min(1, Double(current) / Double(maximum))
    }
}

/// DDC/CI packets as written to / read from I2C address 0x37, sub-address 0x51
/// (the host's source address). Verified against Dell U4320Q, Samsung S32B80P
/// and an ARZOPA portable panel over Apple Silicon IOAVService.
public enum DDCPacket {
    /// I2C chip address of the monitor's DDC/CI endpoint.
    public static let chipAddress: UInt8 = 0x37
    /// Host source address, sent as the I2C "data address".
    public static let hostAddress: UInt8 = 0x51
    /// Length of a VCP reply as returned by IOAVServiceReadI2C.
    public static let replyLength = 11

    /// Set VCP Feature: `84 03 code hi lo chk`.
    public static func setVCP(_ code: VCPCode, value: UInt16) -> [UInt8] {
        let body: [UInt8] = [0x84, 0x03, code.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)]
        return body + [checksum(body)]
    }

    /// Get VCP Feature request: `82 01 code chk`.
    public static func getVCP(_ code: VCPCode) -> [UInt8] {
        let body: [UInt8] = [0x82, 0x01, code.rawValue]
        return body + [checksum(body)]
    }

    /// Checksum of an outgoing packet: XOR of the destination (0x6E), the source
    /// (0x51) and every byte of the packet.
    public static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0x6E ^ hostAddress, ^)
    }

    /// Parses a Get VCP Feature reply:
    /// `6E 88 02 result code type maxHi maxLo curHi curLo chk`
    /// where the checksum is 0x50 XOR the ten preceding bytes. Returns nil for
    /// null messages (`6E 80 BE` — the monitor was busy), bad checksums,
    /// unsupported codes (result ≠ 0) or replies for another code.
    public static func parseReply(_ bytes: [UInt8], for code: VCPCode) -> DDCReading? {
        guard bytes.count >= replyLength else { return nil }
        let b = Array(bytes.prefix(replyLength))
        let expected = b[0..<10].reduce(UInt8(0x50), ^)
        guard expected == b[10],
              b[2] == 0x02,          // VCP reply opcode
              b[3] == 0x00,          // result: no error
              b[4] == code.rawValue
        else { return nil }
        let maximum = UInt16(b[6]) << 8 | UInt16(b[7])
        let current = UInt16(b[8]) << 8 | UInt16(b[9])
        return DDCReading(current: current, maximum: maximum)
    }
}

/// Identity of an I2C service's framebuffer, as found in the IORegistry.
public struct I2CCandidate: Equatable, Sendable {
    public var framebufferPath: String
    public var manufacturerID: String?
    public var productID: UInt32
    public var serialNumber: UInt32
    public var productName: String?

    public init(framebufferPath: String, manufacturerID: String?, productID: UInt32,
                serialNumber: UInt32, productName: String?) {
        self.framebufferPath = framebufferPath
        self.manufacturerID = manufacturerID
        self.productID = productID
        self.serialNumber = serialNumber
        self.productName = productName
    }
}

/// Identity of a CGDirectDisplayID.
public struct DisplayIdentity: Equatable, Sendable {
    public var location: String?
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var name: String?

    public init(location: String?, vendor: UInt32, model: UInt32, serial: UInt32, name: String?) {
        self.location = location
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.name = name
    }
}

/// Pairs displays with the I2C services that drive them.
public enum DisplayPairing {
    /// EDID packs the 3-letter EISA manufacturer ID into 15 bits, 5 per letter
    /// ('A' = 1); CGDisplayVendorNumber returns that number.
    public static func vendorNumber(fromEISA id: String) -> UInt32? {
        let letters = Array(id.uppercased().unicodeScalars)
        guard letters.count == 3 else { return nil }
        var n: UInt32 = 0
        for l in letters {
            guard l.value >= 65, l.value <= 90 else { return nil }
            n = n << 5 | (l.value - 64)
        }
        return n
    }

    /// Score of how well a candidate matches a display; 0 = not this display.
    /// The IORegistry path of the framebuffer is decisive when known.
    public static func score(_ display: DisplayIdentity, _ candidate: I2CCandidate) -> Int {
        if let location = display.location, !location.isEmpty {
            return location == candidate.framebufferPath ? 100 : 0
        }
        var score = 0
        if let id = candidate.manufacturerID, vendorNumber(fromEISA: id) == display.vendor { score += 1 }
        else if candidate.manufacturerID != nil { return 0 }
        if candidate.productID == display.model { score += 2 } else { return 0 }
        if candidate.serialNumber != 0, candidate.serialNumber == display.serial { score += 4 }
        if let a = candidate.productName, let b = display.name, a == b { score += 1 }
        return score
    }

    /// Display index → candidate index. Each candidate is used at most once,
    /// best scores first.
    public static func match(displays: [DisplayIdentity], candidates: [I2CCandidate]) -> [Int: Int] {
        var pairs: [(d: Int, c: Int, s: Int)] = []
        for (d, display) in displays.enumerated() {
            for (c, candidate) in candidates.enumerated() {
                let s = score(display, candidate)
                if s > 0 { pairs.append((d, c, s)) }
            }
        }
        pairs.sort { $0.s != $1.s ? $0.s > $1.s : ($0.d, $0.c) < ($1.d, $1.c) }
        var result: [Int: Int] = [:]
        var usedCandidates = Set<Int>()
        for p in pairs where result[p.d] == nil && !usedCandidates.contains(p.c) {
            result[p.d] = p.c
            usedCandidates.insert(p.c)
        }
        return result
    }
}
