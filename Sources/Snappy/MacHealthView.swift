import AppKit
import SwiftUI
import SnappyCore

/// "Mac Health" window with live disk, memory, battery, CPU, network and
/// external-drive status. A standard macOS window (full title bar with the
/// close/minimize buttons); sampling runs only while it is open.
@MainActor
final class MacHealthController: NSObject, NSWindowDelegate {
    static let shared = MacHealthController()
    private var window: NSWindow?
    private let monitor = SystemMonitor()

    func show() {
        if window == nil {
            let host = NSHostingView(rootView: MacHealthView(monitor: monitor))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: host.fittingSize),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = "Mac Health"
            window.tabbingMode = .disallowed
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.delegate = self
            // Reopen where the user last left it; center the first time.
            // Autosave name predates the rename; kept so the saved position survives.
            if !window.setFrameUsingName("QuickPanel") { window.center() }
            window.setFrameAutosaveName("QuickPanel")
            self.window = window
        }
        monitor.start()
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    func toggle() {
        if let window, window.isVisible, !window.isMiniaturized, window.isKeyWindow {
            window.close()
        } else {
            show()
        }
    }

    func windowWillClose(_ notification: Notification) {
        monitor.stop()
    }
}

struct MacHealthView: View {
    @ObservedObject var monitor: SystemMonitor
    @StateObject private var speedTest = SpeedTest()
    @State private var showingMemory = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            diskCard
            memoryCard
            powerCard
            cpuCard
            networkCard
            drivesCard
        }
        .padding(14)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showingMemory) {
            MemoryOptimizeView()
        }
        .alert("Eject failed", isPresented: Binding(get: { monitor.driveError != nil },
                                                   set: { if !$0 { monitor.driveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(monitor.driveError ?? "")
        }
    }

    // MARK: - Cards

    private var diskCard: some View {
        StatCard(symbol: "internaldrive", title: monitor.disk?.name ?? "Startup Disk") {
            if let disk = monitor.disk {
                Text("Available: \(format(disk.available)) of \(format(disk.total))")
                    .foregroundStyle(color(for: disk.level))
                UsageBar(fraction: 1 - Double(disk.available) / Double(max(disk.total, 1)),
                         tint: color(for: disk.level) == .secondary ? .accentColor
                                                                   : color(for: disk.level))
            } else {
                Text("Unavailable").foregroundStyle(.secondary)
            }
        } action: {
            Button("Free Up\u{2026}") { JunkCleanerController.shared.show() }
        }
    }

    private var memoryCard: some View {
        StatCard(symbol: "memorychip", title: "Memory") {
            if let memory = monitor.memory {
                Text("Pressure: \(percent(memory.pressure))")
                    .foregroundStyle(memory.pressure >= 0.8 ? .red
                                     : memory.pressure >= 0.6 ? .orange : .secondary)
                Text("Used \(format(memory.used, style: .memory)) of \(format(memory.total, style: .memory))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                UsageBar(fraction: memory.pressure,
                         tint: memory.pressure >= 0.8 ? .red
                               : memory.pressure >= 0.6 ? .orange : .accentColor)
            } else {
                Text("Unavailable").foregroundStyle(.secondary)
            }
        } action: {
            Button("Optimize\u{2026}") { showingMemory = true }
        }
    }

    @ViewBuilder
    private var powerCard: some View {
        if let battery = monitor.battery {
            StatCard(symbol: batterySymbol(battery), title: "Battery",
                     trailing: "\(battery.percent)%") {
                Text(battery.status).foregroundStyle(.secondary)
                UsageBar(fraction: Double(battery.percent) / 100,
                         tint: battery.percent <= 10 ? .red
                               : battery.percent <= 20 ? .orange : .green)
            }
        } else {
            StatCard(symbol: "powerplug", title: "Power") {
                Text(monitor.hasBattery ? "Reading\u{2026}" : "Connected to power, no battery")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cpuCard: some View {
        StatCard(symbol: "cpu", title: "CPU") {
            if let cpu = monitor.cpu {
                Text("Load: \(percent(cpu.total))").foregroundStyle(.secondary)
                Text("User \(percent(cpu.user)) · System \(percent(cpu.system))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                UsageBar(fraction: cpu.total,
                         tint: cpu.total >= 0.85 ? .red : cpu.total >= 0.6 ? .orange : .accentColor)
            } else {
                Text("Measuring\u{2026}").foregroundStyle(.secondary)
            }
        }
    }

    private var networkCard: some View {
        StatCard(symbol: networkSymbol, title: networkTitle) {
            Label(SystemMetrics.formatRate(bytesPerSecond: monitor.network.upBytesPerSecond),
                  systemImage: "arrow.up")
                .monospacedDigit()
            Label(SystemMetrics.formatRate(bytesPerSecond: monitor.network.downBytesPerSecond),
                  systemImage: "arrow.down")
                .monospacedDigit()
            speedTestResult
            if monitor.network.link == .wifi, monitor.network.name == nil,
               !monitor.canShowNetworkName {
                Button("Show network name\u{2026}") { monitor.requestNetworkNameAccess() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("macOS only reveals the Wi-Fi name to apps with Location access.")
            }
        } action: {
            Button(speedTest.state == .running ? "Testing\u{2026}" : "Test Speed") {
                speedTest.run()
            }
            .disabled(speedTest.state == .running || monitor.network.link == .offline)
        }
    }

    @ViewBuilder
    private var speedTestResult: some View {
        switch speedTest.state {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Running speed test\u{2026}")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .finished(let down, let up, let rpm):
            VStack(alignment: .leading, spacing: 2) {
                Text("Download \(SystemMetrics.formatBitRate(bitsPerSecond: down)) · "
                     + "Upload \(SystemMetrics.formatBitRate(bitsPerSecond: up))")
                if let rpm { Text("Responsiveness \(rpm) RPM") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    private var drivesCard: some View {
        StatCard(symbol: "externaldrive", title: "External Drives") {
            if monitor.drives.isEmpty {
                Text("No devices connected").foregroundStyle(.secondary)
            } else {
                ForEach(monitor.drives) { drive in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(drive.name).lineLimit(1)
                            Text("\(format(drive.available)) free of \(format(drive.total))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            NSWorkspace.shared.open(drive.url)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Open in Finder")
                        Button {
                            monitor.eject(drive)
                        } label: {
                            Image(systemName: "eject")
                        }
                        .buttonStyle(.borderless)
                        .help("Eject \(drive.name)")
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var networkSymbol: String {
        switch monitor.network.link {
        case .wifi:     return "wifi"
        case .ethernet: return "cable.connector.horizontal"
        case .other:    return "network"
        case .offline:  return "wifi.slash"
        }
    }

    private var networkTitle: String {
        switch monitor.network.link {
        case .wifi:     return monitor.network.name ?? "Wi-Fi"
        case .ethernet: return "Ethernet"
        case .other:    return "Network"
        case .offline:  return "Not connected"
        }
    }

    private func batterySymbol(_ battery: SystemMonitor.Battery) -> String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private func color(for level: DiskLevel) -> Color {
        switch level {
        case .ok:       return .secondary
        case .low:      return .orange
        case .critical: return .red
        }
    }

    private func format(_ bytes: Int64,
                        style: ByteCountFormatter.CountStyle = .file) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: style)
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}

/// One tile of Mac Health: icon + title, body lines, optional action.
private struct StatCard<Content: View, Action: View>: View {
    let symbol: String
    let title: String
    var trailing: String?
    @ViewBuilder let content: Content
    @ViewBuilder let action: Action

    init(symbol: String, title: String, trailing: String? = nil,
         @ViewBuilder content: () -> Content,
         @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.symbol = symbol
        self.title = title
        self.trailing = trailing
        self.content = content()
        self.action = action()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let trailing {
                    Text(trailing).font(.headline).monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                content
            }
            .font(.callout)
            .padding(.leading, 32)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                action
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

/// Thin horizontal usage bar.
private struct UsageBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

/// "Optimize" sheet: the apps using the most memory, with Quit buttons, plus
/// an optional admin-only flush of inactive memory.
private struct MemoryOptimizeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [AppMemoryUsage] = []
    @State private var purging = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Free Up Memory").font(.headline)
            Text("Quitting apps you aren't using is the most effective way to relieve "
                 + "memory pressure. Apps are asked to quit normally, so they can offer "
                 + "to save your work.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(apps) { usage in
                HStack {
                    if let icon = usage.app.icon {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    }
                    Text(usage.name)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .memory))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Quit") {
                        usage.app.terminate()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { reload() }
                    }
                }
            }
            .frame(minHeight: 240)
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(purging ? "Freeing\u{2026}" : "Free Inactive Memory\u{2026}") { purge() }
                    .disabled(purging)
                    .help("Runs macOS's purge tool. Requires an administrator password.")
                Spacer()
                Button("Refresh") { reload() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear(perform: reload)
    }

    private func reload() {
        apps = MemoryOptimizer.heaviestApps()
    }

    private func purge() {
        purging = true
        message = nil
        Task.detached {
            let error = MemoryOptimizer.purgeInactiveMemory()
            await MainActor.run {
                purging = false
                message = error.map { "Couldn't free memory: \($0)" } ?? "Inactive memory freed."
                reload()
            }
        }
    }
}
