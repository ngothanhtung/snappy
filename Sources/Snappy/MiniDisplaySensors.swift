import SnappyCore
import Darwin
import Foundation
import IOKit

struct MiniDisplaySnapshot {
    var cpuTotal: Double = 0          // 0...1
    var cpuCores: [Double] = []       // 0...1 per core
    var gpu: Double? = nil            // 0...1
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = 0
    var netRx: Double = 0             // byte/s
    var netTx: Double = 0
    var cpuTemp: Double? = nil        // °C
    var gpuTemp: Double? = nil
    var socTemp: Double? = nil
    var diskTotal: UInt64 = 0         // startup volume
    var diskFree: UInt64 = 0
    var diskRead: Double = 0          // bytes/s, all block devices
    var diskWrite: Double = 0
    var diskTemp: Double? = nil       // NAND
    var thermal: ThermalLevel = .nominal
    var audio: MiniDisplayAudio.Output? = nil
    var topCPU: [ProcessUsage.Entry] = []      // only filled while the TOP APPS card is on
    var topMemory: [ProcessUsage.Entry] = []
}

final class MiniDisplaySensors {
    private var prevTicks: [(busy: UInt32, total: UInt32)] = []
    private var prevNet: (rx: UInt64, tx: UInt64, t: Date)? = nil
    private let thermal = MiniDisplayThermal()
    private let processes = MiniDisplayProcesses()
    private var lastProcesses: (cpu: [ProcessUsage.Entry], memory: [ProcessUsage.Entry], t: Date)?
    /// Scan processes only while the TOP APPS card is shown (every 2 s).
    var wantsTopApps = false

    func logThermalSensors() {
        let all = thermal.readAll()
        MiniDisplayLog.log("thermal sensors found: \(all.count)")
        let names = Set(all.keys.map { $0.components(separatedBy: " #").first ?? $0 }).sorted()
        MiniDisplayLog.log("thermal sensor names: \(names.joined(separator: ", "))")
    }

    func sample() -> MiniDisplaySnapshot {
        var s = MiniDisplaySnapshot()
        (s.cpuTotal, s.cpuCores) = cpu()
        s.gpu = gpuUtilization()
        (s.memUsed, s.memTotal) = memory()
        (s.netRx, s.netTx) = network()
        let temps = thermal.readAll()
        // M1/M1 Max only expose PMU sensors: tdie* = CPU dies, TPxg = GPU area.
        // M2+ also expose "pACC/eACC MTR" and "GPU MTR"; prefer those when present.
        s.cpuTemp = Self.avg(temps, where: { $0.contains("ACC MTR") })
            ?? Self.avg(temps, where: { $0.contains("tdie") })
        s.gpuTemp = Self.avg(temps, where: { $0.contains("GPU MTR") })
            ?? Self.avg(temps, where: { Self.isPmuGpu($0) })
        s.socTemp = temps.filter { $0.key.hasPrefix("PMU") && !$0.key.contains("tcal") }.map { $0.value }.max()
        s.diskTemp = Self.avg(temps, where: { $0.hasPrefix("NAND") })
        (s.diskTotal, s.diskFree) = diskCapacity()
        (s.diskRead, s.diskWrite) = diskIO()
        s.thermal = ThermalLevel(rawValue: ProcessInfo.processInfo.thermalState.rawValue) ?? .nominal
        s.audio = MiniDisplayAudio.current()
        if wantsTopApps {
            if lastProcesses == nil || Date().timeIntervalSince(lastProcesses!.t) >= 2 {
                let top = processes.sample(limit: 3)
                // The first scan has no CPU interval yet; keep the old CPU list until the next.
                lastProcesses = (top.cpu.isEmpty ? (lastProcesses?.cpu ?? []) : top.cpu, top.memory, Date())
            }
            s.topCPU = lastProcesses?.cpu ?? []
            s.topMemory = lastProcesses?.memory ?? []
        } else {
            lastProcesses = nil
        }
        return s
    }

    // MARK: Disk

    private var prevDisk: (r: UInt64, w: UInt64, t: Date)? = nil

    private func diskCapacity() -> (UInt64, UInt64) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity else { return (0, 0) }
        let free = v.volumeAvailableCapacityForImportantUsage ?? 0
        return (UInt64(total), UInt64(max(0, free)))
    }

    /// Read/write throughput from IOBlockStorageDriver byte counters.
    private func diskIO() -> (Double, Double) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS
        else { return (0, 0) }
        defer { IOObjectRelease(iter) }

        var r: UInt64 = 0, w: UInt64 = 0
        var entry = IOIteratorNext(iter)
        while entry != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let stats = dict["Statistics"] as? [String: Any] {
                r += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                w += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iter)
        }

        let now = Date()
        defer { prevDisk = (r, w, now) }
        guard let prev = prevDisk else { return (0, 0) }
        let dt = now.timeIntervalSince(prev.t)
        guard dt > 0, r >= prev.r, w >= prev.w else { return (0, 0) }
        return (Double(r - prev.r) / dt, Double(w - prev.w) / dt)
    }

    /// "PMU TP1g", "PMU TP1g #1" ...
    private static func isPmuGpu(_ name: String) -> Bool {
        guard name.hasPrefix("PMU TP") else { return false }
        let base = name.split(separator: " ").prefix(2).joined(separator: " ")
        return base.hasSuffix("g")
    }

    private static func avg(_ t: [String: Double], where pred: (String) -> Bool) -> Double? {
        let v = t.filter { pred($0.key) }.map { $0.value }
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    // MARK: CPU

    private func cpu() -> (Double, [Double]) {
        var numCPUs: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &info, &count)
        guard kr == KERN_SUCCESS, let info else { return (0, []) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
        }

        var ticks: [(busy: UInt32, total: UInt32)] = []
        for i in 0..<Int(numCPUs) {
            let base = Int(CPU_STATE_MAX) * i
            let user = UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])
            let sys = UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])
            let nice = UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            let busy = user &+ sys &+ nice
            ticks.append((busy, busy &+ idle))
        }

        var cores: [Double] = []
        var busySum: UInt32 = 0, totalSum: UInt32 = 0
        if prevTicks.count == ticks.count {
            for (now, before) in zip(ticks, prevTicks) {
                let b = now.busy &- before.busy
                let t = now.total &- before.total
                cores.append(t > 0 ? Double(b) / Double(t) : 0)
                busySum &+= b
                totalSum &+= t
            }
        } else {
            cores = Array(repeating: 0, count: ticks.count)
        }
        prevTicks = ticks
        return (totalSum > 0 ? Double(busySum) / Double(totalSum) : 0, cores)
    }

    // MARK: GPU (IOAccelerator PerformanceStatistics)

    private func gpuUtilization() -> Double? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iter) }

        var result: Double?
        var entry = IOIteratorNext(iter)
        while entry != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let perf = dict["PerformanceStatistics"] as? [String: Any],
               let u = perf["Device Utilization %"] as? NSNumber {
                result = u.doubleValue / 100
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iter)
        }
        return result
    }

    // MARK: RAM

    private func memory() -> (UInt64, UInt64) {
        var stats = vm_statistics64()
        var cnt = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &cnt)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard kr == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(getpagesize())
        // Matches Activity Monitor's "Memory Used": app + wired + compressed.
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (min(used, total), total)
    }

    // MARK: Network (sum of en* interfaces)

    private func network() -> (Double, Double) {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return (0, 0) }
        defer { freeifaddrs(ifap) }

        var rx: UInt64 = 0, tx: UInt64 = 0
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               let data = ifa.ifa_data,
               String(cString: ifa.ifa_name).hasPrefix("en") {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                rx += UInt64(d.ifi_ibytes)
                tx += UInt64(d.ifi_obytes)
            }
            p = ifa.ifa_next
        }

        let now = Date()
        defer { prevNet = (rx, tx, now) }
        guard let prev = prevNet else { return (0, 0) }
        let dt = now.timeIntervalSince(prev.t)
        guard dt > 0, rx >= prev.rx, tx >= prev.tx else { return (0, 0) }
        return (Double(rx - prev.rx) / dt, Double(tx - prev.tx) / dt)
    }
}

/// Apple Silicon temperatures via IOHIDEventSystemClient (private API, resolved with dlsym).
final class MiniDisplayThermal {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (CFTypeRef, Int32) -> Double

    private var client: CFTypeRef?
    private var copyServices: CopyServicesFn?
    private var copyProp: CopyPropFn?
    private var copyEvent: CopyEventFn?
    private var getFloat: GetFloatFn?

    private static let typeTemperature: Int64 = 15

    init() {
        let h = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let services = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let prop = sym("IOHIDServiceClientCopyProperty", CopyPropFn.self),
              let event = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self),
              let float = sym("IOHIDEventGetFloatValue", GetFloatFn.self),
              let c = create(kCFAllocatorDefault)?.takeRetainedValue()
        else {
            MiniDisplayLog.log("IOHID temperature API unavailable - temperatures disabled")
            return
        }
        // PrimaryUsagePage 0xff00 / PrimaryUsage 5 = temperature sensors
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = setMatching(c, matching)
        client = c
        copyServices = services
        copyProp = prop
        copyEvent = event
        getFloat = float
    }

    func readAll() -> [String: Double] {
        guard let client, let copyServices, let copyProp, let copyEvent, let getFloat,
              let arr = copyServices(client)?.takeRetainedValue() as? [CFTypeRef]
        else { return [:] }

        var out: [String: Double] = [:]
        var dupes: [String: Int] = [:]
        for svc in arr {
            guard let nameRef = copyProp(svc, "Product" as CFString)?.takeRetainedValue(),
                  let name = nameRef as? String,
                  let ev = copyEvent(svc, Self.typeTemperature, 0, 0)?.takeRetainedValue()
            else { continue }
            let v = getFloat(ev, Int32(Self.typeTemperature << 16))
            guard v > 0, v < 150 else { continue }
            let n = (dupes[name] ?? 0)
            dupes[name] = n + 1
            out[n == 0 ? name : "\(name) #\(n)"] = v
        }
        return out
    }
}
