# Overlay Handle And Z-Order Design

## Goal

Improve selected bounding box editing so it matches the expectations of image annotation and design tools:

- Resize anchors should be visually careful, stable, and centered on the box edge or corner they control.
- Anchors should keep the same square shape at every zoom level.
- Box labels should stay fixed to the box's screen coordinate, even when selection changes stroke width.
- Overlay layering should be explicit: box fill, stroke, label, then anchors.

## Current Problems

The current selected overlay places resize handles fully inside the box. This avoids Flutter hit-test clipping, but it makes the actual resize reference point look offset from the box boundary.

The handle visual size is divided by zoom and clamped. At high zoom, the visual size can become small enough that the fixed border radius makes the handle read as round instead of square.

The label is rendered as a child inside the bordered box container. When selected state changes border width, the label can appear to shift because it participates in the decorated container's internal layout.

The selected box is rendered in the same loop order as all visible boxes. This can make selected state, label readability, and anchors depend on image box order instead of explicit interaction importance.

## Accepted Direction

Adopt a selected-overlay structure that separates geometry, visuals, and hit targets.

The overlay widget for a selected box may occupy a larger screen rect than the box itself. The actual box rectangle is then positioned inside that overlay using a fixed margin equal to the handle hit radius. This lets handles be centered on edges and corners without being clipped.

Non-selected boxes remain lightweight and do not render handles.

## Anchor Design

Each selected box renders eight handles:

- `topLeft`
- `top`
- `topRight`
- `left`
- `right`
- `bottomLeft`
- `bottom`
- `bottomRight`

For every handle:

- The handle center must sit exactly on the displayed box corner or edge midpoint.
- The visual shape must always be a square or near-square chip, never a circle.
- The visible handle size should be stable in screen pixels across zoom levels.
- The hit target should be larger than the visible handle.
- The visible handle should use the box semantic color: gray for proposal boxes, label color for labeled boxes.
- The handle should include a white contrast border and a small shadow so it is readable over images.

Recommended values:

- Visual size: 10-12 screen pixels.
- Hit target: 18-22 screen pixels.
- Border radius: 2 screen pixels or lower.
- Border: white, 1-2 pixels.

The exact values can be tuned during implementation, but the final behavior must keep square handles at all zoom levels.

## Label Position

The label chip is not a child of the box border container.

Instead, it is positioned using the same screen top-left point as the box rectangle. Changing selected stroke width must not change the label's `left` or `top`.

The label should remain visually attached to the box. It may use a small translucent background for readability, but it should not push or resize the box visual.

## Z-Order

Render non-selected boxes first.

Render the selected box last so that its stroke, label, and handles are visible above overlapping boxes.

Within a selected box overlay, draw layers in this order:

1. Box fill.
2. Box stroke.
3. Label chip.
4. Resize handles.

Hit testing follows the same interaction priority:

1. Resize handles.
2. Selected box body for moving.
3. Other boxes for selection.
4. Canvas background.

## Coordinate Rules

This change must not alter stored bbox coordinates.

All bbox data remains in original image pixels. The expanded overlay is only a screen-space layout detail.

Move and resize deltas continue to account for both fit scale and current zoom:

```text
originalDelta = screenDelta / (fitScale * zoom)
```

## Test Coverage

Add or update tests for:

- Selected handles are centered on the box edge/corner in screen geometry.
- Handle visual shape remains square at zoomed and unzoomed states.
- Label position does not change when a box becomes selected.
- Selected box renders after non-selected boxes.
- Existing zoom-correct move and resize tests continue passing.
- Existing toolbar delete and selection color tests continue passing.

Widget-level geometry tests should prefer stable widget keys and `tester.getRect` checks over image pixel assertions.

## Acceptance Criteria

- A selected box shows eight square handles centered on the box boundary.
- Handles remain square after zooming in and out.
- The selected label does not move when selection stroke changes.
- The selected box is visually above overlapping unselected boxes.
- No stored project data, COCO export behavior, or label assignment behavior changes.
- `flutter analyze`, `flutter test`, and `flutter build windows` pass.
