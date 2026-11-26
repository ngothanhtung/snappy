import Foundation

/// Top apps by CPU and memory, Activity Monitor style. Pure: grouping helper
/// processes under their app, CPU % from CPU-time deltas, ranking. The app
/// layer reads the processes (libproc).
public enum ProcessUsage {

    /// One process at one moment.
    public struct Sample: Equatable, Sendable {
        public var pid: Int32
        public var app: String
        /// Total CPU time used so far, seconds.
        public var cpuTime: Double
        /// Physical footprint (Activity Monitor's "Memory"), bytes.
        public var memory: UInt64
        public init(pid: Int32, app: String, cpuTime: Double, memory: UInt64) {
            self.pid = pid
            self.app = app
            self.cpuTime = cpuTime
            self.memory = memory
        }
    }

    public struct Entry: Equatable, Sendable {
        public var app: String
        public var value: Double   // CPU: % of the whole machine (all cores = 100). Memory: bytes.
        public init(app: String, value: Double) {
            self.app = app
            self.value = value
        }
    }

    /// A running app the user sees (Dock or menu bar app), by its bundle folder.
    public struct App: Equatable, Sendable {
        public var name: String
        /// Bundle folder with symlinks resolved, e.g. "/Applications/Google Chrome.app".
        public var bundlePath: String
        public init(name: String, bundlePath: String) {
            self.name = name
            self.bundlePath = bundlePath
        }
    }

    /// The app a process belongs to: the outermost app bundle containing the
    /// process's executable — helpers that register as apps themselves (e.g.
    /// "Microsoft Edge Helper" inside Microsoft Edge.app) count toward the
    /// enclosing app. nil for everything
    /// else — system daemons, kernel tasks, command-line tools — so the top
    /// lists only show apps.
    public static func owningApp(executablePath path: String, apps: [App]) -> String? {
        guard !path.isEmpty else { return nil }
        var best: App?
        for app in apps where path.hasPrefix(app.bundlePath + "/") {
            if best == nil || app.bundlePath.count < best!.bundlePath.count { best = app }
        }
        return best?.name
    }

    /// Top apps by CPU over the interval between two samplings, as a share of
    /// the whole machine (`cores` cores = 100%), so app values add up to at most
    /// the total CPU load — not Activity Monitor's 100%-per-core. Processes not
    /// in `previous` (just started) only count from the next interval.
    public static func topCPU(previous: [Int32: Double], current: [Sample], elapsed: Double,
                              cores: Int = 1, limit: Int) -> [Entry] {
        guard elapsed > 0, cores > 0 else { return [] }
        var byApp: [String: Double] = [:]
        for s in current {
            guard let before = previous[s.pid] else { continue }
            let delta = max(0, s.cpuTime - before)
            byApp[s.app, default: 0] += delta / elapsed * 100 / Double(cores)
        }
        return ranked(byApp, limit: limit, minimum: 0.05)
    }

    /// Top apps by memory footprint.
    public static func topMemory(_ current: [Sample], limit: Int) -> [Entry] {
        var byApp: [String: Double] = [:]
        for s in current { byApp[s.app, default: 0] += Double(s.memory) }
        return ranked(byApp, limit: limit, minimum: 1)
    }

    private static func ranked(_ byApp: [String: Double], limit: Int, minimum: Double) -> [Entry] {
        byApp.filter { $0.value >= minimum }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { Entry(app: $0.key, value: $0.value) }
    }

    /// "12.3%" / "100%".
    public static func cpuText(_ percent: Double) -> String {
        percent >= 99.95 ? String(format: "%.0f%%", percent) : String(format: "%.1f%%", percent)
    }

    /// "850 MB" / "1.2 GB" (binary units, like Activity Monitor).
    public static func memoryText(_ bytes: Double) -> String {
        let mb = bytes / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}

/// `ProcessInfo.ThermalState` wording without Foundation's enum (keeps this testable).
public enum ThermalLevel: Int, Sendable {
    case nominal = 0, fair, serious, critical

    public var text: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }
}
