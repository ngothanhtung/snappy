import Foundation

/// Pure selection, ordering and time labels for the mini display's agenda card
/// (calendar events + reminders). The app layer maps EventKit objects to these.
public enum AgendaFormatting {

    public struct Event: Equatable, Sendable {
        public var title: String
        public var start: Date
        public var end: Date
        public var isAllDay: Bool
        /// Caller's handle to map results back to its own objects.
        public var tag: Int
        public init(title: String, start: Date, end: Date, isAllDay: Bool, tag: Int = 0) {
            self.tag = tag
            self.title = title
            self.start = start
            self.end = end
            self.isAllDay = isAllDay
        }
    }

    public struct Reminder: Equatable, Sendable {
        public var title: String
        public var due: Date?
        /// Whether `due` carries a time of day (otherwise only the date counts).
        public var hasTime: Bool
        /// Caller's handle to map results back to its own objects.
        public var tag: Int
        public init(title: String, due: Date?, hasTime: Bool, tag: Int = 0) {
            self.tag = tag
            self.title = title
            self.due = due
            self.hasTime = hasTime
        }
    }

    /// Events still to come (or in progress) today and tomorrow: all-day ones
    /// first within each day, then by start time.
    public static func upcoming(_ events: [Event], now: Date, calendar: Calendar = .current) -> [Event] {
        let endOfTomorrow = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now))!
        return events
            .filter { $0.end > now && $0.start < endOfTomorrow }
            .sorted { a, b in
                let da = calendar.startOfDay(for: max(a.start, now))
                let db = calendar.startOfDay(for: max(b.start, now))
                if da != db { return da < db }
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.start < b.start
            }
    }

    /// "All day", "14:30", "Now" (in progress), or "Tmrw 09:00" / "Tmrw" for tomorrow.
    public static func label(for e: Event, now: Date, calendar: Calendar = .current) -> String {
        let tomorrow = !calendar.isDate(max(e.start, now), inSameDayAs: now)
        if e.isAllDay { return tomorrow ? "Tmrw" : "All day" }
        if e.start <= now { return "Now" }
        let t = time(e.start, calendar: calendar)
        return tomorrow ? "Tmrw \(t)" : t
    }

    /// Overdue first (oldest first), then due later (soonest first), then undated.
    public static func ordered(_ reminders: [Reminder]) -> [Reminder] {
        reminders.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            default: return false
            }
        }
    }

    /// "Overdue", "Today", "14:30" (today, timed), "Tmrw", "Mon 01/12"-style date, or "" if undated.
    public static func label(for r: Reminder, now: Date, calendar: Calendar = .current) -> String {
        guard let due = r.due else { return "" }
        let today = calendar.startOfDay(for: now)
        if r.hasTime ? due < now : due < today { return "Overdue" }
        if calendar.isDate(due, inSameDayAs: now) { return r.hasTime ? time(due, calendar: calendar) : "Today" }
        if let t = calendar.date(byAdding: .day, value: 1, to: today), calendar.isDate(due, inSameDayAs: t) {
            return "Tmrw"
        }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd/MM"
        return f.string(from: due)
    }

    private static func time(_ d: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
