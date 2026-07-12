import CoreGraphics

/// Pure hit-test geometry for annotation shapes. No platform calls.
public enum AnnotationGeometry {
    /// Shortest distance from `point` to the line segment `from`–`to`.
    /// A degenerate segment (from == to) measures distance to that point.
    public static func distanceToSegment(point: CGPoint,
                                         from a: CGPoint,
                                         to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - a.x, point.y - a.y)
        }
        // Projection parameter of `point` onto the segment, clamped to [0, 1].
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        let nearest = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(point.x - nearest.x, point.y - nearest.y)
    }

    /// Whether `point` lies inside (or on) the ellipse inscribed in `rect`.
    public static func pointInEllipse(_ point: CGPoint, rect: CGRect) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        let nx = (point.x - rect.midX) / (rect.width / 2)
        let ny = (point.y - rect.midY) / (rect.height / 2)
        return nx * nx + ny * ny <= 1
    }
}
