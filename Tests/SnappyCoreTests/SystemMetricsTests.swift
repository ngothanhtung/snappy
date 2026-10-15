import XCTest
@testable import SnappyCore

final class SystemMetricsTests: XCTestCase {

    // MARK: CPU

    func testCPULoadFromTickDelta() {
        let a = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let b = CPUTicks(user: 120, system: 60, idle: 910, nice: 10)
        let load = SystemMetrics.cpuLoad(from: a, to: b)!
        // delta: user 20 + nice 10 = 30, system 10, idle 60 → total 100
        XCTAssertEqual(load.user, 0.30, accuracy: 1e-9)
        XCTAssertEqual(load.system, 0.10, accuracy: 1e-9)
        XCTAssertEqual(load.total, 0.40, accuracy: 1e-9)
    }

    func testCPULoadNilWithoutProgressOrAfterReset() {
        let a = CPUTicks(user: 10, system: 10, idle: 10, nice: 0)
        XCTAssertNil(SystemMetrics.cpuLoad(from: a, to: a))
        let reset = CPUTicks(user: 1, system: 1, idle: 1, nice: 0)
        XCTAssertNil(SystemMetrics.cpuLoad(from: a, to: reset))
    }

    // MARK: Memory

    func testMemoryPressureIsInverseOfFreeLevel() {
        XCTAssertEqual(SystemMetrics.memoryPressure(freeLevel: 61), 0.39, accuracy: 1e-9)
        XCTAssertEqual(SystemMetrics.memoryPressure(freeLevel: 150), 0)
        XCTAssertEqual(SystemMetrics.memoryPressure(freeLevel: -5), 1)
    }

    // MARK: Network

    func testCounterDeltaHandles32BitWrap() {
        XCTAssertEqual(SystemMetrics.counterDelta(previous: 100, current: 600), 500)
        let max32 = UInt64(UInt32.max)
        XCTAssertEqual(SystemMetrics.counterDelta(previous: max32 - 9, current: 5), 15)
    }

    func testCounterDeltaTreatsOutOfRangeDropAsReset() {
        XCTAssertEqual(SystemMetrics.counterDelta(previous: 1 << 40, current: 5), 0)
    }

    func testRateFormatting() {
        XCTAssertEqual(SystemMetrics.formatRate(bytesPerSecond: 513), "513 bytes/sec")
        XCTAssertEqual(SystemMetrics.formatRate(bytesPerSecond: 3_000), "3.0 KB/sec")
        XCTAssertEqual(SystemMetrics.formatRate(bytesPerSecond: 45_600), "46 KB/sec")
        XCTAssertEqual(SystemMetrics.formatRate(bytesPerSecond: 1_260_000), "1.3 MB/sec")
        XCTAssertEqual(SystemMetrics.rate(bytes: 1000, interval: 2), 500)
        XCTAssertEqual(SystemMetrics.rate(bytes: 1000, interval: 0), 0)
    }

    func testBitRateFormatting() {
        XCTAssertEqual(SystemMetrics.formatBitRate(bitsPerSecond: 245_400_000), "245 Mbps")
        XCTAssertEqual(SystemMetrics.formatBitRate(bitsPerSecond: 8_200_000), "8.2 Mbps")
        XCTAssertEqual(SystemMetrics.formatBitRate(bitsPerSecond: 1_500_000_000), "1.50 Gbps")
    }

    // MARK: Disk

    func testDiskLevels() {
        let gb: Int64 = 1_000_000_000
        XCTAssertEqual(SystemMetrics.diskLevel(available: 300 * gb, total: 1000 * gb), .ok)
        XCTAssertEqual(SystemMetrics.diskLevel(available: 19 * gb, total: 150 * gb), .low)
        XCTAssertEqual(SystemMetrics.diskLevel(available: 4 * gb, total: 500 * gb), .critical)
        XCTAssertEqual(SystemMetrics.diskLevel(available: 0, total: 0), .ok)
    }

    // MARK: Battery

    func testBatteryStatus() {
        XCTAssertEqual(SystemMetrics.batteryStatus(isCharging: false, isCharged: true,
                                                   onACPower: true, minutesRemaining: nil),
                       "Fully charged")
        XCTAssertEqual(SystemMetrics.batteryStatus(isCharging: true, isCharged: false,
                                                   onACPower: true, minutesRemaining: 65),
                       "Charging, 1:05 until full")
        XCTAssertEqual(SystemMetrics.batteryStatus(isCharging: false, isCharged: false,
                                                   onACPower: false, minutesRemaining: 200),
                       "3:20 remaining")
        XCTAssertEqual(SystemMetrics.batteryStatus(isCharging: false, isCharged: false,
                                                   onACPower: false, minutesRemaining: -1),
                       "On battery")
        XCTAssertEqual(SystemMetrics.batteryStatus(isCharging: false, isCharged: false,
                                                   onACPower: true, minutesRemaining: nil),
                       "Not charging")
    }
}
