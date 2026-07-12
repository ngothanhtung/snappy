# Region Capture + Annotation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Capture Region" action to Snappy: drag-select a screen area, annotate with arrows/rectangles/circles/text, then copy to clipboard or save as PNG.

**Architecture:** 4 new Swift files (RegionCaptureController, RegionOverlayWindow, AnnotationEditorController, AnnotationCanvasView) plus 4 modified files (ShortcutNames, WindowManager, StatusMenuController, SettingsView). The overlay window uses CoreGraphics for screen capture; the annotation canvas uses NSBezierPath for all drawing. No new SPM dependencies.

**Tech Stack:** Swift 5.9, AppKit (NSWindow, NSView, NSBezierPath), CoreGraphics (CGDisplayCreateImage), UniformTypeIdentifiers, KeyboardShortcuts (existing)

---

## File Map

| File | Status | Responsibility |
|---|---|---|
| `Sources/Snappy/ShortcutNames.swift` | Modify | Add `captureRegion` Name, `AppAction.captureRegion`, `Bindings.capture` |
| `Sources/Snappy/WindowManager.swift` | Modify | Dispatch `captureRegion` without Accessibility check |
| `Sources/Snappy/StatusMenuController.swift` | Modify | Add Capture section before Settings |
| `Sources/Snappy/SettingsView.swift` | Modify | Add "Capture" section with Recorder |
| `Sources/Snappy/RegionCaptureController.swift` | Create | Singleton: permission check, overlay lifecycle, screen capture |
| `Sources/Snappy/RegionOverlayWindow.swift` | Create | Borderless overlay window + NSView with Phase 1/2 UX |
| `Sources/Snappy/AnnotationEditorController.swift` | Create | Singleton: editor window, toolbar, ColorSwatchButton |
| `Sources/Snappy/AnnotationCanvasView.swift` | Create | Image display + all annotation drawing + export |

---

### Task 1: Wire captureRegion into the existing action system

**Files:**
- Modify: `Sources/Snappy/ShortcutNames.swift`
- Modify: `Sources/Snappy/WindowManager.swift`
- Modify: `Sources/Snappy/StatusMenuController.swift`
- Modify: `Sources/Snappy/SettingsView.swift`
- Create: `Sources/Snappy/RegionCaptureController.swift` (stub only)

- [ ] **Step 1: Add captureRegion to ShortcutNames.swift**

Add to `KeyboardShortcuts.Name` extension (after `previousDisplay`):
```swift
static let captureRegion = Self("captureRegion")
```

Add `case captureRegion` to `AppAction`:
```swift
enum AppAction {
    case layout(WindowLayout)
    case moveToDisplay(DisplayOrdering.Direction)
    case captureRegion
}
```

Add `Bindings.capture` and update `all`:
```swift
static let capture: [ActionBinding] = [
    .init(name: .captureRegion, title: "Capture Region",
          action: .captureRegion, symbol: "camera.viewfinder"),
]

static var all: [ActionBinding] { layouts + displays + capture }
```

- [ ] **Step 2: Update WindowManager.swift**

Replace the `perform` method so `captureRegion` bypasses the Accessibility check (screen capture doesn't need Accessibility):

```swift
static func perform(_ action: AppAction) {
    switch action {
    case .layout(let layout):
        guard AccessibilityPermission.ensure() else { return }
        apply(layout)
    case .moveToDisplay(let direction):
        guard AccessibilityPermission.ensure() else { return }
        moveToDisplay(direction)
    case .captureRegion:
        RegionCaptureController.shared.start()
    }
}
```

- [ ] **Step 3: Add Capture section to StatusMenuController.swift**

In `buildMenu()`, add this block immediately after `addActionItems(Bindings.displays, to: menu)` and before the separator preceding Settings:

```swift
menu.addItem(.separator())
addActionItems(Bindings.capture, to: menu)
```

The full `buildMenu` body becomes:
```swift
private func buildMenu() -> NSMenu {
    let menu = NSMenu()

    addActionItems(Bindings.layouts, to: menu)
    menu.addItem(.separator())
    addActionItems(Bindings.displays, to: menu)
    menu.addItem(.separator())
    addActionItems(Bindings.capture, to: menu)

    menu.addItem(.separator())
    let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings),
                              keyEquivalent: ",")
    settings.target = self
    settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
    menu.addItem(settings)

    let about = NSMenuItem(title: "About Snappy", action: #selector(showAbout),
                           keyEquivalent: "")
    about.target = self
    about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About Snappy")
    menu.addItem(about)

    menu.addItem(.separator())
    let quitItem = NSMenuItem(title: "Quit Snappy", action: #selector(quit),
                              keyEquivalent: "q")
    quitItem.target = self
    quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit Snappy")
    menu.addItem(quitItem)
    return menu
}
```

- [ ] **Step 4: Add Capture section to SettingsView.swift**

Insert after the "Displays" Section and before the launch-at-login Section:

```swift
Section("Capture") {
    ForEach(Bindings.capture, id: \.name) { binding in
        KeyboardShortcuts.Recorder(binding.title, name: binding.name)
    }
}
```

- [ ] **Step 5: Create RegionCaptureController.swift stub**

```swift
import AppKit

@MainActor
final class RegionCaptureController {
    static let shared = RegionCaptureController()
    private init() {}

    func start() {
        // TODO: implemented in Task 2
        NSLog("Snappy: captureRegion triggered")
    }
}
```

- [ ] **Step 6: Build**

```bash
cd /Users/tony/GitHub/Snappy && swift build 2>&1
```

Expected: compile success, no errors.

- [ ] **Step 7: Commit**

```bash
git add Sources/Snappy/ShortcutNames.swift \
        Sources/Snappy/WindowManager.swift \
        Sources/Snappy/StatusMenuController.swift \
        Sources/Snappy/SettingsView.swift \
        Sources/Snappy/RegionCaptureController.swift
git commit -m "feat: wire captureRegion action into menu, settings, and hotkey system"
```

---

### Task 2: RegionCaptureController — permission check, overlay lifecycle, screen capture

**Files:**
- Modify: `Sources/Snappy/RegionCaptureController.swift`
- Create: `Sources/Snappy/RegionOverlayWindow.swift` (stub)
- Create: `Sources/Snappy/AnnotationEditorController.swift` (stub)

- [ ] **Step 1: Replace RegionCaptureController.swift with full implementation**

```swift
import AppKit

@MainActor
final class RegionCaptureController {
    static let shared = RegionCaptureController()
    private init() {}

    private var overlayWindow: RegionOverlayWindow?

    func start() {
        guard CGPreflightScreenCaptureAccess() else {
            presentPermissionAlert()
            return
        }
        showOverlay()
    }

    private func presentPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
            Snappy needs Screen Recording access to capture your screen.

            Open System Settings \u{25B8} Privacy & Security \u{25B8} Screen Recording \
            and enable Snappy, then try again.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            )
        }
    }

    private func showOverlay() {
        let win = RegionOverlayWindow()
        overlayWindow = win
        win.onRegionSelected = { [weak self] rect in self?.captureRegion(rect) }
        win.onCancelled = { [weak self] in
            self?.overlayWindow?.orderOut(nil)
            self?.overlayWindow = nil
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    // rect is in AppKit global coordinates (y-up, origin = bottom-left of primary screen)
    private func captureRegion(_ rectInAppKit: CGRect) {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        // Wait one frame for the overlay to vanish before capturing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let img = self?.captureScreen(rect: rectInAppKit) else { return }
            AnnotationEditorController.shared.open(image: img)
        }
    }

    private func captureScreen(rect rectInAppKit: CGRect) -> NSImage? {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        // Convert AppKit (y-up) → Quartz global (y-down, origin = top-left of primary)
        let quartzRect = CGRect(
            x: rectInAppKit.minX,
            y: primaryH - rectInAppKit.maxY,
            width: rectInAppKit.width,
            height: rectInAppKit.height
        )

        // Pick the display with the largest overlap
        var bestID = CGMainDisplayID()
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else { continue }
            let area = CGDisplayBounds(id).intersection(quartzRect).area
            if area > bestArea { bestArea = area; bestID = id }
        }

        // Convert Quartz global → display-local (CGDisplayCreateImage expects local coords)
        let displayBounds = CGDisplayBounds(bestID)
        let localRect = CGRect(
            x: quartzRect.minX - displayBounds.minX,
            y: quartzRect.minY - displayBounds.minY,
            width: quartzRect.width,
            height: quartzRect.height
        )

        guard let cgImage = CGDisplayCreateImage(bestID, rect: localRect) else { return nil }
        return NSImage(cgImage: cgImage, size: rectInAppKit.size)
    }
}

private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}
```

- [ ] **Step 2: Create RegionOverlayWindow.swift stub**

```swift
import AppKit

final class RegionOverlayWindow: NSWindow {
    var onRegionSelected: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: .borderless,
                   backing: .buffered, defer: false)
        // Full implementation in Task 3
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
```

- [ ] **Step 3: Create AnnotationEditorController.swift stub**

```swift
import AppKit

@MainActor
final class AnnotationEditorController {
    static let shared = AnnotationEditorController()
    private init() {}

    func open(image: NSImage) {
        // Full implementation in Task 4
        NSLog("Snappy: annotation editor opened with image \(image.size)")
    }
}
```

- [ ] **Step 4: Build**

```bash
swift build 2>&1
```

Expected: compile success.

- [ ] **Step 5: Commit**

```bash
git add Sources/Snappy/RegionCaptureController.swift \
        Sources/Snappy/RegionOverlayWindow.swift \
        Sources/Snappy/AnnotationEditorController.swift
git commit -m "feat: implement RegionCaptureController with permission check and screen capture"
```

---

### Task 3: RegionOverlayWindow — full Phase 1 + Phase 2 UX

**Files:**
- Modify: `Sources/Snappy/RegionOverlayWindow.swift`

This replaces the stub with the complete implementation: borderless overlay covering the virtual desktop, dim overlay, Phase 1 drag-selection, and Phase 2 (resize handles + floating confirm bar).

- [ ] **Step 1: Replace RegionOverlayWindow.swift with complete implementation**

```swift
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
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1
```

Expected: compile success.

- [ ] **Step 3: Manual smoke test**

```bash
./Scripts/bundle.sh && open ./Snappy.app
```

- Click "Capture Region" in the menu bar menu
- If prompted for Screen Recording, grant access and try again
- Drag to select a region → size label should appear above selection
- Release mouse → resize handles and "Cancel | Capture" bar should appear
- Drag a handle to resize; drag inside selection to move
- Press ESC → overlay should dismiss

- [ ] **Step 4: Commit**

```bash
git add Sources/Snappy/RegionOverlayWindow.swift
git commit -m "feat: implement RegionOverlayWindow with Phase 1 selection and Phase 2 resize/confirm UX"
```

---

### Task 4: AnnotationEditorController — window + toolbar + ColorSwatchButton

**Files:**
- Modify: `Sources/Snappy/AnnotationEditorController.swift`
- Create: `Sources/Snappy/AnnotationCanvasView.swift` (stub)

- [ ] **Step 1: Create AnnotationCanvasView.swift stub**

```swift
import AppKit

final class AnnotationCanvasView: NSView {
    private let image: NSImage

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    var activeTool: Int = 0         // segment index: 0=arrow 1=rect 2=circle 3=text
    var activeColor: NSColor = .systemRed
    var activeLineWidth: CGFloat = 3

    @objc func changeTool(_ sender: NSSegmentedControl) { activeTool = sender.selectedSegment }
    @objc func changeWidth(_ sender: NSStepper) { activeLineWidth = CGFloat(sender.intValue) }
    @objc func undoLast() {}
    @objc func copyToClipboard() {}
    @objc func saveImage() {}

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
    }
}
```

- [ ] **Step 2: Replace AnnotationEditorController.swift with full implementation**

```swift
import AppKit

// MARK: - Color swatch button

final class ColorSwatchButton: NSButton {
    let swatchColor: NSColor

    var isActive: Bool = false {
        didSet { needsDisplay = true }
    }

    init(color: NSColor, label: String) {
        self.swatchColor = color
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if isActive {
            // White ring + inset color circle to indicate active
            NSColor.white.setFill()
            NSBezierPath(ovalIn: bounds).fill()
            swatchColor.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).fill()
        } else {
            swatchColor.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
    }
}

// MARK: - Editor controller

@MainActor
final class AnnotationEditorController {
    static let shared = AnnotationEditorController()
    private init() {}

    private var window: NSWindow?
    private var canvas: AnnotationCanvasView?
    private var swatchButtons: [ColorSwatchButton] = []

    func open(image: NSImage) {
        // Scale image to fit visible screen, never upscale
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let maxSize = screen.visibleFrame.insetBy(dx: 40, dy: 40).size
        let scale = min(maxSize.width / image.size.width,
                        maxSize.height / image.size.height, 1.0)
        let displaySize = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )

        let canvasView = AnnotationCanvasView(image: image)
        canvasView.frame = CGRect(origin: .zero, size: displaySize)
        self.canvas = canvasView

        let toolbarH: CGFloat = 52
        let winSize = CGSize(width: displaySize.width,
                             height: displaySize.height + toolbarH)
        let win = NSWindow(
            contentRect: CGRect(origin: .zero, size: winSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Snappy \u{2014} Annotate"
        win.isReleasedWhenClosed = false

        let content = NSView(frame: CGRect(origin: .zero, size: winSize))
        win.contentView = content

        canvasView.autoresizingMask = [.width, .height]
        content.addSubview(canvasView)

        let toolbar = buildToolbar(width: displaySize.width, canvas: canvasView)
        toolbar.frame = CGRect(x: 0, y: displaySize.height,
                               width: displaySize.width, height: toolbarH)
        toolbar.autoresizingMask = [.width, .minYMargin]
        content.addSubview(toolbar)

        self.window = win
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func buildToolbar(width: CGFloat, canvas: AnnotationCanvasView) -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Bottom border
        let sep = NSBox()
        sep.boxType = .separator
        sep.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        sep.autoresizingMask = .width
        bar.addSubview(sep)

        var x: CGFloat = 12

        // Tool selector (arrow / rect / circle / text)
        let toolImages: [NSImage] = [
            NSImage(systemSymbolName: "arrow.up.right",         accessibilityDescription: "Arrow")!,
            NSImage(systemSymbolName: "rectangle",             accessibilityDescription: "Rectangle")!,
            NSImage(systemSymbolName: "circle",                accessibilityDescription: "Circle")!,
            NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: "Text")!,
        ]
        let toolCtrl = NSSegmentedControl(
            images: toolImages, trackingMode: .selectOne,
            target: canvas, action: #selector(AnnotationCanvasView.changeTool(_:))
        )
        toolCtrl.selectedSegment = 0
        toolCtrl.frame = CGRect(x: x, y: 11, width: 140, height: 30)
        bar.addSubview(toolCtrl)
        x += 152

        addVSep(to: bar, at: x); x += 16

        // 5 color swatches
        swatchButtons = []
        let swatches: [(NSColor, String)] = [
            (.systemRed, "Red"), (.systemOrange, "Orange"),
            (.systemYellow, "Yellow"), (.systemGreen, "Green"), (.systemBlue, "Blue"),
        ]
        for (color, label) in swatches {
            let btn = ColorSwatchButton(color: color, label: label)
            btn.frame = CGRect(x: x, y: 15, width: 22, height: 22)
            btn.target = self
            btn.action = #selector(swatchClicked(_:))
            bar.addSubview(btn)
            swatchButtons.append(btn)
            x += 28
        }
        swatchButtons.first?.isActive = true
        x += 4

        addVSep(to: bar, at: x); x += 16

        // Line width: label + stepper
        let wLabel = NSTextField(labelWithString: "Width:")
        wLabel.frame = CGRect(x: x, y: 18, width: 44, height: 17)
        bar.addSubview(wLabel)
        x += 48

        let stepper = NSStepper()
        stepper.minValue = 1; stepper.maxValue = 12; stepper.intValue = 3
        stepper.frame = CGRect(x: x, y: 13, width: 19, height: 26)
        stepper.target = canvas
        stepper.action = #selector(AnnotationCanvasView.changeWidth(_:))
        bar.addSubview(stepper)
        x += 28

        addVSep(to: bar, at: x); x += 16

        // Action buttons
        for (title, action) in [
            ("Undo",  #selector(AnnotationCanvasView.undoLast)),
            ("Copy",  #selector(AnnotationCanvasView.copyToClipboard)),
            ("Save\u{2026}", #selector(AnnotationCanvasView.saveImage)),
        ] as [(String, Selector)] {
            let btn = NSButton(title: title, target: canvas, action: action)
            btn.bezelStyle = .rounded
            btn.frame = CGRect(x: x, y: 12, width: 62, height: 28)
            bar.addSubview(btn)
            x += 70
        }

        return bar
    }

    @objc private func swatchClicked(_ sender: NSButton) {
        guard let swatch = sender as? ColorSwatchButton else { return }
        canvas?.activeColor = swatch.swatchColor
        swatchButtons.forEach { $0.isActive = ($0 === swatch) }
    }

    private func addVSep(to view: NSView, at x: CGFloat) {
        let sep = NSBox()
        sep.boxType = .separator
        sep.frame = CGRect(x: x, y: 8, width: 1, height: 36)
        view.addSubview(sep)
    }
}
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1
```

Expected: compile success.

- [ ] **Step 4: Quick functional smoke test**

```bash
./Scripts/bundle.sh && open ./Snappy.app
```

Use "Capture Region", drag to select, click Capture → the annotation editor window should open showing the captured screenshot. The toolbar should be visible at the top with tool segments, 5 color swatches, stepper, and Undo/Copy/Save buttons. Canvas should fill the rest of the window.

- [ ] **Step 5: Commit**

```bash
git add Sources/Snappy/AnnotationEditorController.swift \
        Sources/Snappy/AnnotationCanvasView.swift
git commit -m "feat: implement AnnotationEditorController with toolbar and ColorSwatchButton"
```

---

### Task 5: AnnotationCanvasView — arrow, rectangle, and circle tools

**Files:**
- Modify: `Sources/Snappy/AnnotationCanvasView.swift`

- [ ] **Step 1: Replace AnnotationCanvasView.swift with arrow + rect + circle implementation**

```swift
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

        // 3. Draw in-progress preview
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

        // Arrowhead triangle
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

    // MARK: - Toolbar actions (called by AnnotationEditorController toolbar)

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
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1
```

Expected: compile success.

- [ ] **Step 3: Manual test — arrow tool**

```bash
./Scripts/bundle.sh && open ./Snappy.app
```

- Trigger Capture Region → select area → click Capture
- In the editor: drag across the image → an arrow with a filled head should appear
- Switch color swatch → new arrows should use that color
- Adjust width stepper → arrows should be thicker/thinner
- Click Undo → last arrow disappears

- [ ] **Step 4: Manual test — rect and circle tools**

- Select the Rectangle segment → drag → a rectangle outline should appear
- Select the Circle segment → drag → an ellipse outline should appear
- Both should respect the active color and line width

- [ ] **Step 5: Manual test — text tool**

- Select the Text (T) segment → click anywhere on image → an input field appears
- Type some text → press Return → text appears at click position in active color
- Click Undo → text disappears

- [ ] **Step 6: Manual test — export**

- Annotate with several shapes
- Click Copy → paste in Preview or TextEdit → annotated image should appear
- Click Save… → NSSavePanel appears → save as PNG → verify file is correct

- [ ] **Step 7: Commit**

```bash
git add Sources/Snappy/AnnotationCanvasView.swift
git commit -m "feat: implement AnnotationCanvasView with arrow, rect, circle, text, undo, and export"
```

---

### Task 6: Integration build + bundle verification

**Files:** None (verification only)

- [ ] **Step 1: Run unit tests (SnappyCore — unaffected, should still pass)**

```bash
swift test 2>&1
```

Expected: all tests pass. (SnappyCore tests cover layout math, not UI.)

- [ ] **Step 2: Full release build**

```bash
./Scripts/bundle.sh 2>&1
```

Expected: `Snappy.app` assembled with no errors.

- [ ] **Step 3: End-to-end manual test checklist**

Open the app and verify each item:

```
[ ] "Capture Region" appears in the menu bar menu (with camera.viewfinder icon)
[ ] "Capture Region" appears in Settings under a "Capture" section with a shortcut recorder
[ ] If Screen Recording permission is absent: triggering capture shows a guidance alert with "Open System Settings" button
[ ] Phase 1: dragging on screen shows dim overlay + live selection box + W × H label
[ ] Phase 2: releasing mouse shows 8 handles + floating "Cancel | Capture" bar
[ ] Handles resize the selection; dragging inside moves it
[ ] ESC dismisses the overlay
[ ] Cancel button dismisses the overlay
[ ] Capture button opens the editor window with the captured region
[ ] Arrow tool: drag → filled arrowhead at endpoint, shaft from start
[ ] Rectangle tool: drag → rectangle outline
[ ] Circle tool: drag → ellipse outline inscribed in drag area
[ ] Text tool: click → text field appears; Return commits; text drawn at click position
[ ] 5 color swatches: red/orange/yellow/green/blue; active swatch has white ring
[ ] Width stepper (1-12): changes line width for subsequent annotations
[ ] Undo: removes most recent annotation (can undo all the way to empty)
[ ] Copy: pastes annotated screenshot into clipboard
[ ] Save…: NSSavePanel opens; saves PNG with timestamp name
[ ] Window can be closed and reopened (capture again)
```

- [ ] **Step 4: Commit any final tweaks found during testing, then tag the feature**

```bash
git add -p  # stage only intentional changes
git commit -m "feat: region capture + annotation — complete feature integration"
```

---

## Self-Review

### Spec coverage check

| Spec requirement | Covered by task |
|---|---|
| Trigger via hotkey + menu item | Task 1 |
| `AppAction.captureRegion` pattern | Task 1 |
| Status menu section between displays and Settings | Task 1 |
| Settings "Capture" section with Recorder | Task 1 |
| `CGPreflightScreenCaptureAccess()` check + alert | Task 2 |
| Open System Settings on alert button | Task 2 |
| 50ms delay before capture | Task 2 |
| `CGDisplayCreateImage` (non-deprecated) | Task 2 |
| Multi-display: pick display by largest overlap | Task 2 |
| AppKit → Quartz coordinate conversion | Task 2 |
| Borderless window, `.screenSaver` level | Task 3 |
| `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]` | Task 3 |
| Virtual desktop coverage (all screens union) | Task 3 |
| Phase 1: 35% alpha dim + `cgContext.clear` | Task 3 |
| Phase 1: white 1.5pt border | Task 3 |
| Phase 1: W × H size label, flips above/below | Task 3 |
| Phase 1: crosshair cursor | Task 3 |
| Phase 2: 8 resize handles | Task 3 |
| Phase 2: resize by dragging handles | Task 3 |
| Phase 2: move by dragging inside selection | Task 3 |
| Phase 2: contextual cursors | Task 3 |
| Phase 2: floating Cancel | Capture bar, dark pill | Task 3 |
| ESC to cancel | Task 3 |
| Dragging outside → starts new selection | Task 3 |
| Editor window sizing (capped at visible frame − 40pt) | Task 4 |
| Toolbar layout (tool selector, swatches, stepper, buttons) | Task 4 |
| 5 color swatches (red/orange/yellow/green/blue) | Task 4 |
| Active swatch white ring | Task 4 |
| `NSSegmentedControl` for tool selector | Task 4 |
| `NSStepper` width 1–12 default 3 | Task 4 |
| Arrow tool: shaft + filled arrowhead, head = width × 4.5 | Task 5 |
| Rectangle: stroke only, `NSBezierPath(rect:)` | Task 5 |
| Circle: stroke only, `NSBezierPath(ovalIn:)` | Task 5 |
| Text: `NSTextField` overlay → commit → `NSString.draw` | Task 5 |
| `acceptsFirstMouse` | Task 5 |
| Live preview during drag | Task 5 |
| Undo: `removeLast`, unlimited | Task 5 |
| Copy: `bitmapImageRepForCachingDisplay` → `NSPasteboard` | Task 5 |
| Save: `NSSavePanel`, PNG, timestamp filename | Task 5 |

All spec requirements are covered.

### Type/name consistency check

- `AnnotationTool` enum defined in Task 5 with cases `.arrow, .rect, .circle, .text` — matches usage in `drawAnnotation`, `mouseUp`, `changeTool`.
- `Annotation` enum defined in Task 5 with `.arrow, .rect, .circle, .text` — matches `drawAnnotation` switch.
- `ColorSwatchButton.swatchColor: NSColor` — set in init, read in `swatchClicked` and `draw`.
- `AnnotationEditorController.swatchClicked` sets `canvas?.activeColor = swatch.swatchColor` — `activeColor` is defined on `AnnotationCanvasView`.
- `changeTool(_:)`, `changeWidth(_:)`, `undoLast`, `copyToClipboard`, `saveImage` — all defined on `AnnotationCanvasView`, all referenced in toolbar setup in `AnnotationEditorController`.
- `RegionOverlayWindow.onRegionSelected: ((CGRect) -> Void)?` — called from `fireCapture`, received in `RegionCaptureController.showOverlay`.
- `RegionCaptureController.captureRegion(_:)` calls `AnnotationEditorController.shared.open(image:)` — matches the function signature in Task 4.
