# Region Capture + Annotation — Design Spec

**Date:** 2026-07-10  
**Status:** Approved (v2)

---

## Overview

Add a "Capture Region" action to Snappy that lets the user drag-select an area of the screen with macOS-native capture UX, then annotate the captured image with arrows, rectangles, circles, and text labels before copying to clipboard or saving to disk.

---

## Trigger

Follows the existing `ActionBinding` pattern exactly:

- Added to `ShortcutNames.swift` as `static let captureRegion = Self("captureRegion")` (no default shortcut — user assigns in Settings)
- New `AppAction` case: `case captureRegion`
- New `Bindings.capture: [ActionBinding]` array (single entry), included in `Bindings.all`
- `WindowManager.perform(.captureRegion)` dispatches to `RegionCaptureController.shared.start()`
- Appears in the status menu as a new section (with separator) between display-move actions and Settings
- Appears in Settings under a new "Capture" section with a `KeyboardShortcuts.Recorder`

---

## Architecture — New Files

### `RegionCaptureController.swift`
Singleton (`@MainActor`). Orchestrates the full capture flow:

1. Check `CGPreflightScreenCaptureAccess()`. If denied, show an alert (same pattern as `AccessibilityPermission`) linking to **System Settings › Privacy & Security › Screen Recording**.
2. Instantiate and show `RegionOverlayWindow`.
3. On region confirmed: hide overlay → wait 50 ms for compositor flush → call `CGDisplayCreateImage` → hand `NSImage` to `AnnotationEditorController.shared.open(image:)`.
4. On cancelled: discard overlay, do nothing.

**Capture implementation:** `CGDisplayCreateImage(displayID, rect:)` — not deprecated, requires no entitlements for non-sandboxed apps. Selects the display that contains the largest area of the selection rect. Converts AppKit (y-up) to Quartz (y-down) coordinates before calling.

---

### `RegionOverlayWindow.swift`
Two classes in one file.

**`RegionOverlayWindow: NSWindow`**
- `styleMask: .borderless`, `backgroundColor: .clear`, `isOpaque: false`
- `level: .screenSaver` (above all other windows)
- `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]`
- `contentRect`: union of all `NSScreen.screens` frames (covers virtual desktop for multi-display)
- `canBecomeKey: true`

**`RegionOverlayView: NSView`** — macOS Screenshot-style UX:

**Phase 1 — Selection (before mouse up):**
- Crosshair cursor everywhere
- Dark 35% alpha dim over entire view
- `cgContext.clear(selectionRect)` to reveal content beneath selection
- White 1.5pt border around selection
- Size label (`W × H` in monospaced 11pt, pill background) above selection, flips below if near top edge

**Phase 2 — Confirm (after mouse up, before capture):**
- Selection remains visible with dim surround
- **8 resize handles** rendered as white circles at corners + edge midpoints
- Cursor changes contextually:
  - Inside selection → move cursor (4-arrow)
  - On a handle → appropriate resize cursor (NW/N/NE/E etc.)
  - Outside selection → crosshair (start new selection)
- User can drag handles to resize or drag inside selection to move
- **Floating confirm bar** centred below selection (flips above if near bottom): `Cancel` | `Capture` buttons, dark pill background, ~200pt wide
- Clicking **Capture**: fires `onRegionSelected` with final rect
- Clicking **Cancel** or pressing **ESC** at any point: fires `onCancelled`
- Dragging outside current selection → starts a new selection (replaces current)

**Coordinate conversion on confirm:** view-local rect → AppKit global coords by adding `windowOrigin` (the virtual desktop origin).

---

### `AnnotationEditorController.swift`
Singleton (`@MainActor`). Creates and owns the editor `NSWindow`:

- Window size = image size capped at `screen.visibleFrame − 40pt padding`; image displayed 1:1 if it fits, scaled down uniformly otherwise
- `styleMask: [.titled, .closable, .miniaturizable]`, `isReleasedWhenClosed: false`
- Layout: toolbar (52pt, pinned to top) + `AnnotationCanvasView` filling the rest
- Toolbar built by `AnnotationToolbar` helper (private type in the same file)

---

### `AnnotationCanvasView.swift`
`NSView` subclass owning all drawing and annotation state.

**Annotation model:**
```swift
enum Annotation {
    case arrow(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat)
    case rect(rect: CGRect, color: NSColor, width: CGFloat)
    case circle(rect: CGRect, color: NSColor, width: CGFloat)   // inscribed in drag rect
    case text(origin: CGPoint, string: String, color: NSColor, fontSize: CGFloat)
}
```

**Drawing (`draw(_:)`):**
1. `image.draw(in: bounds, …, operation: .copy)` — image fills canvas
2. Each committed `Annotation` drawn with `NSBezierPath`
3. In-progress annotation drawn as a live preview while dragging

**Tool rendering:**
- **Arrow:** rounded-cap shaft + filled arrowhead triangle at endpoint; head length = `lineWidth × 4.5`
- **Rectangle:** `NSBezierPath(rect:)`, stroke only (no fill)
- **Circle:** `NSBezierPath(ovalIn:)`, stroke only (no fill)
- **Text:** `NSString.draw(at:withAttributes:)` with system bold font at chosen size; click places a temporary `NSTextField` overlay, `Return`/`Tab`/click-outside commits to annotations array

**Mouse events:**
- `acceptsFirstMouse(for:) → true`
- `mouseDown` / `mouseDragged` / `mouseUp` behaviour determined by active tool
- Events suppressed while text `NSTextField` is active

**Undo:** `annotations.removeLast()` — unlimited depth, no redo.

**Export:**
- *Copy:* `bitmapImageRepForCachingDisplay(in: bounds)` → `NSPasteboard.general.writeObjects([NSImage])`
- *Save:* `NSSavePanel` (`.png`), default name `screenshot-<unix-timestamp>.png`

---

### Toolbar layout (inside `AnnotationEditorController.swift`)

```
┌──────────────────────────────────────────────────────────────────┐
│ [→][□][○][T]  │  ● ● ● ● ●  │  ━━ [−][+]  │  Undo  │  Copy  Save │
└──────────────────────────────────────────────────────────────────┘
  tool selector    color swatches  line width      actions
```

**Color swatches:** 5 filled circles (18pt diameter), colours: red, orange, yellow, green, blue. Clicking a swatch sets the active colour for all tools. Active swatch has a white 2pt ring.

**Tool selector:** `NSSegmentedControl` with 4 segments — Arrow (`→`), Rectangle (`□`), Circle (`○`), Text (`T`).

**Line width:** `NSStepper` (range 1–12, default 3), shared across all tools.

**Buttons:** `Undo`, `Copy`, `Save…` — `NSButton` with `.rounded` bezel style.

---

## Modified Files

| File | Change |
|---|---|
| `ShortcutNames.swift` | Add `captureRegion` `Name`, `AppAction.captureRegion`, `Bindings.capture` |
| `WindowManager.swift` | Add `case .captureRegion` → `RegionCaptureController.shared.start()` |
| `StatusMenuController.swift` | Add `addActionItems(Bindings.capture, to: menu)` with separator |
| `SettingsView.swift` | Add `Section("Capture")` with `KeyboardShortcuts.Recorder` for `captureRegion` |

---

## Permissions

Screen Recording (TCC) required for `CGDisplayCreateImage`. No `Info.plist` key needed for non-sandboxed apps — macOS prompts automatically on first use. `RegionCaptureController` proactively checks with `CGPreflightScreenCaptureAccess()` and shows a guidance alert if denied.

No entitlements file changes needed.

---

## Out of Scope (v1)

- Redo (only undo via `removeLast`)
- Highlight / blur tool
- Resizing or moving committed annotations
- Copy-on-capture shortcut (no annotation step)
- Magnifier/loupe at cursor during selection
