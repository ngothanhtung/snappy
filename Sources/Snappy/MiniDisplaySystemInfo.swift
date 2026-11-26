import AppKit
import CoreAudio
import Darwin
import Foundation
import SnappyCore

/// Reads every process's CPU time and memory footprint with libproc and ranks
/// apps for the "TOP APPS" card. Only apps count — Dock apps and third-party
/// menu-bar apps from NSWorkspace, with the helpers inside their bundles; system
/// daemons, kernel tasks and command-line tools are left out.
final class MiniDisplayProcesses {
    private var previous: [Int32: Double] = [:]
    private var previousAt: Date?
    /// Executable path per pid (paths don't change while a process lives).
    private var paths: [Int32: String] = [:]
    private let tickSeconds: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        // rusage CPU times are in Mach absolute time units on Apple Silicon.
        return Double(tb.numer) / Double(tb.denom) / 1e9
    }()

    /// (top by CPU, top by memory); CPU is empty on the first call.
    func sample(limit: Int) -> (cpu: [ProcessUsage.Entry], memory: [ProcessUsage.Entry]) {
        let now = Date()
        let samples = readAll()
        let cpu = previousAt.map {
            ProcessUsage.topCPU(previous: previous, current: samples,
                                elapsed: now.timeIntervalSince($0),
                                cores: ProcessInfo.processInfo.activeProcessorCount, limit: limit)
        } ?? []
        previous = Dictionary(samples.map { ($0.pid, $0.cpuTime) }, uniquingKeysWith: { a, _ in a })
        previousAt = now
        let alive = Set(samples.map(\.pid))
        paths = paths.filter { alive.contains($0.key) }
        return (cpu, ProcessUsage.topMemory(samples, limit: limit))
    }

    /// Apps the user sees: everything in the Dock, plus menu-bar apps that are
    /// not Apple's own UI agents (Control Center, Spotlight, …).
    private func runningApps() -> [ProcessUsage.App] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            let visible = app.activationPolicy == .regular
                || (app.activationPolicy == .accessory && !(app.bundleIdentifier ?? "").hasPrefix("com.apple."))
            guard visible, let url = app.bundleURL else { return nil }
            // The bundle's name as in Finder/Dock ("Visual Studio Code", not the process name "Code").
            let folder = url.deletingPathExtension().lastPathComponent
            let name = folder.isEmpty ? (app.localizedName ?? "App") : folder
            return ProcessUsage.App(name: name, bundlePath: url.resolvingSymlinksInPath().path)
        }
    }

    private func readAll() -> [ProcessUsage.Sample] {
        let apps = runningApps()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        var out: [ProcessUsage.Sample] = []
        out.reserveCapacity(Int(n))
        for pid in pids.prefix(Int(max(0, n))) where pid > 0 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard ok == 0, let app = ProcessUsage.owningApp(executablePath: path(of: pid), apps: apps) else { continue }
            let cpu = Double(info.ri_user_time + info.ri_system_time) * tickSeconds
            out.append(.init(pid: pid, app: app, cpuTime: cpu, memory: info.ri_phys_footprint))
        }
        return out
    }

    private func path(of pid: pid_t) -> String {
        if let p = paths[pid] { return p }
        var buf = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        let p = len > 0 ? String(cString: buf) : ""
        paths[pid] = p
        return p
    }
}

/// Default sound output device: name, volume (0...1, nil if the device has no
/// software volume, e.g. HDMI) and mute.
enum MiniDisplayAudio {
    struct Output: Equatable {
        var name: String
        var volume: Double?
        var muted: Bool
    }

    static func current() -> Output? {
        var device = AudioObjectID(kAudioObjectUnknown)
        guard get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                  kAudioObjectPropertyScopeGlobal, &device), device != kAudioObjectUnknown else { return nil }

        var name: Unmanaged<CFString>?
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let title = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr
            ? (name?.takeRetainedValue() as String?) ?? "Output" : "Output"

        var muted: UInt32 = 0
        _ = get(device, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, &muted)
        return Output(name: title, volume: volume(of: device), muted: muted != 0)
    }

    /// Main volume if the device has one, else the average of channels 1 and 2.
    private static func volume(of device: AudioObjectID) -> Double? {
        var v: Float32 = 0
        if get(device, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, &v,
               element: kAudioObjectPropertyElementMain) {
            return Double(v)
        }
        var channels: [Double] = []
        for ch: UInt32 in [1, 2] where get(device, kAudioDevicePropertyVolumeScalar,
                                           kAudioDevicePropertyScopeOutput, &v, element: ch) {
            channels.append(Double(v))
        }
        return channels.isEmpty ? nil : channels.reduce(0, +) / Double(channels.count)
    }

    private static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope, _ value: inout T,
                               element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(object, &addr) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
    }
}
