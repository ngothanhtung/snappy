import AppKit
import CoreLocation
import CoreWLAN
import Darwin
import IOKit.ps
import Network
import SnappyCore

/// Live system readings for the quick panel. Samples every 2 s while
/// started; call `stop()` when the panel closes so nothing polls in the
/// background.
@MainActor
final class SystemMonitor: NSObject, ObservableObject {

    struct Disk {
        var name: String
        var available: Int64
        var total: Int64
        var level: DiskLevel { SystemMetrics.diskLevel(available: available, total: total) }
    }

    struct Memory {
        var pressure: Double
        var used: Int64
        var total: Int64
    }

    struct Battery {
        var percent: Int
        var status: String
        var isCharging: Bool
        var onACPower: Bool
    }

    enum Link { case wifi, ethernet, other, offline }

    struct NetworkState {
        var link: Link = .offline
        /// Wi-Fi network name; nil until Location access is granted.
        var name: String?
        var upBytesPerSecond: Double = 0
        var downBytesPerSecond: Double = 0
    }

    struct Drive: Identifiable {
        let url: URL
        let name: String
        let available: Int64
        let total: Int64
        var id: String { url.path }
    }

    @Published private(set) var disk: Disk?
    @Published private(set) var memory: Memory?
    @Published private(set) var cpu: CPULoad?
    @Published private(set) var battery: Battery?
    @Published private(set) var hasBattery = true
    @Published private(set) var network = NetworkState()
    @Published private(set) var drives: [Drive] = []
    @Published private(set) var canShowNetworkName = false
    @Published var driveError: String?

    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var lastTicks: CPUTicks?
    private var lastCounters: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var lastCountersAt: Date?
    private var volumeObservers: [NSObjectProtocol] = []
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()

    private static let host = mach_host_self()

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        updateLocationAccess()
        startPathMonitor()
        observeVolumes()
        refreshDrives()
        sample()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        volumeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        volumeObservers = []
        lastTicks = nil
        lastCounters = [:]
        lastCountersAt = nil
    }

    private func sample() {
        disk = Self.readDisk()
        memory = Self.readMemory()
        if let ticks = Self.readCPUTicks() {
            if let last = lastTicks { cpu = SystemMetrics.cpuLoad(from: last, to: ticks) ?? cpu }
            lastTicks = ticks
        }
        battery = Self.readBattery()
        hasBattery = battery != nil
        sampleNetwork()
    }

    // MARK: - Disk & memory & CPU

    static func readDisk() -> Disk? {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Disk(name: values.volumeLocalizedName ?? "Startup Disk",
                    available: available, total: Int64(total))
    }

    static func readMemory() -> Memory? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else { return nil }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var used: Int64 = 0
        if result == KERN_SUCCESS {
            // Activity Monitor's "Memory Used": app memory + wired + compressed.
            let pages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
                + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
            used = min(total, max(0, pages) * Int64(vm_kernel_page_size))
        }
        return Memory(pressure: SystemMetrics.memoryPressure(freeLevel: Int(level)),
                      used: used, total: total)
    }

    static func readCPUTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks // (user, system, idle, nice)
        return CPUTicks(user: UInt64(t.0), system: UInt64(t.1),
                        idle: UInt64(t.2), nice: UInt64(t.3))
    }

    // MARK: - Battery

    static func readBattery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let charged = desc[kIOPSIsChargedKey] as? Bool ?? false
            let onAC = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutes = (charging ? desc[kIOPSTimeToFullChargeKey]
                                    : desc[kIOPSTimeToEmptyKey]) as? Int
            return Battery(
                percent: current * 100 / max,
                status: SystemMetrics.batteryStatus(isCharging: charging, isCharged: charged,
                                                    onACPower: onAC, minutesRemaining: minutes),
                isCharging: charging, onACPower: onAC)
        }
        return nil
    }

    // MARK: - Network

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let link: Link
            if path.status != .satisfied { link = .offline }
            else if path.usesInterfaceType(.wifi) { link = .wifi }
            else if path.usesInterfaceType(.wiredEthernet) { link = .ethernet }
            else { link = .other }
            Task { @MainActor in
                self?.network.link = link
                self?.refreshNetworkName()
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    private func sampleNetwork() {
        let now = Date()
        let counters = Self.readInterfaceCounters()
        if let last = lastCountersAt {
            let interval = now.timeIntervalSince(last)
            var rx: UInt64 = 0
            var tx: UInt64 = 0
            for (name, value) in counters {
                guard let previous = lastCounters[name] else { continue }
                rx += SystemMetrics.counterDelta(previous: previous.rx, current: value.rx)
                tx += SystemMetrics.counterDelta(previous: previous.tx, current: value.tx)
            }
            network.downBytesPerSecond = SystemMetrics.rate(bytes: rx, interval: interval)
            network.upBytesPerSecond = SystemMetrics.rate(bytes: tx, interval: interval)
        }
        lastCounters = counters
        lastCountersAt = now
        refreshNetworkName()
    }

    /// Byte counters of the physical `en*` interfaces (Wi-Fi/Ethernet). VPN
    /// tunnels are skipped so their traffic isn't counted twice.
    static func readInterfaceCounters() -> [String: (rx: UInt64, tx: UInt64)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var result: [String: (rx: UInt64, tx: UInt64)] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.ifa_data else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            result[name] = (UInt64(stats.ifi_ibytes), UInt64(stats.ifi_obytes))
        }
        return result
    }

    private func refreshNetworkName() {
        network.name = network.link == .wifi ? CWWiFiClient.shared().interface()?.ssid() : nil
    }

    // MARK: - Location (only needed to read the Wi-Fi name)

    /// macOS hides the Wi-Fi name from apps without Location access.
    func requestNetworkNameAccess() {
        if locationManager.authorizationStatus == .denied {
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
        } else {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    private func updateLocationAccess() {
        let status = locationManager.authorizationStatus
        canShowNetworkName = status == .authorizedAlways || status == .authorized
        refreshNetworkName()
    }

    // MARK: - External drives

    private func observeVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil,
                                                      queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDrives() }
            })
        }
    }

    func refreshDrives() {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsEjectableKey,
            .volumeIsRemovableKey, .volumeIsRootFileSystemKey,
            .volumeAvailableCapacityKey, .volumeTotalCapacityKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        drives = urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsRootFileSystem != true, !url.path.hasPrefix("/System/Volumes"),
                  v.volumeIsInternal == false || v.volumeIsEjectable == true
                    || v.volumeIsRemovable == true else { return nil }
            return Drive(url: url, name: v.volumeLocalizedName ?? url.lastPathComponent,
                         available: Int64(v.volumeAvailableCapacity ?? 0),
                         total: Int64(v.volumeTotalCapacity ?? 0))
        }
    }

    func eject(_ drive: Drive) {
        let url = drive.url
        Task.detached {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                await MainActor.run {
                    self.driveError = "Couldn't eject \(drive.name): \(error.localizedDescription)"
                }
            }
            await MainActor.run { self.refreshDrives() }
        }
    }
}

extension SystemMonitor: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.updateLocationAccess() }
    }
}

// MARK: - Memory: heavy apps & purge

/// A running app and how much memory its main process uses.
struct AppMemoryUsage: Identifiable {
    let app: NSRunningApplication
    let bytes: Int64
    var id: pid_t { app.processIdentifier }
    var name: String { app.localizedName ?? app.bundleIdentifier ?? "App \(id)" }
}

enum MemoryOptimizer {

    /// Regular (Dock) apps sorted by physical memory footprint, largest first.
    /// Helper processes (e.g. browser renderers) aren't included.
    static func heaviestApps(limit: Int = 10) -> [AppMemoryUsage] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap { app in footprint(of: app.processIdentifier).map {
                AppMemoryUsage(app: app, bytes: $0)
            } }
            .sorted { $0.bytes > $1.bytes }
            .prefix(limit)
            .map { $0 }
    }

    private static func footprint(of pid: pid_t) -> Int64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? Int64(info.ri_phys_footprint) : nil
    }

    /// Runs `/usr/sbin/purge` (flushes inactive/disk-cache memory). macOS
    /// shows its own administrator password prompt. Blocking — call off main.
    static func purgeInactiveMemory() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"]
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        guard process.terminationStatus != 0 else { return nil }
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
        return message.contains("-128") ? "Cancelled." : message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Speed test

/// Runs Apple's built-in `networkQuality` tool (contacts Apple's test servers).
@MainActor
final class SpeedTest: ObservableObject {
    enum State: Equatable {
        case idle, running
        case finished(down: Double, up: Double, responsiveness: Int?)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    func run() {
        guard state != .running else { return }
        state = .running
        Task.detached {
            let outcome = Self.measure()
            await MainActor.run { self.state = outcome }
        }
    }

    private nonisolated static func measure() -> State {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        process.arguments = ["-c", "-M", "25"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let down = (json["dl_throughput"] as? NSNumber)?.doubleValue,
              let up = (json["ul_throughput"] as? NSNumber)?.doubleValue else {
            return .failed("Speed test didn't return a result. Check your connection.")
        }
        let rpm = (json["responsiveness"] as? NSNumber)?.intValue
        return .finished(down: down, up: up, responsiveness: rpm)
    }
}
