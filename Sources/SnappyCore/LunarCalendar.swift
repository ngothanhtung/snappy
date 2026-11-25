import Foundation

/// Vietnamese lunar calendar (Âm lịch), after Hồ Ngọc Đức's astronomical
/// algorithm. Uses UTC+7, which is why Foundation's `.chinese` calendar
/// (UTC+8) is not used: the two occasionally disagree, e.g. on Tết 1985 and 2007.
public struct LunarDate: Equatable, Sendable {
    public var day: Int
    public var month: Int
    public var year: Int
    public var isLeapMonth: Bool

    public init(day: Int, month: Int, year: Int, isLeapMonth: Bool = false) {
        self.day = day
        self.month = month
        self.year = year
        self.isLeapMonth = isLeapMonth
    }

    /// Heavenly stem + earthly branch of the year, e.g. "Bính Ngọ" for 2026.
    public var canChiYear: String {
        let can = ["Canh", "Tân", "Nhâm", "Quý", "Giáp", "Ất", "Bính", "Đinh", "Mậu", "Kỷ"]
        let chi = ["Thân", "Dậu", "Tuất", "Hợi", "Tý", "Sửu", "Dần", "Mão", "Thìn", "Tỵ", "Ngọ", "Mùi"]
        return can[((year % 10) + 10) % 10] + " " + chi[((year % 12) + 12) % 12]
    }

    /// "8/10 Bính Ngọ", with " nhuận" after the month when it is a leap month.
    public var shortText: String {
        "\(day)/\(month)\(isLeapMonth ? " nhuận" : "") \(canChiYear)"
    }
}

public enum LunarCalendar {
    /// Vietnam's time zone, in hours.
    public static let vietnamTimeZone = 7.0

    /// Lunar date for a solar (Gregorian) day.
    public static func lunarDate(day: Int, month: Int, year: Int, timeZone tz: Double = vietnamTimeZone) -> LunarDate {
        let dayNumber = jdFromDate(day, month, year)
        let k = Int(floor((Double(dayNumber) - 2_415_021.076998695) / 29.530588853))
        var monthStart = newMoonDay(k + 1, tz)
        if monthStart > dayNumber { monthStart = newMoonDay(k, tz) }

        var a11 = lunarMonth11(year, tz)
        var b11 = a11
        var lunarYear: Int
        if a11 >= monthStart {
            lunarYear = year
            a11 = lunarMonth11(year - 1, tz)
        } else {
            lunarYear = year + 1
            b11 = lunarMonth11(year + 1, tz)
        }
        let lunarDay = dayNumber - monthStart + 1
        let diff = (monthStart - a11) / 29
        var isLeap = false
        var lunarMonth = diff + 11
        if b11 - a11 > 365 {
            let leapDiff = leapMonthOffset(a11, tz)
            if diff >= leapDiff {
                lunarMonth = diff + 10
                if diff == leapDiff { isLeap = true }
            }
        }
        if lunarMonth > 12 { lunarMonth -= 12 }
        if lunarMonth >= 11 && diff < 4 { lunarYear -= 1 }
        return LunarDate(day: lunarDay, month: lunarMonth, year: lunarYear, isLeapMonth: isLeap)
    }

    /// Lunar date for `date` as seen in `calendar`'s time zone (the Mac's, by default).
    public static func lunarDate(for date: Date, calendar: Calendar = .current) -> LunarDate {
        let c = calendar.dateComponents([.day, .month, .year], from: date)
        return lunarDate(day: c.day ?? 1, month: c.month ?? 1, year: c.year ?? 2000)
    }

    // MARK: Astronomy (Hồ Ngọc Đức)

    static func jdFromDate(_ dd: Int, _ mm: Int, _ yy: Int) -> Int {
        let a = (14 - mm) / 12
        let y = yy + 4800 - a
        let m = mm + 12 * a - 3
        var jd = dd + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
        if jd < 2_299_161 { jd = dd + (153 * m + 2) / 5 + 365 * y + y / 4 - 32083 }
        return jd
    }

    /// Julian day number of the k-th new moon after 1900-01-01, in time zone `tz`.
    static func newMoonDay(_ k: Int, _ tz: Double) -> Int {
        let kd = Double(k)
        let t = kd / 1236.85, t2 = t * t, t3 = t2 * t
        let dr = Double.pi / 180
        var jd1 = 2_415_020.75933 + 29.53058868 * kd + 0.0001178 * t2 - 0.000000155 * t3
        jd1 += 0.00033 * sin((166.56 + 132.87 * t - 0.009173 * t2) * dr)
        let m = 359.2242 + 29.10535608 * kd - 0.0000333 * t2 - 0.00000347 * t3
        let mpr = 306.0253 + 385.81691806 * kd + 0.0107306 * t2 + 0.00001236 * t3
        let f = 21.2964 + 390.67050646 * kd - 0.0016528 * t2 - 0.00000239 * t3
        var c1 = (0.1734 - 0.000393 * t) * sin(m * dr) + 0.0021 * sin(2 * dr * m)
        c1 -= 0.4068 * sin(mpr * dr) - 0.0161 * sin(dr * 2 * mpr)
        c1 -= 0.0004 * sin(dr * 3 * mpr)
        c1 += 0.0104 * sin(dr * 2 * f) - 0.0051 * sin(dr * (m + mpr))
        c1 -= 0.0074 * sin(dr * (m - mpr)) - 0.0004 * sin(dr * (2 * f + m))
        c1 -= 0.0004 * sin(dr * (2 * f - m)) - 0.0006 * sin(dr * (2 * f + mpr))
        c1 += 0.0010 * sin(dr * (2 * f - mpr)) + 0.0005 * sin(dr * (2 * mpr + m))
        let deltaT = t < -11
            ? 0.001 + 0.000839 * t + 0.0002261 * t2 - 0.00000845 * t3 - 0.000000081 * t * t3
            : -0.000278 + 0.000265 * t + 0.000262 * t2
        let jdNew = jd1 + c1 - deltaT
        return Int(floor(jdNew + 0.5 + tz / 24))
    }

    /// Sun longitude sector (0...11, 30° each) at the start of day `jdn`.
    static func sunLongitude(_ jdn: Int, _ tz: Double) -> Int {
        let t = (Double(jdn) - 2_451_545.5 - tz / 24) / 36525, t2 = t * t
        let dr = Double.pi / 180
        let m = 357.52910 + 35999.05030 * t - 0.0001559 * t2 - 0.00000048 * t * t2
        let l0 = 280.46645 + 36000.76983 * t + 0.0003032 * t2
        var dl = (1.914600 - 0.004817 * t - 0.000014 * t2) * sin(dr * m)
        dl += (0.019993 - 0.000101 * t) * sin(dr * 2 * m) + 0.000290 * sin(dr * 3 * m)
        var l = (l0 + dl) * dr
        l -= Double.pi * 2 * floor(l / (Double.pi * 2))
        return Int(floor(l / Double.pi * 6))
    }

    /// Day number of the start of lunar month 11 (the one holding the winter solstice) of `yy`.
    static func lunarMonth11(_ yy: Int, _ tz: Double) -> Int {
        let off = jdFromDate(31, 12, yy) - 2_415_021
        let k = Int(floor(Double(off) / 29.530588853))
        var nm = newMoonDay(k, tz)
        if sunLongitude(nm, tz) >= 9 { nm = newMoonDay(k - 1, tz) }
        return nm
    }

    /// Index (after month 11 starting at `a11`) of the leap month.
    static func leapMonthOffset(_ a11: Int, _ tz: Double) -> Int {
        let k = Int(floor((Double(a11) - 2_415_021.076998695) / 29.530588853 + 0.5))
        var i = 1
        var arc = sunLongitude(newMoonDay(k + i, tz), tz)
        var last: Int
        repeat {
            last = arc
            i += 1
            arc = sunLongitude(newMoonDay(k + i, tz), tz)
        } while arc != last && i < 14
        return i - 1
    }
}
