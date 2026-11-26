import XCTest
@testable import SnappyCore

/// DDC/CI packet building and reply parsing. Reply bytes are real captures
/// from a Dell U4320Q, Samsung S32B80P and ARZOPA panel (Apple Silicon IOAVService).
final class DDCTests: XCTestCase {

    func testGetRequestPacket() {
        // 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x10 = 0xAC
        XCTAssertEqual(DDCPacket.getVCP(.brightness), [0x82, 0x01, 0x10, 0xAC])
    }

    func testSetPacket() {
        let p = DDCPacket.setVCP(.brightness, value: 75)
        XCTAssertEqual(Array(p.prefix(5)), [0x84, 0x03, 0x10, 0x00, 0x4B])
        XCTAssertEqual(p[5], [0x84, 0x03, 0x10, 0x00, 0x4B].reduce(UInt8(0x6E ^ 0x51), ^))
    }

    func testSetPacketHighByte() {
        let p = DDCPacket.setVCP(.volume, value: 0x0123)
        XCTAssertEqual(p[3], 0x01)
        XCTAssertEqual(p[4], 0x23)
    }

    func testParsesDellBrightness() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x4B, 0x8B]
        XCTAssertEqual(DDCPacket.parseReply(reply, for: .brightness), DDCReading(current: 75, maximum: 100))
    }

    func testParsesWithTrailingBytes() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x62, 0x00, 0x00, 0x64, 0x00, 0x32, 0x80, 0x00]
        XCTAssertEqual(DDCPacket.parseReply(reply, for: .volume), DDCReading(current: 50, maximum: 100))
    }

    func testRejectsNullMessage() {
        let reply: [UInt8] = [0x6E, 0x80, 0xBE, 0x6E, 0x80, 0xBE, 0x6E, 0x80, 0xBE, 0x6E, 0x80]
        XCTAssertNil(DDCPacket.parseReply(reply, for: .brightness))
    }

    func testRejectsUnsupportedCode() {
        // Dell: mute is "unsupported VCP code" (result 0x01).
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x01, 0x8D, 0x01, 0xFF, 0xFF, 0x00, 0x00, 0x39]
        XCTAssertNil(DDCPacket.parseReply(reply, for: .mute))
    }

    func testRejectsStaleReplyForOtherCode() {
        // A brightness reply returned while contrast was asked for.
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x4B, 0x8B]
        XCTAssertNil(DDCPacket.parseReply(reply, for: .contrast))
    }

    func testRejectsBadChecksum() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x4B, 0x8C]
        XCTAssertNil(DDCPacket.parseReply(reply, for: .brightness))
    }

    func testRejectsShortReply() {
        XCTAssertNil(DDCPacket.parseReply([0x6E, 0x88, 0x02], for: .brightness))
    }

    func testReadingFraction() {
        XCTAssertEqual(DDCReading(current: 50, maximum: 100).fraction, 0.5)
        XCTAssertEqual(DDCReading(current: 5, maximum: 0).fraction, 0)
        XCTAssertEqual(DDCReading(current: 120, maximum: 100).fraction, 1)
    }

    // MARK: Pairing

    func testEISAVendorNumbers() {
        // Values from CGDisplayVendorNumber on real displays.
        XCTAssertEqual(DisplayPairing.vendorNumber(fromEISA: "DEL"), 4268)
        XCTAssertEqual(DisplayPairing.vendorNumber(fromEISA: "GSM"), 7789)
        XCTAssertEqual(DisplayPairing.vendorNumber(fromEISA: "SAM"), 19501)
        XCTAssertEqual(DisplayPairing.vendorNumber(fromEISA: "GWD"), 7908)
        XCTAssertNil(DisplayPairing.vendorNumber(fromEISA: "D1L"))
        XCTAssertNil(DisplayPairing.vendorNumber(fromEISA: "DELL"))
    }

    private let dellPath = "IOService:/AppleARMPE/arm-io/AppleT600xIO/dispext0@88000000/AppleCLCD2"
    private let samPath = "IOService:/AppleARMPE/arm-io/AppleT600xIO/dispext1@8B000000/AppleCLCD2"

    private var dellCandidate: I2CCandidate {
        I2CCandidate(framebufferPath: dellPath, manufacturerID: "DEL", productID: 16848,
                     serialNumber: 825767244, productName: "DELL U4320Q")
    }
    private var samCandidate: I2CCandidate {
        I2CCandidate(framebufferPath: samPath, manufacturerID: "SAM", productID: 29171,
                     serialNumber: 810372684, productName: "S32B80P")
    }

    func testMatchesByLocation() {
        let displays = [
            DisplayIdentity(location: samPath, vendor: 19501, model: 29171, serial: 810372684, name: "S32B80P"),
            DisplayIdentity(location: dellPath, vendor: 4268, model: 16848, serial: 825767244, name: "DELL U4320Q"),
        ]
        XCTAssertEqual(DisplayPairing.match(displays: displays, candidates: [dellCandidate, samCandidate]),
                       [0: 1, 1: 0])
    }

    func testLocationMismatchNeverPairs() {
        // Same model, different port: identical attributes must not win over the path.
        let display = DisplayIdentity(location: "IOService:/other", vendor: 4268, model: 16848,
                                      serial: 825767244, name: "DELL U4320Q")
        XCTAssertEqual(DisplayPairing.score(display, dellCandidate), 0)
    }

    func testFallsBackToAttributes() {
        let displays = [
            DisplayIdentity(location: nil, vendor: 4268, model: 16848, serial: 825767244, name: "DELL U4320Q"),
            DisplayIdentity(location: nil, vendor: 1, model: 2, serial: 3, name: "Sidecar"),
        ]
        XCTAssertEqual(DisplayPairing.match(displays: displays, candidates: [samCandidate, dellCandidate]), [0: 1])
    }

    func testTwoIdenticalMonitorsUseSerial() {
        let a = I2CCandidate(framebufferPath: "a", manufacturerID: "DEL", productID: 1, serialNumber: 10, productName: nil)
        let b = I2CCandidate(framebufferPath: "b", manufacturerID: "DEL", productID: 1, serialNumber: 20, productName: nil)
        let displays = [
            DisplayIdentity(location: nil, vendor: 4268, model: 1, serial: 20, name: nil),
            DisplayIdentity(location: nil, vendor: 4268, model: 1, serial: 10, name: nil),
        ]
        XCTAssertEqual(DisplayPairing.match(displays: displays, candidates: [a, b]), [0: 1, 1: 0])
    }
}
