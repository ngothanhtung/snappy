# Region Capture + Annotation — Design Spec

**Date:** 2026-07-10  
**Status:** Approved

---

## Overview

Add a "Capture Region" action to Snappy that lets the user drag-select an area of the screen, then annotate the captured image with arrows, rectangles, and text labels before copying to clipboard or saving to disk.

---

## Trigger

Follows the existing `ActionBinding` pattern exactly:

- Added to `ShortcutNames.swift` as `static let captureRegion = Self("captureRegion")` (no default shortcut — user assigns in Settings)
- New `AppAction` case: `case captureRegion`
- New `Bindings.capture: [ActionBinding]` array (single entry), added to `Bindings.all`
- `WindowManager.perform(.captureRegion)` dispatches to `RegionCaptureController.shared.start()`
- Appears in the status menu as a new section (with separator) between the display-move actions and Settings
- Appears in Settings under a new "Capture" section with a `KeyboardShortcuts.Recorder`

---

## Architecture — New Files

### `RegionCaptureController.swift`
Singleton (`@MainActor`). Orchestrates the full capture flow:

1. Check `CGPreflightScreenCaptureAccess()`. If denied, show an alert (same pattern as `AccessibilityPermission`) that opens **System Settings › Privacy & Security › Screen Recording**.
2. Instantiate and show `RegionOverlayWindow`.
3. On region selected: hide overlay → wait 50 ms for compositor flush → call `CGDisplayCreateImage` → hand `NSImage` to `AnnotationEditorController.shared.open(image:)`.
4. On cancelled: discard overlay, do nothing.

**Capture implementation:** `CGDisplayCreateImage(displayID, rect:)` — not deprecated, no additional entitlements needed for non-sandboxed apps. Selects the display that contains the largest area of the selection rect (handles multi-monitor). Converts AppKit (y-up) coordinates to Quartz (y-down) coordinates before calling.

### `RegionOverlayWindow.swift`
Two classes in one file:

**`RegionOverlayWindow: NSWindow`**
- `styleMask: .borderless`, `backgroundColor: .clear`, `isOpaque: false`
- `level: .screenSaver` (above all other windows)
- `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]`
- `contentRect`: union of all `NSScreen.screens` frames (virtual desktop)
- `canBecomeKey: true`

**`RegionOverlayView: NSView`**
- Crosshair cursor via `resetCursorRects`
- `acceptsFirstResponder: true`; `cancelOperation(_:)` → fires `onCancelled`
- `mouseDown` / `mouseDragged` / `mouseUp` → tracks `startPoint` + `selectionRect`
- `draw(_:)`:
  - Black 35% alpha fill over entire bounds
  - `cgContext.clear(selectionRect)` to reveal the screen beneath
  - White 1.5pt border around selection
  - Size label (`W × H`) in monospaced 11pt, pill background, positioned above selection (flips below if near top edge)
- `mouseUp` with rect < 5×5 pt: no-op (accidental click)
- On valid `mouseUp`: converts view-local rect → AppKit global coords (add `windowOrigin`) → fires `onRegionSelected`

### `AnnotationEditorController.swift`
Singleton (`@MainActor`). Creates and owns the editor `NSWindow`:

- Window size = `min(image.size, screen.visibleFrame − 40pt padding)` — image is shown at 1:1 if it fits, otherwise scaled down uniformly
- `styleMask: [.titled, .closable, .miniaturizable]`, `isReleasedWhenClosed: false`
- Layout: toolbar (48pt, pinned top) + `AnnotationCanvasView` (fills remainder)
- Toolbar contains: tool segment control, `NSColorWell`, line-width `NSStepper` (1–12), Undo button, Copy button, Save button

### `AnnotationCanvasView.swift`
`NSView` subclass. Owns all drawing state.

**Annotation model:**
```swift
enum Annotation {
    case arrow(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat)
    case rect(rect: CGRect, color: NSColor, width: CGFloat)
    case text(origin: CGPoint, string: String, color: NSColor, fontSize: CGFloat)
}
```

**Drawing (`draw(_:)`):**
1. `image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)` — image fills canvas
2. For each committed `Annotation`, draw with `NSBezierPath`
3. For the in-progress annotation (currentStart + currentEnd), draw a preview

**Arrow rendering:** shaft with `lineCapStyle: .round`; filled arrowhead triangle at the endpoint; head length = `lineWidth × 4.5`.

**Rectangle rendering:** `NSBezierPath(rect:)`, stroke only, no fill.

**Text rendering:** `NSString.draw(at:withAttributes:)` with system font at chosen size.

**Text tool flow:** `mouseDown` → place an `NSTextField` overlay at click point → user types → on `Return` or `Tab` or click-outside, commit as `.text(...)` annotation and remove the field.

**Mouse events:**
- `acceptsFirstMouse(for:) → true`
- `mouseDown` / `mouseDragged` / `mouseUp` — behaviour depends on active tool
- Ignores events while a text field is active

**Undo:** `annotations.removeLast()` — unlimited depth.

**Export:**
- *Copy:* `bitmapImageRepForCachingDisplay(in: bounds)` → `NSPasteboard.general.writeObjects([NSImage])`
- *Save:* `NSSavePanel` (`.png`), default name `screenshot-<unix-timestamp>.png`, `NSBitmapImageRep.representation(using: .png)`

---

## Modified Files

| File | Change |
|---|---|
| `ShortcutNames.swift` | Add `captureRegion` `Name`, `AppAction.captureRegion`, `Bindings.capture` |
| `WindowManager.swift` | Add `case .captureRegion` dispatching to `RegionCaptureController` |
| `StatusMenuController.swift` | Add `addActionItems(Bindings.capture, to: menu)` section with separator |
| `SettingsView.swift` | Add `Section("Capture")` with recorder for `captureRegion` |

---

## Permissions

Screen Recording (TCC) is required for `CGDisplayCreateImage`. For non-sandboxed apps, no `Info.plist` key is needed — macOS prompts automatically. `RegionCaptureController` proactively checks with `CGPreflightScreenCaptureAccess()` and shows a guidance alert (mirroring `AccessibilityPermission`) if denied.

No entitlements file changes needed.

---

## Out of Scope (v1)

- Undo history beyond `removeLast` (no redo)
- Highlighting / blur tool
- Multi-display spanning selections (captures the display with the largest intersection)
- Resizing/moving committed annotations
- Copy-on-capture (no annotation) shortcut
