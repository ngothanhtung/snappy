import AppKit

// MARK: - Window

final class RegionOverlayWindow: NSWindow {
    var onRegionSelected: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    init() {
        // Cover the entire virtual desktop (all screens)
        let virtualDesktop = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        super.init(
            contentRect: virtualDesktop,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true

        let view = RegionOverlayView(
            frame: CGRect(origin: .zero, size: virtualDesktop.size)
        )
        view.windowOrigin = virtualDesktop.origin
        view.onRegionSelected = { [weak self] rect in self?.onRegionSelected?(rect) }
        view.onCancelled = { [weak self] in
            self?.orderOut(nil)
            self?.onCancelled?()
        }
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        makeFirstResponder(contentView)
    }
}

// MARK: - Phase enum

private enum OverlayPhase { case idle, selecting, confirming }

// MARK: - Handle enum

private enum DragHandle: CaseIterable {
    case topLeft, top, topRight
    case right
    case bottomRight, bottom, bottomLeft
    case left

    func center(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.maxY)
        case .top:         return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.maxY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.minY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    var cursor: NSCursor {
        switch self {
        case .top, .bottom:                   return .resizeUpDown
        case .left, .right:                   return .resizeLeftRight
        case .topLeft, .bottomRight,
             .topRight, .bottomLeft:          return .crosshair
        }
    }
}

// MARK: - Overlay view

final class RegionOverlayView: NSView {
    // Set by RegionOverlayWindow to convert view coords → AppKit global
    var windowOrigin: CGPoint = .zero
    var onRegionSelected: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    private var phase: OverlayPhase = .idle
    private var selectionRect: CGRect = .zero
    private var startPoint: CGPoint?

    // Phase 2 drag state
    private var activeHandle: DragHandle?
    private var isMoving = false
    private var dragStartPoint: CGPoint?
    private var rectAtDragStart: CGRect = .zero

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // ESC key
    override func cancelOperation(_ sender: Any?) {
        onCancelled?()
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch phase {
        case .idle, .selecting:
            phase = .selecting
            startPoint = point
            selectionRect = .zero
            activeHandle = nil
            isMoving = false
            needsDisplay = true
        case .confirming:
            handleConfirmingMouseDown(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch phase {
        case .selecting:
            guard let start = startPoint else { return }
            selectionRect = CGRect(
                x: min(start.x, point.x), y: min(start.y, point.y),
                width: abs(point.x - start.x), height: abs(point.y - start.y)
            )
            needsDisplay = true
        case .confirming:
            handleConfirmingMouseDragged(to: point)
        case .idle:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch phase {
        case .selecting:
            if selectionRect.width > 5, selectionRect.height > 5 {
                phase = .confirming
            } else {
                selectionRect = .zero
                phase = .idle
            }
            needsDisplay = true
        case .confirming:
            activeHandle = nil
            isMoving = false
            dragStartPoint = nil
            needsDisplay = true
        case .idle:
            break
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard phase == .confirming else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let handle = hitHandle(at: point) {
            handle.cursor.set()
        } else if selectionRect.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    // MARK: - Phase 2 interaction

    private func handleConfirmingMouseDown(at point: CGPoint) {
        let bar = confirmBarRect(for: selectionRect)

        // Cancel (left half of bar)
        if CGRect(x: bar.minX, y: bar.minY, width: bar.width / 2, height: bar.height)
            .contains(point) {
            onCancelled?()
            return
        }

        // Capture (right half of bar)
        if CGRect(x: bar.midX, y: bar.minY, width: bar.width / 2, height: bar.height)
            .contains(point) {
            fireCapture()
            return
        }

        // Handle hit test
        if let handle = hitHandle(at: point) {
            activeHandle = handle
            dragStartPoint = point
            rectAtDragStart = selectionRect
            return
        }

        // Inside selection → move
        if selectionRect.contains(point) {
            isMoving = true
            dragStartPoint = point
            rectAtDragStart = selectionRect
            NSCursor.closedHand.set()
            return
        }

        // Outside → start new selection
        phase = .selecting
        startPoint = point
        selectionRect = .zero
        activeHandle = nil
        isMoving = false
        needsDisplay = true
    }

    private func handleConfirmingMouseDragged(to point: CGPoint) {
        if let handle = activeHandle {
            selectionRect = applyResize(handle, original: rectAtDragStart, to: point)
            needsDisplay = true
        } else if isMoving, let start = dragStartPoint {
            let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
            selectionRect = CGRect(
                x: rectAtDragStart.minX + delta.x,
                y: rectAtDragStart.minY + delta.y,
                width: rectAtDragStart.width,
                height: rectAtDragStart.height
            )
            needsDisplay = true
        }
    }

    private func fireCapture() {
        // Convert view-local → AppKit global coordinates
        let screenRect = CGRect(
            x: selectionRect.minX + windowOrigin.x,
            y: selectionRect.minY + windowOrigin.y,
            width: selectionRect.width,
            height: selectionRect.height
        )
        onRegionSelected?(screenRect)
    }

    private func hitHandle(at point: CGPoint) -> DragHandle? {
        DragHandle.allCases.first { handle in
            let c = handle.center(in: selectionRect)
            return hypot(point.x - c.x, point.y - c.y) <= 12
        }
    }

    // All calculations reference `orig` (rect at drag start), not current state
    private func applyResize(_ handle: DragHandle, original orig: CGRect,
                             to pt: CGPoint) -> CGRect {
        switch handle {
        case .topLeft:
            let x = min(pt.x, orig.maxX - 5)
            return CGRect(x: x, y: orig.minY, width: orig.maxX - x,
                          height: max(pt.y - orig.minY, 5))
        case .top:
            return CGRect(x: orig.minX, y: orig.minY, width: orig.width,
                          height: max(pt.y - orig.minY, 5))
        case .topRight:
            return CGRect(x: orig.minX, y: orig.minY,
                          width: max(pt.x - orig.minX, 5),
                          height: max(pt.y - orig.minY, 5))
        case .right:
            return CGRect(x: orig.minX, y: orig.minY,
                          width: max(pt.x - orig.minX, 5), height: orig.height)
        case .bottomRight:
            let y = min(pt.y, orig.maxY - 5)
            return CGRect(x: orig.minX, y: y,
                          width: max(pt.x - orig.minX, 5), height: orig.maxY - y)
        case .bottom:
            let y = min(pt.y, orig.maxY - 5)
            return CGRect(x: orig.minX, y: y, width: orig.width, height: orig.maxY - y)
        case .bottomLeft:
            let x = min(pt.x, orig.maxX - 5)
            let y = min(pt.y, orig.maxY - 5)
            return CGRect(x: x, y: y, width: orig.maxX - x, height: orig.maxY - y)
        case .left:
            let x = min(pt.x, orig.maxX - 5)
            return CGRect(x: x, y: orig.minY, width: orig.maxX - x, height: orig.height)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Dim the whole virtual desktop
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard phase != .idle, !selectionRect.isEmpty else { return }

        // Punch a hole to reveal screen content under the selection
        NSGraphicsContext.current?.cgContext.clear(selectionRect)

        // White selection border
        let border = NSBezierPath(rect: selectionRect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1.5
        NSColor.white.setStroke()
        border.stroke()

        // Size label (W × H)
        drawSizeLabel(for: selectionRect)

        // Phase 2: handles + confirm bar
        if phase == .confirming {
            drawHandles(for: selectionRect)
            drawConfirmBar(confirmBarRect(for: selectionRect))
        }
    }

    private func drawSizeLabel(for rect: CGRect) {
        let text = "\(Int(rect.width)) \u{00D7} \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        var labelRect = CGRect(
            x: rect.midX - textSize.width / 2 - 4,
            y: rect.maxY + 6,
            width: textSize.width + 8,
            height: textSize.height + 4
        )
        if labelRect.maxY > bounds.maxY - 4 {
            labelRect.origin.y = rect.minY - labelRect.height - 6
        }
        let bg = NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.65).setFill()
        bg.fill()
        (text as NSString).draw(
            at: CGPoint(x: labelRect.minX + 4, y: labelRect.minY + 2),
            withAttributes: attrs
        )
    }

    private func drawHandles(for rect: CGRect) {
        for handle in DragHandle.allCases {
            let center = handle.center(in: rect)
            let r = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
            let path = NSBezierPath(ovalIn: r)
            NSColor.white.setFill()
            path.fill()
            NSColor(white: 0.3, alpha: 1).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func confirmBarRect(for rect: CGRect) -> CGRect {
        let w: CGFloat = 180, h: CGFloat = 36, gap: CGFloat = 16
        var y = rect.minY - gap - h
        if y < 4 { y = rect.maxY + gap }
        let x = max(4, min(rect.midX - w / 2, bounds.maxX - w - 4))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func drawConfirmBar(_ barRect: CGRect) {
        // Dark pill background
        let bg = NSBezierPath(roundedRect: barRect, xRadius: 8, yRadius: 8)
        NSColor(white: 0.1, alpha: 0.88).setFill()
        bg.fill()

        // Vertical divider between Cancel / Capture
        let div = NSBezierPath()
        div.move(to: CGPoint(x: barRect.midX, y: barRect.minY + 6))
        div.line(to: CGPoint(x: barRect.midX, y: barRect.maxY - 6))
        NSColor(white: 0.4, alpha: 1).setStroke()
        div.lineWidth = 0.5
        div.stroke()

        let cancelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let captureAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.systemBlue,
        ]
        let cancelSize = ("Cancel" as NSString).size(withAttributes: cancelAttrs)
        let captureSize = ("Capture" as NSString).size(withAttributes: captureAttrs)
        let textY = barRect.minY + (barRect.height - cancelSize.height) / 2

        ("Cancel" as NSString).draw(
            at: CGPoint(x: barRect.minX + (barRect.width / 2 - cancelSize.width) / 2, y: textY),
            withAttributes: cancelAttrs
        )
        ("Capture" as NSString).draw(
            at: CGPoint(x: barRect.midX + (barRect.width / 2 - captureSize.width) / 2, y: textY),
            withAttributes: captureAttrs
        )
    }
}
