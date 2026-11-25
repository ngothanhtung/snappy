import AppKit
import EventKit
import SnappyCore

/// One line on the agenda card.
struct MiniDisplayAgendaItem: Sendable {
    var label: String       // "14:30", "All day", "Overdue", …
    var title: String
    var color: CGColor      // calendar / reminder list colour
    var isAlert: Bool       // overdue reminder → label drawn in red
}

/// What the agenda card shows. A section is nil when it is switched off.
struct MiniDisplayAgenda: Sendable {
    var events: [MiniDisplayAgendaItem]?
    var reminders: [MiniDisplayAgendaItem]?
    var eventsNote: String?     // "No access to Calendar" etc.
    var remindersNote: String?
}

/// Reads upcoming calendar events and open reminders from EventKit for the
/// mini display. Refreshes every minute and whenever the store changes; the
/// latest agenda is kept in a thread-safe box for the engine thread.
@MainActor
final class MiniDisplayAgendaSource {
    let current = AgendaBox()

    var showsEvents = false { didSet { if showsEvents != oldValue { restart() } } }
    var showsReminders = false { didSet { if showsReminders != oldValue { restart() } } }

    /// Most lines either section ever needs (the card shows fewer when split).
    private let maxItems = 10
    private let store = EKEventStore()
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var eventsNote: String?
    private var remindersNote: String?
    private var events: [MiniDisplayAgendaItem] = []
    private var reminders: [MiniDisplayAgendaItem] = []
    /// Access prompts already on screen, so switching both on doesn't ask twice.
    private var askingEvents = false
    private var askingReminders = false

    var isActive: Bool { showsEvents || showsReminders }

    private func restart() {
        guard isActive else { stop(); return }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observer = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: store, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        requestAccessThenRefresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        current.set(nil)
    }

    private func requestAccessThenRefresh() {
        // Show the card right away, even while macOS is still asking for access.
        if showsEvents, EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            eventsNote = "Waiting for access\u{2026}"
        }
        if showsReminders, EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
            remindersNote = "Waiting for access\u{2026}"
        }
        publish()
        MiniDisplayLog.log("agenda: calendar access \(EKEventStore.authorizationStatus(for: .event).rawValue), "
                           + "reminders access \(EKEventStore.authorizationStatus(for: .reminder).rawValue) "
                           + "(3 = full)")
        var pending = 0
        func done() {
            pending -= 1
            if pending == 0 {
                MiniDisplayLog.log("agenda: access now calendar \(EKEventStore.authorizationStatus(for: .event).rawValue), "
                                   + "reminders \(EKEventStore.authorizationStatus(for: .reminder).rawValue)")
                refresh()
            }
        }
        if showsEvents && !askingEvents && EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            pending += 1
            askingEvents = true
            store.requestFullAccessToEvents { _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.askingEvents = false; done() }
                }
            }
        }
        if showsReminders && !askingReminders && EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
            pending += 1
            askingReminders = true
            store.requestFullAccessToReminders { _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.askingReminders = false; done() }
                }
            }
        }
        if pending == 0 && !askingEvents && !askingReminders { refresh() }
    }

    func refresh() {
        guard isActive else { return }
        let now = Date()
        if showsEvents {
            if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
                eventsNote = nil
                events = loadEvents(now: now)
            } else {
                eventsNote = "No access to Calendar"
                events = []
            }
        }
        publish()
        guard showsReminders else { return }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            remindersNote = "No access to Reminders"
            reminders = []
            publish()
            return
        }
        remindersNote = nil
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] found in
            let items = Self.reminderItems(found ?? [], now: now, limit: 10)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.showsReminders else { return }
                    self.reminders = items
                    self.publish()
                }
            }
        }
    }

    private func publish() {
        current.set(MiniDisplayAgenda(
            events: showsEvents ? events : nil,
            reminders: showsReminders ? reminders : nil,
            eventsNote: showsEvents ? eventsNote : nil,
            remindersNote: showsReminders ? remindersNote : nil))
    }

    private func loadEvents(now: Date) -> [MiniDisplayAgendaItem] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 2, to: start)!
        let found = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        let plain = found.enumerated().map { i, e in
            AgendaFormatting.Event(title: e.title ?? "", start: e.startDate, end: e.endDate,
                                   isAllDay: e.isAllDay, tag: i)
        }
        return AgendaFormatting.upcoming(plain, now: now).prefix(maxItems).map { p in
            let e = found[p.tag]
            return MiniDisplayAgendaItem(label: AgendaFormatting.label(for: p, now: now),
                                         title: e.title ?? "Untitled",
                                         color: e.calendar?.cgColor ?? CGColor(gray: 0.6, alpha: 1),
                                         isAlert: false)
        }
    }

    nonisolated private static func reminderItems(_ found: [EKReminder], now: Date, limit: Int) -> [MiniDisplayAgendaItem] {
        let cal = Calendar.current
        let plain = found.enumerated().map { i, r -> AgendaFormatting.Reminder in
            let comps = r.dueDateComponents
            let due = comps.flatMap { cal.date(from: $0) }
            return AgendaFormatting.Reminder(title: r.title ?? "", due: due, hasTime: comps?.hour != nil, tag: i)
        }
        return AgendaFormatting.ordered(plain).prefix(limit).map { p in
            let r = found[p.tag]
            let label = AgendaFormatting.label(for: p, now: now)
            return MiniDisplayAgendaItem(label: label, title: r.title ?? "Untitled",
                                         color: r.calendar?.cgColor ?? CGColor(gray: 0.6, alpha: 1),
                                         isAlert: label == "Overdue")
        }
    }

    final class AgendaBox: @unchecked Sendable {
        private let lock = NSLock()
        private var agenda: MiniDisplayAgenda?
        func set(_ a: MiniDisplayAgenda?) { lock.lock(); agenda = a; lock.unlock() }
        func get() -> MiniDisplayAgenda? { lock.lock(); defer { lock.unlock() }; return agenda }
    }
}
