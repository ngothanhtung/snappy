import XCTest
@testable import SnappyCore

final class LunarCalendarTests: XCTestCase {
    private func lunar(_ d: Int, _ m: Int, _ y: Int) -> LunarDate {
        LunarCalendar.lunarDate(day: d, month: m, year: y)
    }

    func testTet() {
        XCTAssertEqual(lunar(17, 2, 2026), LunarDate(day: 1, month: 1, year: 2026))
        XCTAssertEqual(lunar(29, 1, 2025), LunarDate(day: 1, month: 1, year: 2025))
        XCTAssertEqual(lunar(16, 2, 2026), LunarDate(day: 29, month: 12, year: 2025))
    }

    /// Years where Vietnam (UTC+7) and China (UTC+8) celebrate Tết on different days.
    func testVietnamTimeZoneDiffersFromChina() {
        XCTAssertEqual(lunar(17, 2, 2007), LunarDate(day: 1, month: 1, year: 2007))
        XCTAssertEqual(lunar(21, 1, 1985), LunarDate(day: 1, month: 1, year: 1985))
    }

    func testMidAutumn2026() {
        XCTAssertEqual(lunar(25, 9, 2026), LunarDate(day: 15, month: 8, year: 2026))
    }

    func testLeapMonths() {
        XCTAssertEqual(lunar(22, 3, 2023), LunarDate(day: 1, month: 2, year: 2023, isLeapMonth: true))
        XCTAssertEqual(lunar(25, 7, 2025), LunarDate(day: 1, month: 6, year: 2025, isLeapMonth: true))
        XCTAssertEqual(lunar(25, 6, 2025), LunarDate(day: 1, month: 6, year: 2025))
    }

    func testCanChiAndText() {
        XCTAssertEqual(LunarDate(day: 1, month: 1, year: 2026).canChiYear, "Bính Ngọ")
        XCTAssertEqual(LunarDate(day: 1, month: 1, year: 2025).canChiYear, "Ất Tỵ")
        XCTAssertEqual(LunarDate(day: 1, month: 1, year: 1984).canChiYear, "Giáp Tý")
        XCTAssertEqual(LunarDate(day: 18, month: 10, year: 2026).shortText, "18/10 Bính Ngọ")
        XCTAssertEqual(LunarDate(day: 1, month: 6, year: 2025, isLeapMonth: true).shortText, "1/6 nhuận Ất Tỵ")
    }

    func testToday() {
        XCTAssertEqual(lunar(26, 11, 2026), LunarDate(day: 18, month: 10, year: 2026))
    }
}
