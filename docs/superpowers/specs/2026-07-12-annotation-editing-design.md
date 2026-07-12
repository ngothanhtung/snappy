# Annotation editing: select, move, restyle, arrow styles

Date: 2026-07-12
Status: approved

## Goal

Extend the Annotate editor so annotations remain editable after drawing:

1. Move arrows, rectangles, circles, and labels after they are drawn.
2. Change color and size (stroke width; font size for labels) after drawing.
3. Arrows support multiple styles: `→` (head), `↔` (head + tail), `—` (plain
   line), `●→` (dot tail + head).

## Decisions (confirmed with user)

- Selection uses a dedicated **Select** tool (new first segment in the tool
  picker), not click-to-select in drawing modes.
- Color / width / arrow-style controls apply to **both** the selected
  annotation and the defaults for new annotations.
- Arrow style set: the 4 styles above, chosen from an `NSPopUpButton` in the
  toolbar.

## Model

`Annotation` changes from an enum to a struct so style fields are mutable:

```swift
enum ArrowStyle: Int { case head, both, line, dotTail }
struct Annotation {
    enum Shape {
        case arrow(from: CGPoint, to: CGPoint, style: ArrowStyle)
        case rect(CGRect)
        case circle(CGRect)
        case text(origin: CGPoint, string: String)
    }
    var shape: Shape
    var color: NSColor
    var width: CGFloat
}
```

Labels derive their font size from `width`: `fontSize = 10 + 2 × width`
(default width 3 → 16 pt, matching current behavior).

## Interaction

- **Select mode**: mouseDown hit-tests annotations topmost-first. Hit rules:
  arrow = distance to segment ≤ max(width/2 + 4, 8); rect/circle = point
  inside the shape's rect outset by 4 pt; label = inside its text bounding
  box. Dragging moves the annotation. Click on empty space or **Esc**
  deselects; **Delete/Backspace** removes the selection.
- Selected annotation is drawn with a dashed accent-color bounding box.
  This chrome is skipped during `renderToImage()` so Copy/Save output stays
  clean.
- Switching tools deselects.
- Swatch / width stepper / arrow-style popup: update the selected annotation
  (if any) *and* the defaults for new annotations.

## Undo

The undo stack becomes an array of `[Annotation]` snapshots. Every mutation
(add, move, restyle, delete) pushes the prior state; Undo pops one snapshot.
This replaces the previous "remove last annotation" behavior, which cannot
express undoing a move or restyle.

## SnappyCore

Pure hit-test geometry moves to `SnappyCore` (`AnnotationGeometry`), unit
tested: distance from point to line segment, point-in-ellipse.

## Addendum (same day): stamps, steps, sharper arrowheads

- **Arrowheads**: half-angle narrowed 30° → 20°, length `max(6 × width, 14)`,
  and the shaft stops at the head's base so its round cap no longer blunts
  the tip.
- **Stamp tool**: click places the emoji chosen in a toolbar popup
  (✅ ❌ ⚠️ ❗ 👉 ⭐ 🔥 💡 🐛 ❓); size follows the width control
  (`12 + 8 × width`). Changing the popup with a stamp selected swaps its emoji.
- **Step tool**: click places a filled circle (active color) with a white
  auto-incrementing number (max existing + 1); diameter `16 + 4 × width`.
- Both are ordinary annotations: selectable, movable, recolorable (steps),
  resizable via width, and covered by snapshot undo.

## Toolbar

`Select | Arrow | Rect | Circle | Label` segmented control, arrow-style popup
after the tool picker, existing swatches / width / Undo / Copy / Save
unchanged. `minimumToolbarWidth` grows to fit the two new controls.
