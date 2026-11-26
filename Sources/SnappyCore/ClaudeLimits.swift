import Foundation

/// Claude plan usage limits as Claude Code shows them ("Session (5hr)" and
/// "Weekly (7 day)" utilization with reset times). Pure parsing and wording;
/// the app reads Claude Code's credentials and calls the usage endpoint.
public enum ClaudeLimits {

    /// One limit window: how much of it is used (0–100 %) and when it resets.
    public struct Window: Equatable, Sendable, Codable {
        public var percent: Double
        public var resetsAt: Date?
        public init(percent: Double, resetsAt: Date?) {
            self.percent = percent
            self.resetsAt = resetsAt
        }
    }

    public struct Usage: Equatable, Sendable, Codable {
        public var session: Window?      // five_hour
        public var weekly: Window?       // seven_day
        public var weeklyOpus: Window?   // seven_day_opus, when the plan has one
        public var weeklySonnet: Window? // seven_day_sonnet, when the plan has one
        public init(session: Window? = nil, weekly: Window? = nil,
                    weeklyOpus: Window? = nil, weeklySonnet: Window? = nil) {
            self.session = session
            self.weekly = weekly
            self.weeklyOpus = weeklyOpus
            self.weeklySonnet = weeklySonnet
        }
    }

    /// What we need from Claude Code's stored login.
    public struct Credentials: Equatable, Sendable {
        public var accessToken: String
        public var expiresAt: Date?
        public var subscriptionType: String?
        public init(accessToken: String, expiresAt: Date?, subscriptionType: String?) {
            self.accessToken = accessToken
            self.expiresAt = expiresAt
            self.subscriptionType = subscriptionType
        }

        public func isExpired(at now: Date) -> Bool { expiresAt.map { $0 <= now } ?? false }
    }

    /// Parses the usage endpoint's JSON (`{"five_hour":{"utilization":11,"resets_at":"…"}, …}`).
    /// Windows that are null or missing stay nil.
    public static func usage(fromJSON data: Data) -> Usage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func window(_ key: String) -> Window? {
            guard let w = obj[key] as? [String: Any],
                  let u = (w["utilization"] as? NSNumber)?.doubleValue, u.isFinite else { return nil }
            let reset = (w["resets_at"] as? String).flatMap(parseDate)
            return Window(percent: u, resetsAt: reset)
        }
        let usage = Usage(session: window("five_hour"), weekly: window("seven_day"),
                          weeklyOpus: window("seven_day_opus"), weeklySonnet: window("seven_day_sonnet"))
        return usage.session == nil && usage.weekly == nil ? nil : usage
    }

    /// Parses Claude Code's keychain item (`{"claudeAiOauth":{"accessToken":…,"expiresAt":ms,…}}`).
    public static func credentials(fromJSON data: Data) -> Credentials? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Credentials(accessToken: token, expiresAt: expires,
                           subscriptionType: oauth["subscriptionType"] as? String)
    }

    /// "pro" → "Claude Pro", "max" → "Claude Max", …
    public static func planName(_ subscriptionType: String?) -> String? {
        guard let t = subscriptionType?.lowercased(), !t.isEmpty else { return nil }
        switch t {
        case "pro": return "Claude Pro"
        case "max": return "Claude Max"
        case "team": return "Claude Team"
        case "enterprise": return "Claude Enterprise"
        case "free": return "Claude Free"
        default: return "Claude " + t.prefix(1).uppercased() + t.dropFirst()
        }
    }

    /// "11%" (rounded, clamped at 0).
    public static func percentText(_ w: Window) -> String {
        "\(Int(max(0, w.percent).rounded()))%"
    }

    /// "resets 14:40" today, "resets Tmrw 09:00", otherwise "resets Sun 29/11 16:00".
    /// `compact` (small cards): "↻ 14:40", "↻ Tmrw 09:00", "↻ Sun 16:00" (within a week).
    public static func resetText(_ date: Date?, now: Date, calendar: Calendar = .current,
                                 compact: Bool = false) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        let time = f.string(from: date)
        let lead = compact ? "\u{21BB} " : "resets "
        if calendar.isDate(date, inSameDayAs: now) { return lead + time }
        if let t = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           calendar.isDate(date, inSameDayAs: t) { return lead + "Tmrw \(time)" }
        f.dateFormat = compact && date.timeIntervalSince(now) < 6.5 * 86400 ? "EEE HH:mm" : "EEE dd/MM HH:mm"
        return lead + f.string(from: date)
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
