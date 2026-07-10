# Box Editing UX Redesign

## Context

Hands-on labeling revealed several friction points in box editing:

- Moving or resizing a selected box feels too fast after zooming in.
- The selected box only has one resize handle, so resizing from the top, left,
  or corners is awkward.
- The selected-box delete action is buried in the right inspector and may
  require scrolling when the image has many boxes.
- The selected box changes to a yellow outline, which hides the semantic color
  of the box: gray for proposals and the label color for labeled boxes.

This design improves the direct manipulation feel of the annotation canvas
without changing project data semantics or COCO export.

## Goals

- Make move and resize gestures feel consistent at every zoom level.
- Add eight resize anchors for selected boxes.
- Make selected-box deletion immediately reachable from the center toolbar.
- Keep selected boxes visually tied to their original proposal or label color.
- Preserve original-image pixel coordinates for all saved boxes.
- Keep Delete and Backspace shortcuts working.

## Non-Goals

- Do not add polygon, segmentation, rotation, or freeform editing.
- Do not change COCO export behavior.
- Do not add a floating mini-toolbar over the image in this iteration.
- Do not add custom keyboard shortcut settings.

## Zoom-Correct Editing

Move and resize gestures must be based on original image coordinates, not raw
screen deltas.

Current behavior divides pointer deltas by the fitted image scale. This is not
enough once the `InteractiveViewer` transform has zoomed the canvas, because the
same physical mouse delta should represent a smaller original-image movement at
higher zoom levels.

Preferred behavior:

1. On drag start, capture the selected box's original coordinates.
2. On drag start, convert the pointer position to original image coordinates.
3. On drag update, convert the current pointer position to original image
   coordinates using the same display transform and current zoom.
4. Compute `originalDelta = currentOriginalPointer - startOriginalPointer`.
5. Apply that delta to the captured start box.

This makes moving and resizing consistent:

- At 100% zoom, dragging 10 screen pixels moves roughly 10 displayed pixels.
- At 200% zoom, dragging 10 screen pixels changes original coordinates by half
  as much.
- At 400% zoom, fine adjustment becomes easier rather than faster.

## Eight Resize Anchors

When a box is selected, show eight resize anchors:

```text
top-left     top     top-right
left                 right
bottom-left  bottom  bottom-right
```

Anchor behavior:

- `topLeft`: moves left and top; keeps right and bottom fixed.
- `top`: moves top; keeps bottom fixed.
- `topRight`: moves right and top; keeps left and bottom fixed.
- `left`: moves left; keeps right fixed.
- `right`: moves right; keeps left fixed.
- `bottomLeft`: moves left and bottom; keeps right and top fixed.
- `bottom`: moves bottom; keeps top fixed.
- `bottomRight`: moves right and bottom; keeps left and top fixed.

Rules:

- A box must never leave the image bounds.
- A box must never become smaller than the existing minimum box size.
- Dragging a handle past the opposite side clamps at the minimum size instead
  of flipping the box.
- Handle hit targets must be large enough to use with a mouse.
- Handle visual size should remain stable on screen when zoom changes.

## Selected Box Delete Action

The selected-box delete action should be available in the center action toolbar,
not only at the bottom of the right inspector.

Toolbar layout:

```text
[자동 박스] [박스 전체 삭제] [선택 박스 삭제]
[선택] [박스 그리기] [이동] [축소] [맞춤] [원본 크기] [확대]
```

Rules:

- `선택 박스 삭제` is enabled only when a box is selected.
- It calls the same delete action as Delete and Backspace.
- It must support undo through the existing undo stack.
- The right inspector may keep selected-box coordinates, but the duplicate
  delete button can be removed to avoid hiding the primary action in a scroll
  area.

## Selected Box Visual Style

Selection should not replace the box's semantic color with yellow.

Base colors:

- Proposal boxes use gray.
- Labeled boxes use their label color.
- Invalid boxes continue to use an error color if present.

Unselected style:

- Thin stroke using the base color.
- Very light fill using the base color.

Selected style:

- Thicker stroke using the same base color.
- Slightly stronger transparent fill using the same base color.
- Eight resize anchors using the same base color with a contrasting border.
- No yellow outline for normal selection.

The user should be able to identify both:

- Which box is selected.
- Whether the box is a gray proposal or a labeled box with a class color.

## Data Semantics

- Project data still stores original image pixel coordinates.
- Movement and resizing update `x`, `y`, `width`, and `height` only.
- Box ids, label ids, status, and confidence are unchanged by resize/move.
- Deleted boxes continue to use the existing delete and undo behavior.

## Error Handling

- If a drag update arrives after the selected box is deleted, ignore it.
- If the image dimensions are invalid, do not create or resize boxes.
- Clamp calculations must prevent negative width or height.
- Undo should restore the exact previous selected image state.

## Testing

Unit tests:

- Convert pointer drag deltas through zoom so zoomed editing changes original
  coordinates proportionally.
- Resizing from each of the eight anchors changes the expected sides.
- Resizing clamps to image bounds.
- Resizing clamps at the minimum box size instead of flipping.

Widget tests:

- A selected box renders eight resize handles.
- Dragging a zoomed selected box moves it less in original coordinates than the
  same screen drag at unzoomed scale.
- Dragging `topLeft`, `top`, `left`, `right`, `bottom`, and corner handles
  updates the expected coordinates.
- The center action toolbar shows `선택 박스 삭제`.
- `선택 박스 삭제` is disabled with no selected box and enabled when a box is
  selected.
- Clicking `선택 박스 삭제` removes the selected box immediately.
- The selected box keeps its proposal or label color rather than turning yellow.

Manual checks:

- Zoom in strongly and move a box by a small amount.
- Zoom in strongly and resize from each handle.
- Verify selected proposal boxes remain gray and selected labeled boxes remain
  their label color.
- Verify deletion is reachable without scrolling the right inspector.
- Verify Undo restores a deleted box.

## Acceptance Criteria

- Box move and resize gestures feel consistent across zoom levels.
- A selected box has eight usable resize anchors.
- The center action toolbar includes an immediately visible selected-box delete
  action.
- Selected boxes use stronger versions of their original color instead of a
  yellow selection outline.
- Box coordinates remain valid original-image pixel coordinates after move,
  resize, delete, undo, save, and export.
