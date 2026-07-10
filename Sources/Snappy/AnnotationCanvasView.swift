import AppKit
import UniformTypeIdentifiers

// MARK: - Tool + Annotation model

enum AnnotationTool: Int {
    case arrow = 0, rect, circle, text
}

enum Annotation {
    case arrow(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat)
    case rect(rect: CGRect, color: NSColor, width: CGFloat)
    case circle(rect: CGRect, color: NSColor, width: CGFloat)
    case text(origin: CGPoint, string: String, color: NSColor, fontSize: CGFloat)
}

// MARK: - Canvas view

final class AnnotationCanvasView: NSView {
    private let image: NSImage
    private var annotations: [Annotation] = []
    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?
    private var activeTextField: NSTextField?

    var activeTool: AnnotationTool = .arrow
    var activeColor: NSColor = .systemRed
    var activeLineWidth: CGFloat = 3

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Commit any active text field first
        if activeTextField != nil {
            commitTextEntry()
            return
        }

        if activeTool == .text {
            beginTextEntry(at: point)
            return
        }

        dragStart = point
        dragEnd = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeTool != .text else { return }
        dragEnd = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard activeTool != .text,
              let start = dragStart, let end = dragEnd,
              hypot(end.x - start.x, end.y - start.y) > 3 else {
            dragStart = nil; dragEnd = nil
            return
        }

        let dragRect = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )

        switch activeTool {
        case .arrow:
            annotations.append(.arrow(from: start, to: end,
                                      color: activeColor, width: activeLineWidth))
        case .rect:
            annotations.append(.rect(rect: dragRect,
                                     color: activeColor, width: activeLineWidth))
        case .circle:
            annotations.append(.circle(rect: dragRect,
                                       color: activeColor, width: activeLineWidth))
        case .text:
            break
        }

        dragStart = nil; dragEnd = nil
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // 1. Draw the captured screenshot
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)

        // 2. Draw all committed annotations
        for annotation in annotations { drawAnnotation(annotation) }

        // 3. Draw in-progress preview while dragging
        if let start = dragStart, let end = dragEnd {
            let dragRect = CGRect(
                x: min(start.x, end.x), y: min(start.y, end.y),
                width: abs(end.x - start.x), height: abs(end.y - start.y)
            )
            switch activeTool {
            case .arrow:  drawArrow(from: start, to: end, color: activeColor, width: activeLineWidth)
            case .rect:   drawRect(dragRect, color: activeColor, width: activeLineWidth)
            case .circle: drawCircle(dragRect, color: activeColor, width: activeLineWidth)
            case .text:   break
            }
        }
    }

    private func drawAnnotation(_ annotation: Annotation) {
        switch annotation {
        case .arrow(let from, let to, let color, let width):
            drawArrow(from: from, to: to, color: color, width: width)
        case .rect(let rect, let color, let width):
            drawRect(rect, color: color, width: width)
        case .circle(let rect, let color, let width):
            drawCircle(rect, color: color, width: width)
        case .text(let origin, let string, let color, let fontSize):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: fontSize),
                .foregroundColor: color,
            ]
            (string as NSString).draw(at: origin, withAttributes: attrs)
        }
    }

    // MARK: - Shape drawing helpers

    private func drawArrow(from a: CGPoint, to b: CGPoint,
                           color: NSColor, width: CGFloat) {
        let headLen = width * 4.5
        let headAngle: CGFloat = .pi / 6

        color.setStroke()
        color.setFill()

        // Shaft
        let shaft = NSBezierPath()
        shaft.lineWidth = width
        shaft.lineCapStyle = .round
        shaft.move(to: a); shaft.line(to: b)
        shaft.stroke()

        // Filled arrowhead triangle at endpoint
        let angle = atan2(b.y - a.y, b.x - a.x)
        let p1 = CGPoint(x: b.x - headLen * cos(angle - headAngle),
                         y: b.y - headLen * sin(angle - headAngle))
        let p2 = CGPoint(x: b.x - headLen * cos(angle + headAngle),
                         y: b.y - headLen * sin(angle + headAngle))
        let head = NSBezierPath()
        head.move(to: b); head.line(to: p1); head.line(to: p2); head.close()
        head.fill()
    }

    private func drawRect(_ rect: CGRect, color: NSColor, width: CGFloat) {
        let path = NSBezierPath(rect: rect)
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    private func drawCircle(_ rect: CGRect, color: NSColor, width: CGFloat) {
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    // MARK: - Text tool

    private func beginTextEntry(at point: CGPoint) {
        let field = NSTextField(frame: CGRect(x: point.x, y: point.y, width: 200, height: 28))
        field.font = NSFont.boldSystemFont(ofSize: 16)
        field.textColor = activeColor
        field.backgroundColor = NSColor.white.withAlphaComponent(0.85)
        field.isBordered = true
        field.isEditable = true
        field.delegate = self
        field.target = self
        field.action = #selector(textFieldAction)
        addSubview(field)
        window?.makeFirstResponder(field)
        activeTextField = field
    }

    private func commitTextEntry() {
        guard let field = activeTextField else { return }
        activeTextField = nil
        let text = field.stringValue
        let origin = CGPoint(x: field.frame.minX, y: field.frame.minY)
        field.removeFromSuperview()
        if !text.isEmpty {
            annotations.append(.text(origin: origin, string: text,
                                     color: activeColor, fontSize: 16))
        }
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    @objc private func textFieldAction() {
        commitTextEntry()
    }

    // MARK: - Toolbar actions

    @objc func changeTool(_ sender: NSSegmentedControl) {
        activeTool = AnnotationTool(rawValue: sender.selectedSegment) ?? .arrow
    }

    @objc func changeWidth(_ sender: NSStepper) {
        activeLineWidth = CGFloat(sender.intValue)
    }

    @objc func undoLast() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        needsDisplay = true
    }

    @objc func copyToClipboard() {
        guard let img = renderToImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }

    @objc func saveImage() {
        guard let img = renderToImage() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "screenshot-\(Int(Date().timeIntervalSince1970)).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    private func renderToImage() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        return img
    }
}

// MARK: - NSTextFieldDelegate

extension AnnotationCanvasView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextEntry()
    }
}
