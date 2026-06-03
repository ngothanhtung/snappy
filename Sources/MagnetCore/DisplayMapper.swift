import CoreGraphics

/// Remaps a window frame from one screen's usable area onto another's,
/// preserving relative position and size. Pure; all rects share one space.
public enum DisplayMapper {
    public static func mappedFrame(of window: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return window }
        let relX = (window.minX - source.minX) / source.width
        let relY = (window.minY - source.minY) / source.height
        let relW = window.width / source.width
        let relH = window.height / source.height
        return CGRect(x: target.minX + relX * target.width,
                      y: target.minY + relY * target.height,
                      width: relW * target.width,
                      height: relH * target.height)
    }
}
