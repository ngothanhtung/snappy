import AppKit

/// A crisp, code-drawn menu-bar icon: a rounded window outline split into two
/// panes. Rendered as a template image so it tints to the menu bar's color
/// (adapts automatically to light/dark and highlight states).
enum MenuBarIcon {
    static func image() -> NSImage {
        let size = NSSize(width: 18, height: 14)
        let image = NSImage(size: size, flipped: false) { _ in
            let bounds = NSRect(origin: .zero, size: size)
            let frame = bounds.insetBy(dx: 1, dy: 1)

            NSColor.black.setStroke()

            let outline = NSBezierPath(roundedRect: frame, xRadius: 2.5, yRadius: 2.5)
            outline.lineWidth = 1.4
            outline.stroke()

            // Vertical divider at ~42% — evokes a left/right split.
            let x = frame.minX + frame.width * 0.42
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: x, y: frame.minY))
            divider.line(to: NSPoint(x: x, y: frame.maxY))
            divider.lineWidth = 1.4
            divider.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }
}
