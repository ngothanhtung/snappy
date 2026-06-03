import CoreGraphics

/// The window layouts supported in v1: halves and thirds.
public enum WindowLayout: String, CaseIterable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case firstThird, centerThird, lastThird
    case firstTwoThirds, lastTwoThirds
}

/// Pure geometry: given a usable screen rect (top-left origin), compute the
/// target window frame for a layout. No side effects, no platform calls.
public enum LayoutCalculator {
    public static func frame(for layout: WindowLayout, in screen: CGRect) -> CGRect {
        let x = screen.minX, y = screen.minY
        let w = screen.width, h = screen.height

        // Thirds boundaries, rounded so the three columns tile exactly.
        let t1 = (w / 3).rounded()        // end of first third
        let t2 = (2 * w / 3).rounded()    // end of second third

        switch layout {
        case .leftHalf:
            return CGRect(x: x, y: y, width: (w / 2).rounded(), height: h)
        case .rightHalf:
            let half = (w / 2).rounded()
            return CGRect(x: x + half, y: y, width: w - half, height: h)
        case .topHalf:
            return CGRect(x: x, y: y, width: w, height: (h / 2).rounded())
        case .bottomHalf:
            let half = (h / 2).rounded()
            return CGRect(x: x, y: y + half, width: w, height: h - half)
        case .firstThird:
            return CGRect(x: x, y: y, width: t1, height: h)
        case .centerThird:
            return CGRect(x: x + t1, y: y, width: t2 - t1, height: h)
        case .lastThird:
            return CGRect(x: x + t2, y: y, width: w - t2, height: h)
        case .firstTwoThirds:
            return CGRect(x: x, y: y, width: t2, height: h)
        case .lastTwoThirds:
            return CGRect(x: x + t1, y: y, width: w - t1, height: h)
        }
    }
}
