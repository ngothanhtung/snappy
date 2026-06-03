import CoreGraphics

/// Coordinate-system helpers. Pure, no platform calls.
public enum Geometry {
    /// Converts a rect between AppKit global coords (origin bottom-left of the
    /// primary screen, y up) and Accessibility coords (origin top-left, y down).
    ///
    /// The transform is symmetric, so calling it twice returns the original.
    /// - Parameter primaryHeight: full height of the primary screen
    ///   (`NSScreen.screens[0].frame.height`).
    public static func flipY(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        return CGRect(x: rect.minX,
                      y: primaryHeight - rect.maxY,
                      width: rect.width,
                      height: rect.height)
    }
}
