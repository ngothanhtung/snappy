import XCTest
import CoreGraphics
@testable import MagnetCore

/// AppKit global coords: origin bottom-left of primary screen, y grows up.
/// Accessibility coords: origin top-left of primary screen, y grows down.
/// The conversion is its own inverse.
final class GeometryTests: XCTestCase {

    private let primaryHeight: CGFloat = 900

    func testFullPrimaryScreenIsUnchangedExceptOrientation() {
        let appKit = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(Geometry.flipY(appKit, primaryHeight: primaryHeight),
                       CGRect(x: 0, y: 0, width: 1440, height: 900))
    }

    func testBottomLeftQuarterBecomesBottomInTopLeftSpace() {
        // AppKit bottom-left quarter (y measured from bottom).
        let appKit = CGRect(x: 0, y: 0, width: 720, height: 450)
        // In AX top-left space this sits at the bottom: y = 900 - 450.
        XCTAssertEqual(Geometry.flipY(appKit, primaryHeight: primaryHeight),
                       CGRect(x: 0, y: 450, width: 720, height: 450))
    }

    func testTopRightQuarter() {
        let appKit = CGRect(x: 720, y: 450, width: 720, height: 450)
        XCTAssertEqual(Geometry.flipY(appKit, primaryHeight: primaryHeight),
                       CGRect(x: 720, y: 0, width: 720, height: 450))
    }

    func testConversionIsItsOwnInverse() {
        let original = CGRect(x: 137, y: 64, width: 500, height: 333)
        let once = Geometry.flipY(original, primaryHeight: primaryHeight)
        let twice = Geometry.flipY(once, primaryHeight: primaryHeight)
        XCTAssertEqual(twice, original)
    }

    func testSecondaryDisplayAbovePrimary() {
        // A display stacked above primary: AppKit y >= primaryHeight.
        let appKit = CGRect(x: 0, y: 900, width: 1000, height: 600)
        // AX y = 900 - (900 + 600) = -600 (above the primary's top edge).
        XCTAssertEqual(Geometry.flipY(appKit, primaryHeight: primaryHeight),
                       CGRect(x: 0, y: -600, width: 1000, height: 600))
    }
}
