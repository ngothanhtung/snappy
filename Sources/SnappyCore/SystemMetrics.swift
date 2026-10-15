import Foundation

/// Cumulative CPU tick counters (as reported by `HOST_CPU_LOAD_INFO`).
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// CPU usage between two samples, as fractions in 0...1.
public struct CPULoad: Equatable, Sendable {
    public var user: Double
    public var system: Double
    public var total: Double { user + system }
}

public enum DiskLevel: Equatable, Sendable {
    case ok, low, critical
}

/// Pure math and wording for the quick panel's live system readings.
public enum SystemMetrics {

    /// Load between two tick samples; nil if no time passed or counters reset.
    public static func cpuLoad(from a: CPUTicks, to b: CPUTicks) -> CPULoad? {
        guard b.user >= a.user, b.system >= a.system, b.idle >= a.idle, b.nice >= a.nice else {
            return nil
        }
        let user = Double(b.user - a.user + b.nice - a.nice)
        let system = Double(b.system - a.system)
        let idle = Double(b.idle - a.idle)
        let total = user + system + idle
        guard total > 0 else { return nil }
        return CPULoad(user: user / total, system: system / total)
    }

    /// Memory pressure in 0...1 from the kernel's free-memory level
    /// (`kern.memorystatus_level`, 0–100, higher = more free).
    public static func memoryPressure(freeLevel: Int) -> Double {
        Double(100 - min(max(freeLevel, 0), 100)) / 100
    }

    /// Bytes added to a counter that is `bitWidth` bits wide, allowing for a
    /// single wrap-around (the 32-bit interface counters wrap every 4 GB).
    public static func counterDelta(previous: UInt64, current: UInt64,
                                    bitWidth: Int = 32) -> UInt64 {
        if current >= previous { return current - previous }
        guard bitWidth < 64 else { return 0 }
        let modulus = UInt64(1) << UInt64(bitWidth)
        guard previous < modulus, current < modulus else { return 0 } // counter reset
        return modulus - previous + current
    }

    /// Bytes per second over `interval`; 0 when the interval is unusable.
    public static func rate(bytes: UInt64, interval: TimeInterval) -> Double {
        interval > 0 ? Double(bytes) / interval : 0
    }

    /// "513 bytes/sec", "3 KB/sec", "1.2 MB/sec".
    public static func formatRate(bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value < 1000 { return "\(Int(value.rounded())) bytes/sec" }
        let units = ["KB", "MB", "GB"]
        var scaled = value / 1000
        var index = 0
        while scaled >= 1000, index < units.count - 1 {
            scaled /= 1000
            index += 1
        }
        let number = scaled < 10 ? String(format: "%.1f", scaled) : String(Int(scaled.rounded()))
        return "\(number) \(units[index])/sec"
    }

    /// "245 Mbps" style throughput from bits per second.
    public static func formatBitRate(bitsPerSecond: Double) -> String {
        let mbps = max(0, bitsPerSecond) / 1_000_000
        if mbps >= 1000 { return String(format: "%.2f Gbps", mbps / 1000) }
        if mbps >= 100 { return "\(Int(mbps.rounded())) Mbps" }
        return String(format: "%.1f Mbps", mbps)
    }

    /// Warn when the startup disk runs low: under 10% (or 20 GB) is low,
    /// under 5% (or 5 GB) is critical.
    public static func diskLevel(available: Int64, total: Int64) -> DiskLevel {
        guard total > 0 else { return .ok }
        let fraction = Double(available) / Double(total)
        let gb: Int64 = 1_000_000_000
        if fraction < 0.05 || available < 5 * gb { return .critical }
        if fraction < 0.10 || available < 20 * gb { return .low }
        return .ok
    }

    /// One-line battery status. `minutesRemaining` is nil/negative while
    /// macOS is still estimating.
    public static func batteryStatus(isCharging: Bool, isCharged: Bool, onACPower: Bool,
                                     minutesRemaining: Int?) -> String {
        if isCharged { return "Fully charged" }
        let time = minutesRemaining.flatMap { $0 > 0 ? formatMinutes($0) : nil }
        if isCharging {
            return time.map { "Charging, \($0) until full" } ?? "Charging"
        }
        if onACPower { return "Not charging" }
        return time.map { "\($0) remaining" } ?? "On battery"
    }

    /// 125 → "2:05".
    public static func formatMinutes(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}
