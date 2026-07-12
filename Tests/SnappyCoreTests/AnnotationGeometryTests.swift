import XCTest
import CoreGraphics
@testable import SnappyCore

final class AnnotationGeometryTests: XCTestCase {

    // MARK: - distanceToSegment

    func testPointOnSegmentIsZero() {
        XCTAssertEqual(AnnotationGeometry.distanceToSegment(
            point: CGPoint(x: 5, y: 0),
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0)), 0, accuracy: 1e-9)
    }

    func testPerpendicularDistanceToHorizontalSegment() {
        XCTAssertEqual(AnnotationGeometry.distanceToSegment(
            point: CGPoint(x: 5, y: 3),
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0)), 3, accuracy: 1e-9)
    }

    func testDistanceBeyondEndpointUsesEndpoint() {
        // Point past the segment end: distance is to the endpoint, not the line.
        XCTAssertEqual(AnnotationGeometry.distanceToSegment(
            point: CGPoint(x: 13, y: 4),
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0)), 5, accuracy: 1e-9)
    }

    func testDistanceBeforeStartUsesStartPoint() {
        XCTAssertEqual(AnnotationGeometry.distanceToSegment(
            point: CGPoint(x: -3, y: -4),
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0)), 5, accuracy: 1e-9)
    }

    func testDegenerateSegmentIsDistanceToPoint() {
        XCTAssertEqual(AnnotationGeometry.distanceToSegment(
            point: CGPoint(x: 3, y: 4),
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: 0)), 5, accuracy: 1e-9)
    }

    func testDiagonalSegment() {
        // Segment (0,0)-(10,10); point (10,0) is at perpendicular distance 10/√2.
        XCTAssertEqual(AnnotationGeometry.distanceToSegment(
            point: CGPoint(x: 10, y: 0),
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 10)),
            10 / sqrt(2), accuracy: 1e-9)
    }

    // MARK: - pointInEllipse

    func testCenterIsInsideEllipse() {
        XCTAssertTrue(AnnotationGeometry.pointInEllipse(
            CGPoint(x: 50, y: 30), rect: CGRect(x: 0, y: 0, width: 100, height: 60)))
    }

    func testEllipseEdgeMidpointsAreInside() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 60)
        XCTAssertTrue(AnnotationGeometry.pointInEllipse(CGPoint(x: 0, y: 30), rect: rect))
        XCTAssertTrue(AnnotationGeometry.pointInEllipse(CGPoint(x: 50, y: 60), rect: rect))
    }

    func testRectCornerIsOutsideEllipse() {
        // Corners of the bounding rect are outside the inscribed ellipse.
        XCTAssertFalse(AnnotationGeometry.pointInEllipse(
            CGPoint(x: 2, y: 2), rect: CGRect(x: 0, y: 0, width: 100, height: 60)))
    }

    func testPointOutsideRectIsOutsideEllipse() {
        XCTAssertFalse(AnnotationGeometry.pointInEllipse(
            CGPoint(x: 120, y: 30), rect: CGRect(x: 0, y: 0, width: 100, height: 60)))
    }

    func testZeroSizeRectContainsNothing() {
        XCTAssertFalse(AnnotationGeometry.pointInEllipse(
            CGPoint(x: 0, y: 0), rect: CGRect(x: 0, y: 0, width: 0, height: 0)))
    }
}
