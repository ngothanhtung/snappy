import XCTest
@testable import SnappyCore

final class ClaudeLimitsTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    private func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }

    func testParsesUsage() throws {
        let json = """
        {"five_hour":{"utilization":11.0,"resets_at":"2026-11-26T07:40:00.123+00:00"},
         "seven_day":{"utilization":53,"resets_at":"2026-11-29T09:00:00Z"},
         "seven_day_opus":null,"extra":{"x":1}}
        """
        let u = try XCTUnwrap(ClaudeLimits.usage(fromJSON: Data(json.utf8)))
        XCTAssertEqual(u.session?.percent, 11)
        XCTAssertEqual(u.session?.resetsAt?.timeIntervalSince1970 ?? 0,
                       at(26, 14, 40).timeIntervalSince1970 + 0.123, accuracy: 0.001)
        XCTAssertEqual(u.weekly?.percent, 53)
        XCTAssertEqual(u.weekly?.resetsAt, at(29, 16))
        XCTAssertNil(u.weeklyOpus)
    }

    func testUsageWithoutWindowsIsNil() {
        XCTAssertNil(ClaudeLimits.usage(fromJSON: Data(#"{"five_hour":null,"seven_day":null}"#.utf8)))
        XCTAssertNil(ClaudeLimits.usage(fromJSON: Data("nope".utf8)))
    }

    func testParsesCredentials() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"r","expiresAt":1795000000000,"subscriptionType":"pro"}}"#
        let c = try XCTUnwrap(ClaudeLimits.credentials(fromJSON: Data(json.utf8)))
        XCTAssertEqual(c.accessToken, "tok")
        XCTAssertEqual(c.expiresAt, Date(timeIntervalSince1970: 1_795_000_000))
        XCTAssertEqual(c.subscriptionType, "pro")
        XCTAssertTrue(c.isExpired(at: Date(timeIntervalSince1970: 1_795_000_001)))
        XCTAssertFalse(c.isExpired(at: Date(timeIntervalSince1970: 1_794_999_999)))
        XCTAssertNil(ClaudeLimits.credentials(fromJSON: Data(#"{"other":{}}"#.utf8)))
    }

    func testPlanNames() {
        XCTAssertEqual(ClaudeLimits.planName("pro"), "Claude Pro")
        XCTAssertEqual(ClaudeLimits.planName("max"), "Claude Max")
        XCTAssertEqual(ClaudeLimits.planName("ultra"), "Claude Ultra")
        XCTAssertNil(ClaudeLimits.planName(nil))
    }

    func testTexts() {
        let now = at(26, 10)
        XCTAssertEqual(ClaudeLimits.percentText(.init(percent: 10.6, resetsAt: nil)), "11%")
        XCTAssertEqual(ClaudeLimits.resetText(at(26, 14, 40), now: now, calendar: cal), "resets 14:40")
        XCTAssertEqual(ClaudeLimits.resetText(at(27, 9), now: now, calendar: cal), "resets Tmrw 09:00")
        XCTAssertEqual(ClaudeLimits.resetText(at(29, 16), now: now, calendar: cal), "resets Sun 29/11 16:00")
        XCTAssertEqual(ClaudeLimits.resetText(nil, now: now, calendar: cal), "")
        XCTAssertEqual(ClaudeLimits.resetText(at(26, 14, 40), now: now, calendar: cal, compact: true), "\u{21BB} 14:40")
        XCTAssertEqual(ClaudeLimits.resetText(at(29, 16), now: now, calendar: cal, compact: true), "\u{21BB} Sun 16:00")
        XCTAssertEqual(ClaudeLimits.resetText(at(30, 16).addingTimeInterval(86400 * 3), now: now, calendar: cal,
                                              compact: true), "\u{21BB} Thu 03/12 16:00")
    }
}
