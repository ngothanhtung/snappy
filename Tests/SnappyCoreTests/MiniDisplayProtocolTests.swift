import XCTest
@testable import SnappyCore

final class MiniDisplayProtocolTests: XCTestCase {

    func testGetInfoCommandBytes() {
        // Verified against a real 9.16" panel.
        XCTAssertEqual(MiniDisplayProtocol.command(.getInfo), [0x55, 0xAA, 0x07, 0x00, 0x06, 0x0C, 0x01])
    }

    func testSetLightCommandBytes() {
        XCTAssertEqual(MiniDisplayProtocol.command(.setLight, payload: [80]),
                       [0x55, 0xAA, 0x08, 0x00, 0x03, 0x50, 0x5A, 0x01])
    }

    func testImageFrameLengthAndChecksum() {
        let jpeg: [UInt8] = [0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9]
        let f = MiniDisplayProtocol.imageFrame(jpeg: jpeg)
        XCTAssertEqual(Array(f[0..<4]), [6, 0, 0, 0])
        XCTAssertEqual(Array(f[4..<10]), jpeg)
        let sum = MiniDisplayProtocol.sum16(f[0..<10])
        XCTAssertEqual(f[10], UInt8(sum & 0xFF))
        XCTAssertEqual(f[11], UInt8(sum >> 8))
    }

    func testSum16Wraps() {
        XCTAssertEqual(MiniDisplayProtocol.sum16([UInt8](repeating: 0xFF, count: 300)), UInt16(truncatingIfNeeded: 300 * 255))
    }

    func testReplyPayloadSkipsNoiseAndWaitsForFullFrame() {
        let frame = MiniDisplayProtocol.command(.getInfo, payload: Array("{}".utf8))
        XCTAssertEqual(MiniDisplayProtocol.replyPayload(in: [0x00, 0x13] + frame), Array("{}".utf8))
        XCTAssertNil(MiniDisplayProtocol.replyPayload(in: Array(frame.dropLast())))
        XCTAssertNil(MiniDisplayProtocol.replyPayload(in: []))
    }

    func testInfoParsesRealReply() throws {
        let json = #"{"cmd":"info","data":{"width":1920,"height":462,"brightness":100,"model":"AW_F101-NOR-FL7707N-9.16inch-hor","version":"5.3","angle":270}}"#
        let info = try XCTUnwrap(MiniDisplayInfo(json: Array(json.utf8)))
        XCTAssertEqual(info.width, 1920)
        XCTAssertEqual(info.height, 462)
        XCTAssertEqual(info.angle, 270)
        XCTAssertEqual(info.shortModel, "9.16\"")
        XCTAssertTrue(info.isNewerFirmware)
        XCTAssertEqual(info.maxJpegBytes, 120 * 1024 - 4096)
    }

    func testInfoSwapsPortraitAndNormalisesAngle() throws {
        let json = #"{"width":462,"height":1920,"version":"2.8","angle":-90}"#
        let info = try XCTUnwrap(MiniDisplayInfo(json: Array(json.utf8)))
        XCTAssertEqual(info.width, 1920)
        XCTAssertEqual(info.height, 462)
        XCTAssertEqual(info.angle, 270)
        XCTAssertFalse(info.isNewerFirmware)
        XCTAssertEqual(info.maxJpegBytes, 90 * 1024 - 4096)
    }

    func testIsBaseline420() {
        // Minimal SOF0 segment: 3 components, Y 2x2, Cb/Cr 1x1.
        let sof0: [UInt8] = [0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0xCE, 0x07, 0x80, 0x03,
                             0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]
        XCTAssertTrue(MiniDisplayProtocol.isBaseline420(sof0))
        var yuv444 = sof0
        yuv444[13] = 0x11
        XCTAssertFalse(MiniDisplayProtocol.isBaseline420(yuv444))
        var progressive = sof0
        progressive[3] = 0xC2
        XCTAssertFalse(MiniDisplayProtocol.isBaseline420(progressive))
    }

    func testFormatOneDecimal() {
        XCTAssertEqual(MiniDisplayFormat.percent(0.085), "8.5%")
        XCTAssertEqual(MiniDisplayFormat.percent(1.4), "100.0%")
        XCTAssertEqual(MiniDisplayFormat.temperature(48.24), "48.2°C")
        XCTAssertEqual(MiniDisplayFormat.temperature(nil), "--.-°C")
        XCTAssertEqual(MiniDisplayFormat.rate(2048), "2.0 KB/s")
        XCTAssertEqual(MiniDisplayFormat.rate(5 * 1_048_576), "5.0 MB/s")
        XCTAssertEqual(MiniDisplayFormat.size(494_400_000_000).number, "494.4")
        XCTAssertEqual(MiniDisplayFormat.size(1_200_000_000_000).unit, "TB")
    }
}
