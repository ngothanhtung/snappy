import AppKit

/// A crisp, code-drawn menu-bar icon: a rounded window outline split into two
/// panes. Rendered as a template image so it tints to the menu bar's color
/// (adapts automatically to light/dark and highlight states).
enum MenuBarIcon {
    /// Standard menu-bar icon height in points.
    private static let barHeight: CGFloat = 18

    static func image() -> NSImage {
        custom() ?? drawn()
    }

    /// Override the built-in icon by dropping a file named `MenuBarIcon.png`
    /// (or `.pdf`) into the repo's `Resources/` folder — `bundle.sh` copies it
    /// into the app. Use a black-on-transparent monochrome image so it renders
    /// as a template and tints to the menu-bar color automatically.
    private static func custom() -> NSImage? {
        guard let image = Bundle.main.image(forResource: NSImage.Name("MenuBarIcon")) else {
            return nil
        }
        let ratio = image.size.width / max(image.size.height, 1)
        image.size = NSSize(width: barHeight * ratio, height: barHeight)
        image.isTemplate = true
        return image
    }

    private static func drawn() -> NSImage {
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
