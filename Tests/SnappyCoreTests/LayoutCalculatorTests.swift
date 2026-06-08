import XCTest
import CoreGraphics
@testable import SnappyCore

/// All frames are expressed in a top-left origin coordinate space (x → right,
/// y → down), matching the Accessibility API. `LayoutCalculator` is pure.
final class LayoutCalculatorTests: XCTestCase {

    // A 1440×900 screen with origin at (0,0).
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: Halves

    func testLeftHalf() {
        XCTAssertEqual(LayoutCalculator.frame(for: .leftHalf, in: screen),
                       CGRect(x: 0, y: 0, width: 720, height: 900))
    }

    func testRightHalf() {
        XCTAssertEqual(LayoutCalculator.frame(for: .rightHalf, in: screen),
                       CGRect(x: 720, y: 0, width: 720, height: 900))
    }

    func testTopHalf() {
        XCTAssertEqual(LayoutCalculator.frame(for: .topHalf, in: screen),
                       CGRect(x: 0, y: 0, width: 1440, height: 450))
    }

    func testBottomHalf() {
        XCTAssertEqual(LayoutCalculator.frame(for: .bottomHalf, in: screen),
                       CGRect(x: 0, y: 450, width: 1440, height: 450))
    }

    // MARK: Maximize — fills the whole usable screen rect

    func testMaximize() {
        XCTAssertEqual(LayoutCalculator.frame(for: .maximize, in: screen),
                       CGRect(x: 0, y: 0, width: 1440, height: 900))
    }

    func testMaximizeRespectsOrigin() {
        let offset = CGRect(x: 100, y: 50, width: 1440, height: 900)
        XCTAssertEqual(LayoutCalculator.frame(for: .maximize, in: offset), offset)
    }

    // MARK: Thirds (1440 / 3 = 480 exactly)

    func testFirstThird() {
        XCTAssertEqual(LayoutCalculator.frame(for: .firstThird, in: screen),
                       CGRect(x: 0, y: 0, width: 480, height: 900))
    }

    func testCenterThird() {
        XCTAssertEqual(LayoutCalculator.frame(for: .centerThird, in: screen),
                       CGRect(x: 480, y: 0, width: 480, height: 900))
    }

    func testLastThird() {
        XCTAssertEqual(LayoutCalculator.frame(for: .lastThird, in: screen),
                       CGRect(x: 960, y: 0, width: 480, height: 900))
    }

    func testFirstTwoThirds() {
        XCTAssertEqual(LayoutCalculator.frame(for: .firstTwoThirds, in: screen),
                       CGRect(x: 0, y: 0, width: 960, height: 900))
    }

    func testLastTwoThirds() {
        XCTAssertEqual(LayoutCalculator.frame(for: .lastTwoThirds, in: screen),
                       CGRect(x: 480, y: 0, width: 960, height: 900))
    }

    // MARK: Non-zero origin (e.g. external display offset)

    func testLeftHalfRespectsOrigin() {
        let offset = CGRect(x: 100, y: 50, width: 1440, height: 900)
        XCTAssertEqual(LayoutCalculator.frame(for: .leftHalf, in: offset),
                       CGRect(x: 100, y: 50, width: 720, height: 900))
    }

    // MARK: Odd width — thirds must tile exactly with no gaps or overlaps

    func testThirdsTileExactlyForOddWidth() {
        let odd = CGRect(x: 0, y: 0, width: 1001, height: 600)
        let first = LayoutCalculator.frame(for: .firstThird, in: odd)
        let center = LayoutCalculator.frame(for: .centerThird, in: odd)
        let last = LayoutCalculator.frame(for: .lastThird, in: odd)

        // No gap / overlap between adjacent thirds.
        XCTAssertEqual(first.maxX, center.minX)
        XCTAssertEqual(center.maxX, last.minX)
        // They span the full width.
        XCTAssertEqual(first.minX, odd.minX)
        XCTAssertEqual(last.maxX, odd.maxX)
        // Each is roughly a third.
        XCTAssertEqual(first.width, 334)   // round(1001/3)
        XCTAssertEqual(center.width, 333)
        XCTAssertEqual(last.width, 334)
    }
}
