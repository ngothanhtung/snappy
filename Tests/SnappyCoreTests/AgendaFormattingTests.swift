import XCTest
@testable import SnappyCore

final class AgendaFormattingTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    private func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }

    private typealias E = AgendaFormatting.Event
    private typealias R = AgendaFormatting.Reminder

    func testUpcomingDropsPastAndLaterThanTomorrow() {
        let now = at(26, 10)
        let events = [
            E(title: "past", start: at(26, 8), end: at(26, 9), isAllDay: false),
            E(title: "now", start: at(26, 9, 30), end: at(26, 11), isAllDay: false),
            E(title: "later", start: at(26, 15), end: at(26, 16), isAllDay: false),
            E(title: "allday", start: at(26, 0), end: at(27, 0), isAllDay: true),
            E(title: "tmrw", start: at(27, 9), end: at(27, 10), isAllDay: false),
            E(title: "tmrwAllDay", start: at(27, 0), end: at(28, 0), isAllDay: true),
            E(title: "far", start: at(28, 9), end: at(28, 10), isAllDay: false),
        ]
        let titles = AgendaFormatting.upcoming(events, now: now, calendar: cal).map(\.title)
        XCTAssertEqual(titles, ["allday", "now", "later", "tmrwAllDay", "tmrw"])
    }

    func testEventLabels() {
        let now = at(26, 10)
        func label(_ e: E) -> String { AgendaFormatting.label(for: e, now: now, calendar: cal) }
        XCTAssertEqual(label(E(title: "", start: at(26, 9), end: at(26, 11), isAllDay: false)), "Now")
        XCTAssertEqual(label(E(title: "", start: at(26, 14, 30), end: at(26, 15), isAllDay: false)), "14:30")
        XCTAssertEqual(label(E(title: "", start: at(26, 0), end: at(27, 0), isAllDay: true)), "All day")
        XCTAssertEqual(label(E(title: "", start: at(27, 9), end: at(27, 10), isAllDay: false)), "Tmrw 09:00")
        XCTAssertEqual(label(E(title: "", start: at(27, 0), end: at(28, 0), isAllDay: true)), "Tmrw")
    }

    func testRemindersOrderOverdueFirstUndatedLast() {
        let list = [
            R(title: "undated", due: nil, hasTime: false),
            R(title: "later", due: at(28, 9), hasTime: true),
            R(title: "overdue", due: at(20, 9), hasTime: true),
            R(title: "today", due: at(26, 0), hasTime: false),
        ]
        XCTAssertEqual(AgendaFormatting.ordered(list).map(\.title), ["overdue", "today", "later", "undated"])
    }

    func testReminderLabels() {
        let now = at(26, 10)
        func label(_ r: R) -> String { AgendaFormatting.label(for: r, now: now, calendar: cal) }
        XCTAssertEqual(label(R(title: "", due: nil, hasTime: false)), "")
        XCTAssertEqual(label(R(title: "", due: at(25, 0), hasTime: false)), "Overdue")
        XCTAssertEqual(label(R(title: "", due: at(26, 9), hasTime: true)), "Overdue")
        XCTAssertEqual(label(R(title: "", due: at(26, 0), hasTime: false)), "Today")
        XCTAssertEqual(label(R(title: "", due: at(26, 16, 5), hasTime: true)), "16:05")
        XCTAssertEqual(label(R(title: "", due: at(27, 0), hasTime: false)), "Tmrw")
        XCTAssertEqual(label(R(title: "", due: at(30, 0), hasTime: false)), "30/11")
    }
}
