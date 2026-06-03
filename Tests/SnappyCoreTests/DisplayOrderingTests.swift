import XCTest
import CoreGraphics
@testable import SnappyCore

/// `DisplayOrdering` picks the next/previous screen, ordered left-to-right
/// (then top-to-bottom), wrapping around. Pure — operates on frames.
final class DisplayOrderingTests: XCTestCase {

    private let left  = CGRect(x: 0,    y: 0, width: 1440, height: 900)
    private let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

    func testNextWrapsAround() {
        let screens = [left, right]
        XCTAssertEqual(DisplayOrdering.target(from: left, in: screens, direction: .next), right)
        XCTAssertEqual(DisplayOrdering.target(from: right, in: screens, direction: .next), left)
    }

    func testPreviousWrapsAround() {
        let screens = [left, right]
        XCTAssertEqual(DisplayOrdering.target(from: right, in: screens, direction: .previous), left)
        XCTAssertEqual(DisplayOrdering.target(from: left, in: screens, direction: .previous), right)
    }

    func testUnsortedInputIsOrderedByXPosition() {
        // Provided out of order; ordering is by minX.
        let screens = [right, left]
        XCTAssertEqual(DisplayOrdering.target(from: left, in: screens, direction: .next), right)
    }

    func testSingleScreenReturnsNil() {
        XCTAssertNil(DisplayOrdering.target(from: left, in: [left], direction: .next))
    }

    func testThreeScreensCycleForward() {
        let mid = CGRect(x: 1440, y: 0, width: 800, height: 600)
        let far = CGRect(x: 3000, y: 0, width: 800, height: 600)
        let screens = [left, mid, far]
        XCTAssertEqual(DisplayOrdering.target(from: left, in: screens, direction: .next), mid)
        XCTAssertEqual(DisplayOrdering.target(from: mid, in: screens, direction: .next), far)
        XCTAssertEqual(DisplayOrdering.target(from: far, in: screens, direction: .next), left)
    }
}
