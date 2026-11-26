import XCTest
import CoreGraphics
@testable import SnappyCore

final class DisplayModeCatalogTests: XCTestCase {

    private func mode(_ id: Int32, _ w: Int, _ h: Int, px: Int, _ hz: Double, usable: Bool = true) -> DisplayModeInfo {
        DisplayModeInfo(id: id, width: w, height: h, pixelWidth: px, pixelHeight: px * h / w,
                        refreshRate: hz, isUsableForDesktop: usable)
    }

    private lazy var modes: [DisplayModeInfo] = [
        mode(1, 1920, 1080, px: 3840, 60),
        mode(2, 1920, 1080, px: 3840, 30),
        mode(3, 1920, 1080, px: 1920, 60),
        mode(4, 2560, 1440, px: 5120, 60),
        mode(5, 3840, 2160, px: 3840, 60),
        mode(6, 3840, 2160, px: 3840, 59.94),
        mode(7, 640, 480, px: 640, 60, usable: false),
    ]

    func testResolutionsSortedAndDeduplicated() {
        let r = DisplayModeCatalog.resolutions(modes)
        XCTAssertEqual(r, [
            DisplayResolution(width: 3840, height: 2160, isHiDPI: false),
            DisplayResolution(width: 2560, height: 1440, isHiDPI: true),
            DisplayResolution(width: 1920, height: 1080, isHiDPI: true),
            DisplayResolution(width: 1920, height: 1080, isHiDPI: false),
        ])
    }

    func testRefreshRatesRounded() {
        let r = DisplayResolution(width: 3840, height: 2160, isHiDPI: false)
        XCTAssertEqual(DisplayModeCatalog.refreshRates(for: r, in: modes), [60])
        let hd = DisplayResolution(width: 1920, height: 1080, isHiDPI: true)
        XCTAssertEqual(DisplayModeCatalog.refreshRates(for: hd, in: modes), [60, 30])
    }

    func testPickKeepsCurrentRate() {
        let current = modes[1] // 1920 HiDPI @ 30
        let r = DisplayResolution(width: 1920, height: 1080, isHiDPI: true)
        XCTAssertEqual(DisplayModeCatalog.mode(for: r, keepingRateOf: current, in: modes)?.id, 2)
    }

    func testPickFallsBackToHighestRate() {
        let current = modes[1] // @30, not offered at 2560
        let r = DisplayResolution(width: 2560, height: 1440, isHiDPI: true)
        XCTAssertEqual(DisplayModeCatalog.mode(for: r, keepingRateOf: current, in: modes)?.id, 4)
        XCTAssertNil(DisplayModeCatalog.mode(for: DisplayResolution(width: 640, height: 480, isHiDPI: false),
                                             keepingRateOf: nil, in: modes))
    }

    func testModeForRate() {
        XCTAssertEqual(DisplayModeCatalog.mode(forRate: 30, at: modes[0], in: modes)?.id, 2)
        XCTAssertNil(DisplayModeCatalog.mode(forRate: 120, at: modes[0], in: modes))
    }

    func testOriginsMakingMain() {
        let bounds: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            2: CGRect(x: 2560, y: 360, width: 1920, height: 1080),
            3: CGRect(x: -2560, y: 0, width: 2560, height: 1440),
        ]
        let o = DisplayArrangement.originsMakingMain(2, bounds: bounds)
        XCTAssertEqual(o?[2], .zero)
        XCTAssertEqual(o?[1], CGPoint(x: -2560, y: -360))
        XCTAssertEqual(o?[3], CGPoint(x: -5120, y: -360))
        XCTAssertNil(DisplayArrangement.originsMakingMain(9, bounds: bounds))
    }
}

final class DisplayLevelTests: XCTestCase {

    func testStepsOnSixteenthGrid() {
        XCTAssertEqual(DisplayLevel.step(0.5, up: true), 9.0 / 16)
        XCTAssertEqual(DisplayLevel.step(0.5, up: false), 7.0 / 16)
    }

    func testOffGridSnapsToNeighbour() {
        // 0.52 sits between 8/16 and 9/16.
        XCTAssertEqual(DisplayLevel.step(0.52, up: true), 9.0 / 16)
        XCTAssertEqual(DisplayLevel.step(0.52, up: false), 8.0 / 16)
    }

    func testClampsAtEnds() {
        XCTAssertEqual(DisplayLevel.step(1, up: true), 1)
        XCTAssertEqual(DisplayLevel.step(0, up: false), 0)
        XCTAssertEqual(DisplayLevel.step(1.0 / 16, up: false), 0)
    }

    func testSegmentsAndDDCValue() {
        XCTAssertEqual(DisplayLevel.segments(0.75), 12)
        XCTAssertEqual(DisplayLevel.ddcValue(0.75, maximum: 100), 75)
        XCTAssertEqual(DisplayLevel.ddcValue(2, maximum: 100), 100)
        XCTAssertEqual(DisplayLevel.percent(0.333), "33%")
    }

    func testSoftwareDimmingNeverBlack() {
        XCTAssertEqual(SoftwareDimming.factor(for: 0), SoftwareDimming.floor)
        XCTAssertEqual(SoftwareDimming.factor(for: 1), 1)
        XCTAssertEqual(SoftwareDimming.scaled([0, 0.5, 1], level: 1), [0, 0.5, 1])
        XCTAssertEqual(SoftwareDimming.scaled([1], level: 0)[0], Float(SoftwareDimming.floor), accuracy: 1e-6)
    }
}
