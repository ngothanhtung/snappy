import AppKit
import UniformTypeIdentifiers
import SnappyCore

// MARK: - Tool + Annotation model

enum AnnotationTool: Int {
    case select = 0, arrow, rect, circle, text, stamp, step
}

enum ArrowStyle: Int {
    case head = 0   // →
    case both       // ↔
    case line       // —
    case dotTail    // ●→
}

struct Annotation {
    enum Shape {
        case arrow(from: CGPoint, to: CGPoint, style: ArrowStyle)
        case rect(CGRect)
        case circle(CGRect)
        case text(origin: CGPoint, string: String)
        case emoji(center: CGPoint, symbol: String)
        case step(center: CGPoint, number: Int)
    }

    var shape: Shape
    var color: NSColor
    var width: CGFloat

    /// Labels derive their font size from the shared width control.
    var fontSize: CGFloat { 10 + 2 * width }
    /// Emoji stamps scale with the width control too.
    var emojiSize: CGFloat { 12 + 8 * width }
    /// Step badge diameter.
    var stepDiameter: CGFloat { 16 + 4 * width }

    func translated(by delta: CGPoint) -> Annotation {
        var copy = self
        switch shape {
        case .arrow(let from, let to, let style):
            copy.shape = .arrow(from: CGPoint(x: from.x + delta.x, y: from.y + delta.y),
                                to: CGPoint(x: to.x + delta.x, y: to.y + delta.y),
                                style: style)
        case .rect(let rect):
            copy.shape = .rect(rect.offsetBy(dx: delta.x, dy: delta.y))
        case .circle(let rect):
            copy.shape = .circle(rect.offsetBy(dx: delta.x, dy: delta.y))
        case .text(let origin, let string):
            copy.shape = .text(origin: CGPoint(x: origin.x + delta.x, y: origin.y + delta.y),
                               string: string)
        case .emoji(let center, let symbol):
            copy.shape = .emoji(center: CGPoint(x: center.x + delta.x, y: center.y + delta.y),
                                symbol: symbol)
        case .step(let center, let number):
            copy.shape = .step(center: CGPoint(x: center.x + delta.x, y: center.y + delta.y),
                               number: number)
        }
        return copy
    }

    var boundingBox: CGRect {
        switch shape {
        case .arrow(let from, let to, _):
            return CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                          width: abs(to.x - from.x), height: abs(to.y - from.y))
                .insetBy(dx: -width * 2, dy: -width * 2)
        case .rect(let rect), .circle(let rect):
            return rect
        case .text(let origin, let string):
            let size = (string as NSString).size(withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: fontSize),
            ])
            return CGRect(origin: origin, size: size)
        case .emoji(let center, let symbol):
            let size = (symbol as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: emojiSize),
            ])
            return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                          width: size.width, height: size.height)
        case .step(let center, _):
            return CGRect(x: center.x - stepDiameter / 2, y: center.y - stepDiameter / 2,
                          width: stepDiameter, height: stepDiameter)
        }
    }

    func hitTest(_ point: CGPoint) -> Bool {
        let slop: CGFloat = 4
        switch shape {
        case .arrow(let from, let to, _):
            return AnnotationGeometry.distanceToSegment(point: point, from: from, to: to)
                <= max(width / 2 + slop, 8)
        case .rect(let rect):
            return rect.insetBy(dx: -slop, dy: -slop).contains(point)
        case .circle(let rect):
            return AnnotationGeometry.pointInEllipse(point, rect: rect.insetBy(dx: -slop, dy: -slop))
        case .text, .emoji:
            return boundingBox.insetBy(dx: -slop, dy: -slop).contains(point)
        case .step:
            return AnnotationGeometry.pointInEllipse(
                point, rect: boundingBox.insetBy(dx: -slop, dy: -slop))
        }
    }
}

// MARK: - Canvas view

final class AnnotationCanvasView: NSView {
    private let image: NSImage
    private let fileURL: URL?
    private var annotations: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?
    private var activeTextField: NSTextField?

    // Select-tool state
    private var selectedIndex: Int?
    private var lastMovePoint: CGPoint?
    private var moveSnapshotPushed = false

    // Suppresses selection chrome while rendering for Copy/Save.
    private var isExporting = false

    var activeTool: AnnotationTool = .arrow
    var activeColor: NSColor = .systemRed
    var activeLineWidth: CGFloat = 3
    var activeArrowStyle: ArrowStyle = .head
    var activeEmoji: String = "\u{2705}"  // ✅

    static let stampEmojis = ["\u{2705}", "\u{274C}", "\u{26A0}\u{FE0F}", "\u{2757}",
                              "\u{1F449}", "\u{2B50}", "\u{1F525}", "\u{1F4A1}",
                              "\u{1F41B}", "\u{2753}"]

    init(image: NSImage, fileURL: URL? = nil) {
        self.image = image
        self.fileURL = fileURL
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Undo bookkeeping

    private func pushUndoSnapshot() {
        undoStack.append(annotations)
        if undoStack.count > 100 { undoStack.removeFirst() }
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)

        // Commit any active text field first
        if activeTextField != nil {
            commitTextEntry()
            if activeTool == .text { return }
            // fall through: let the click begin a drag for the other tools
        }

        switch activeTool {
        case .select:
            // Topmost annotation first
            selectedIndex = annotations.lastIndex(where: { $0.hitTest(point) })
            lastMovePoint = selectedIndex != nil ? point : nil
            moveSnapshotPushed = false
            needsDisplay = true
        case .text:
            beginTextEntry(at: point)
        case .stamp:
            pushUndoSnapshot()
            annotations.append(Annotation(
                shape: .emoji(center: point, symbol: activeEmoji),
                color: activeColor, width: activeLineWidth))
            needsDisplay = true
        case .step:
            pushUndoSnapshot()
            annotations.append(Annotation(
                shape: .step(center: point, number: nextStepNumber),
                color: activeColor, width: activeLineWidth))
            needsDisplay = true
        case .arrow, .rect, .circle:
            dragStart = point
            dragEnd = point
        }
    }

    private var nextStepNumber: Int {
        (annotations.compactMap { annotation -> Int? in
            if case .step(_, let number) = annotation.shape { return number }
            return nil
        }.max() ?? 0) + 1
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if activeTool == .select {
            guard let index = selectedIndex, let last = lastMovePoint else { return }
            if !moveSnapshotPushed {
                pushUndoSnapshot()
                moveSnapshotPushed = true
            }
            annotations[index] = annotations[index]
                .translated(by: CGPoint(x: point.x - last.x, y: point.y - last.y))
            lastMovePoint = point
            needsDisplay = true
            return
        }

        guard dragStart != nil else { return }
        dragEnd = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if activeTool == .select {
            lastMovePoint = nil
            return
        }

        guard let start = dragStart, let end = dragEnd,
              hypot(end.x - start.x, end.y - start.y) > 3 else {
            dragStart = nil; dragEnd = nil
            return
        }

        let dragRect = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )

        pushUndoSnapshot()
        switch activeTool {
        case .arrow:
            annotations.append(Annotation(
                shape: .arrow(from: start, to: end, style: activeArrowStyle),
                color: activeColor, width: activeLineWidth))
        case .rect:
            annotations.append(Annotation(
                shape: .rect(dragRect), color: activeColor, width: activeLineWidth))
        case .circle:
            annotations.append(Annotation(
                shape: .circle(dragRect), color: activeColor, width: activeLineWidth))
        case .select, .text, .stamp, .step:
            break
        }

        dragStart = nil; dragEnd = nil
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            if selectedIndex != nil {
                selectedIndex = nil
                needsDisplay = true
                return
            }
        case 51, 117: // Delete, Forward Delete
            if let index = selectedIndex {
                pushUndoSnapshot()
                annotations.remove(at: index)
                selectedIndex = nil
                needsDisplay = true
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // 1. Draw the captured screenshot
        image.draw(in: bounds)

        // 2. Draw all committed annotations
        for annotation in annotations { drawAnnotation(annotation) }

        // 3. Selection chrome (never exported)
        if !isExporting, let index = selectedIndex, index < annotations.count {
            drawSelectionChrome(around: annotations[index].boundingBox)
        }

        // 4. Draw in-progress preview while dragging
        if let start = dragStart, let end = dragEnd {
            let dragRect = CGRect(
                x: min(start.x, end.x), y: min(start.y, end.y),
                width: abs(end.x - start.x), height: abs(end.y - start.y)
            )
            switch activeTool {
            case .arrow:
                drawArrow(from: start, to: end, style: activeArrowStyle,
                          color: activeColor, width: activeLineWidth)
            case .rect:   drawRect(dragRect, color: activeColor, width: activeLineWidth)
            case .circle: drawCircle(dragRect, color: activeColor, width: activeLineWidth)
            case .select, .text, .stamp, .step: break
            }
        }
    }

    private func drawAnnotation(_ annotation: Annotation) {
        switch annotation.shape {
        case .arrow(let from, let to, let style):
            drawArrow(from: from, to: to, style: style,
                      color: annotation.color, width: annotation.width)
        case .rect(let rect):
            drawRect(rect, color: annotation.color, width: annotation.width)
        case .circle(let rect):
            drawCircle(rect, color: annotation.color, width: annotation.width)
        case .text(let origin, let string):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: annotation.fontSize),
                .foregroundColor: annotation.color,
            ]
            (string as NSString).draw(at: origin, withAttributes: attrs)
        case .emoji(_, let symbol):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: annotation.emojiSize),
            ]
            (symbol as NSString).draw(at: annotation.boundingBox.origin, withAttributes: attrs)
        case .step(_, let number):
            let box = annotation.boundingBox
            annotation.color.setFill()
            NSBezierPath(ovalIn: box).fill()
            let label = "\(number)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: annotation.stepDiameter * 0.55),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: box.midX - size.width / 2,
                                   y: box.midY - size.height / 2),
                       withAttributes: attrs)
        }
    }

    private func drawSelectionChrome(around box: CGRect) {
        let path = NSBezierPath(rect: box.insetBy(dx: -4, dy: -4))
        path.lineWidth = 1.5
        path.setLineDash([5, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    // MARK: - Shape drawing helpers

    private func drawArrow(from a: CGPoint, to b: CGPoint, style: ArrowStyle,
                           color: NSColor, width: CGFloat) {
        color.setStroke()
        color.setFill()

        // The shaft's rounded cap would blunt the sharp tip, so end the shaft
        // where the arrowhead begins instead of at the tip itself.
        let headLen = Self.arrowheadLength(for: width)
        let length = hypot(b.x - a.x, b.y - a.y)
        let unit = length > 0
            ? CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
            : CGPoint(x: 1, y: 0)
        let inset = min(headLen * 0.8, length / 2)

        var shaftStart = a
        var shaftEnd = b
        switch style {
        case .head, .dotTail:
            shaftEnd = CGPoint(x: b.x - unit.x * inset, y: b.y - unit.y * inset)
        case .both:
            shaftEnd = CGPoint(x: b.x - unit.x * inset, y: b.y - unit.y * inset)
            shaftStart = CGPoint(x: a.x + unit.x * inset, y: a.y + unit.y * inset)
        case .line:
            break
        }

        let shaft = NSBezierPath()
        shaft.lineWidth = width
        shaft.lineCapStyle = .round
        shaft.move(to: shaftStart); shaft.line(to: shaftEnd)
        shaft.stroke()

        switch style {
        case .head:
            drawArrowhead(at: b, from: a, width: width)
        case .both:
            drawArrowhead(at: b, from: a, width: width)
            drawArrowhead(at: a, from: b, width: width)
        case .line:
            break
        case .dotTail:
            drawArrowhead(at: b, from: a, width: width)
            let radius = max(width * 1.6, 4)
            NSBezierPath(ovalIn: CGRect(x: a.x - radius, y: a.y - radius,
                                        width: radius * 2, height: radius * 2)).fill()
        }
    }

    private static func arrowheadLength(for width: CGFloat) -> CGFloat {
        max(width * 6, 14)
    }

    /// Filled triangle pointing at `tip`, oriented away from `tail`.
    private func drawArrowhead(at tip: CGPoint, from tail: CGPoint, width: CGFloat) {
        let headLen = Self.arrowheadLength(for: width)
        let headAngle: CGFloat = .pi / 9  // 20° half-angle: slim, sharp tip
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let p1 = CGPoint(x: tip.x - headLen * cos(angle - headAngle),
                         y: tip.y - headLen * sin(angle - headAngle))
        let p2 = CGPoint(x: tip.x - headLen * cos(angle + headAngle),
                         y: tip.y - headLen * sin(angle + headAngle))
        let head = NSBezierPath()
        head.move(to: tip); head.line(to: p1); head.line(to: p2); head.close()
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
        field.font = NSFont.boldSystemFont(ofSize: 10 + 2 * activeLineWidth)
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
            pushUndoSnapshot()
            annotations.append(Annotation(
                shape: .text(origin: origin, string: text),
                color: activeColor, width: activeLineWidth))
        }
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    @objc private func textFieldAction() {
        commitTextEntry()
    }

    // MARK: - Toolbar actions

    @objc func changeTool(_ sender: NSSegmentedControl) {
        activeTool = AnnotationTool(rawValue: sender.selectedSegment) ?? .select
        if activeTool != .select, selectedIndex != nil {
            selectedIndex = nil
            needsDisplay = true
        }
    }

    /// Applies to the selected annotation (if any) and becomes the default.
    func applyColor(_ color: NSColor) {
        activeColor = color
        if let index = selectedIndex, index < annotations.count {
            pushUndoSnapshot()
            annotations[index].color = color
            needsDisplay = true
        }
    }

    @objc func changeWidth(_ sender: NSStepper) {
        activeLineWidth = CGFloat(sender.intValue)
        if let index = selectedIndex, index < annotations.count {
            pushUndoSnapshot()
            annotations[index].width = activeLineWidth
            needsDisplay = true
        }
    }

    @objc func changeEmoji(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem >= 0,
              sender.indexOfSelectedItem < Self.stampEmojis.count else { return }
        activeEmoji = Self.stampEmojis[sender.indexOfSelectedItem]
        if let index = selectedIndex, index < annotations.count,
           case .emoji(let center, _) = annotations[index].shape {
            pushUndoSnapshot()
            annotations[index].shape = .emoji(center: center, symbol: activeEmoji)
            needsDisplay = true
        }
    }

    @objc func changeArrowStyle(_ sender: NSPopUpButton) {
        activeArrowStyle = ArrowStyle(rawValue: sender.indexOfSelectedItem) ?? .head
        if let index = selectedIndex, index < annotations.count,
           case .arrow(let from, let to, _) = annotations[index].shape {
            pushUndoSnapshot()
            annotations[index].shape = .arrow(from: from, to: to, style: activeArrowStyle)
            needsDisplay = true
        }
    }

    @objc func undoLast() {
        if activeTextField != nil {
            // Cancel in-progress text entry without committing
            activeTextField?.removeFromSuperview()
            activeTextField = nil
            window?.makeFirstResponder(self)
            return
        }
        guard let snapshot = undoStack.popLast() else { return }
        annotations = snapshot
        if let index = selectedIndex, index >= annotations.count {
            selectedIndex = nil
        }
        needsDisplay = true
    }

    @objc func copyToClipboard() {
        commitTextEntry()
        guard let img = renderToImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }

    @objc func saveImage() {
        commitTextEntry()
        guard let img = renderToImage() else { return }
        let url: URL
        if let fileURL {
            url = fileURL
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "screenshot-\(Int(Date().timeIntervalSince1970)).png"
            guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
            url = selectedURL
        }
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Save failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func renderToImage() -> NSImage? {
        let sourceRep = image.representations.max {
            ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh)
        }
        let pixelW = sourceRep?.pixelsWide ?? Int(bounds.width.rounded())
        let pixelH = sourceRep?.pixelsHigh ?? Int(bounds.height.rounded())
        let scaleX = CGFloat(pixelW) / bounds.width
        let scaleY = CGFloat(pixelH) / bounds.height
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelW, pixelsHigh: pixelH,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        // NSGraphicsContext(bitmapImageRep:) pre-scales its CTM by pixels/size
        // when rep.size is already set, which would stack with scaleBy below
        // and render at 4x. Create the context while rep.size is still 1:1,
        // and only set the logical size (DPI metadata) after drawing.
        isExporting = true
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.scaleBy(x: scaleX, y: scaleY)
        draw(bounds)
        NSGraphicsContext.restoreGraphicsState()
        isExporting = false
        rep.size = bounds.size  // preserve logical size so DPI metadata is correct
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
