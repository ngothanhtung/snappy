import AppKit

/// Picks the screen a window belongs to. All rects are in AppKit coords.
enum ScreenProvider {
    /// The screen with the largest overlap with the window. Falls back to the
    /// main screen (the one with keyboard focus) when there is no overlap.
    static func screen(containing rect: CGRect) -> NSScreen {
        let best = NSScreen.screens.max { a, b in
            overlapArea(rect, a.frame) < overlapArea(rect, b.frame)
        }
        if let best, overlapArea(rect, best.frame) > 0 {
            return best
        }
        return NSScreen.main ?? NSScreen.screens.first ?? best!
    }

    private static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }
}
