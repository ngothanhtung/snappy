import XCTest
@testable import SnappyCore

final class ProcessUsageTests: XCTestCase {
    func testOwningAppKeepsOnlyApps() {
        let helperApp = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/"
            + "Helpers/Google Chrome Helper (Renderer).app"
        let apps = [ProcessUsage.App(name: "Google Chrome Helper (Renderer)", bundlePath: helperApp),
                    ProcessUsage.App(name: "Google Chrome", bundlePath: "/Applications/Google Chrome.app"),
                    ProcessUsage.App(name: "Finder", bundlePath: "/System/Library/CoreServices/Finder.app")]
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/"
            + "Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        XCTAssertEqual(ProcessUsage.owningApp(executablePath: helper, apps: apps), "Google Chrome")
        XCTAssertEqual(ProcessUsage.owningApp(executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
                                              apps: apps), "Finder")
        // Daemons, kernel tasks, tools and look-alike paths are not apps.
        XCTAssertNil(ProcessUsage.owningApp(executablePath: "/usr/libexec/duetexpertd", apps: apps))
        XCTAssertNil(ProcessUsage.owningApp(executablePath: "", apps: apps))
        XCTAssertNil(ProcessUsage.owningApp(executablePath: "/Applications/Google Chrome.app.bak/x", apps: apps))
    }

    func testTopCPUGroupsAndRanks() {
        let previous: [Int32: Double] = [1: 10, 2: 5, 3: 0, 4: 100]
        let current = [
            ProcessUsage.Sample(pid: 1, app: "Chrome", cpuTime: 11, memory: 0),    // +1 s
            ProcessUsage.Sample(pid: 2, app: "Chrome", cpuTime: 5.5, memory: 0),   // +0.5 s
            ProcessUsage.Sample(pid: 3, app: "Xcode", cpuTime: 3, memory: 0),      // +3 s
            ProcessUsage.Sample(pid: 4, app: "Idle", cpuTime: 100, memory: 0),     // 0
            ProcessUsage.Sample(pid: 5, app: "New", cpuTime: 50, memory: 0),       // not in previous
        ]
        let top = ProcessUsage.topCPU(previous: previous, current: current, elapsed: 2, limit: 5)
        XCTAssertEqual(top, [.init(app: "Xcode", value: 150), .init(app: "Chrome", value: 75)])
        // On a 10-core machine the same load is a share of the whole CPU.
        let machine = ProcessUsage.topCPU(previous: previous, current: current, elapsed: 2, cores: 10, limit: 5)
        XCTAssertEqual(machine, [.init(app: "Xcode", value: 15), .init(app: "Chrome", value: 7.5)])
    }

    func testTopMemory() {
        let current = [
            ProcessUsage.Sample(pid: 1, app: "A", cpuTime: 0, memory: 100),
            ProcessUsage.Sample(pid: 2, app: "B", cpuTime: 0, memory: 300),
            ProcessUsage.Sample(pid: 3, app: "A", cpuTime: 0, memory: 250),
            ProcessUsage.Sample(pid: 4, app: "C", cpuTime: 0, memory: 10),
        ]
        XCTAssertEqual(ProcessUsage.topMemory(current, limit: 2), [.init(app: "A", value: 350), .init(app: "B", value: 300)])
    }

    func testTexts() {
        XCTAssertEqual(ProcessUsage.cpuText(12.34), "12.3%")
        XCTAssertEqual(ProcessUsage.cpuText(100), "100%")
        XCTAssertEqual(ProcessUsage.memoryText(850 * 1_048_576), "850 MB")
        XCTAssertEqual(ProcessUsage.memoryText(1.25 * 1_073_741_824), "1.2 GB")
        XCTAssertEqual(ThermalLevel(rawValue: 2)?.text, "Serious")
    }
}
