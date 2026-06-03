import XCTest
import CoreGraphics
@testable import MagnetCore

/// `DisplayMapper` remaps a window's frame from one screen's usable area onto
/// another's, preserving relative position and size. Coordinate-system
/// agnostic — caller passes all rects in the same space.
final class DisplayMapperTests: XCTestCase {

    private let source = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testWindowFillingSourceFillsTarget() {
        let target = CGRect(x: 2000, y: 0, width: 1600, height: 1200)
        let window = source
        XCTAssertEqual(DisplayMapper.mappedFrame(of: window, from: source, to: target),
                       target)
    }

    func testLeftHalfStaysLeftHalfOnTarget() {
        let target = CGRect(x: 2000, y: 0, width: 1600, height: 1200)
        let window = CGRect(x: 0, y: 0, width: 500, height: 800) // left half of source
        XCTAssertEqual(DisplayMapper.mappedFrame(of: window, from: source, to: target),
                       CGRect(x: 2000, y: 0, width: 800, height: 1200))
    }

    func testProportionalPositionAndSize() {
        let target = CGRect(x: 0, y: 0, width: 2000, height: 1600) // 2× source
        let window = CGRect(x: 100, y: 200, width: 300, height: 400)
        // Everything doubles relative to origin.
        XCTAssertEqual(DisplayMapper.mappedFrame(of: window, from: source, to: target),
                       CGRect(x: 200, y: 400, width: 600, height: 800))
    }

    func testRespectsSourceAndTargetOrigins() {
        let offsetSource = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let target = CGRect(x: 5000, y: 300, width: 1000, height: 800) // same size
        let window = CGRect(x: 200, y: 150, width: 400, height: 400) // +100,+100 into source
        // Same size target → same relative offset preserved.
        XCTAssertEqual(DisplayMapper.mappedFrame(of: window, from: offsetSource, to: target),
                       CGRect(x: 5100, y: 400, width: 400, height: 400))
    }
}
