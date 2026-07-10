# Coordinate, Toolbar, And Global Label Bar Redesign

## Context

Recent hands-on testing found two related problems in the annotation workflow.
First, automatically generated boxes can appear consistently shifted from the
objects. The pattern looks like a coordinate-origin or image-scaling mismatch,
not simply poor detection. Second, the manual-first UI still spends too much
space on secondary panels: automatic box actions live in the right inspector,
label information is duplicated there, and the quick-label bar is constrained to
the center panel instead of using the whole app width.

This design keeps the manual-first direction, but tightens the annotation
workspace around three priorities:

- Bounding boxes must use a trustworthy original-image coordinate system.
- Current-image actions should live near the canvas, not in the inspector.
- Label shortcuts should be visible across the full bottom width of the app.

## Goals

- Diagnose and fix the apparent box coordinate offset.
- Use one consistent coordinate transform for image display, overlays, drawing,
  moving, and resizing.
- Move `Auto boxes` and `Clear boxes` from the right inspector to a canvas
  action toolbar above the image.
- Remove the proposal-count toggle and numeric input.
- Remove duplicated label summary content from the right inspector.
- Move the quick-label bar to a global bottom bar that spans the whole window.
- Make existing projects usable by automatically backfilling missing label
  shortcuts.
- Provide fallback or empty-state UI when no label shortcuts are available.
- Add visible progress, success, empty-result, and failure feedback for
  `Auto boxes`.
- Clean up mixed Korean and English UI copy, using Korean-first labels.

## Non-Goals

- Do not add model selection, model training, cloud sync, or collaboration.
- Do not add a custom proposal-count control in this iteration.
- Do not preserve existing boxes when the user intentionally runs
  `Auto boxes`; successful detection still replaces the current image's boxes.
- Do not change COCO export semantics.
- Do not store display coordinates in project files.

## Coordinate Reliability

The coordinate issue must be treated as the highest-priority fix because it can
damage exported training data.

The implementation should verify these coordinate spaces:

- Original image pixel coordinates stored in project data.
- Detector input coordinates.
- Detector output coordinates.
- Displayed image coordinates inside the Flutter canvas.
- Overlay coordinates for existing boxes.
- Pointer coordinates for drawing, moving, and resizing.

The app should use one transform path for all viewer interactions. The existing
`ViewportTransform` concept is the right boundary: it should be used or matched
by the canvas widget instead of keeping a separate scale-only calculation for
painting and gestures.

### Suspected Causes To Check

- Display image and overlay are being laid out with different assumptions.
- The canvas uses a scale-only transform while the image widget is stretched or
  centered differently.
- Detector preprocessing resizes or pads the image, then restores boxes with an
  incorrect offset.
- EXIF orientation changes decoded image dimensions or visual orientation.
- Image metadata dimensions and the displayed file dimensions differ.

### Coordinate Acceptance Criteria

- A known box in original pixel coordinates appears at the matching object in
  the displayed image.
- Drawing a box on screen stores the expected original pixel coordinates.
- Moving or resizing a box changes original coordinates by the correct scaled
  amount.
- Running `Auto boxes` on the sample dataset no longer creates boxes with a
  consistent vertical or horizontal shift.
- Exported COCO boxes match the corrected original-image coordinates.

## Revised Workbench Layout

The desktop workbench keeps the left queue, center viewer, and right inspector,
but the bottom quick-label bar becomes global:

```text
Top app bar
Left image queue | Center viewer | Right inspector
Global quick-label bar across the full window
```

The default window should be larger because the current 1280x720-style layout
clips important controls. The app should start around 1600 x 950 when possible,
with a practical minimum around 1440 x 900 for desktop annotation work.

## Center Canvas Toolbars

The center viewer gets two compact toolbar rows above the image.

First row, current-image actions:

```text
[자동 박스] [박스 전체 삭제]
```

Second row, canvas tools:

```text
[선택] [박스 그리기] [이동] [축소] [맞춤] [원본 크기] [확대]
```

Rules:

- `자동 박스` runs detection for the selected image only.
- On success, it replaces all visible boxes on that image with new proposal
  boxes.
- There is no confirmation dialog.
- Undo restores the previous boxes.
- `박스 전체 삭제` removes all visible boxes on the selected image immediately.
- Undo restores the cleared boxes.
- The proposal-count toggle and numeric input are removed completely.
- Detector defaults decide how many proposals are returned.

## Auto Boxes Feedback

`Auto boxes` must not fail silently.

Feedback states:

- Running: disable the button and show a short progress state such as
  `자동 박스 생성 중`.
- Success with boxes: show a transient message such as
  `후보 박스 9개 생성됨`.
- Success with zero boxes: show `후보를 찾지 못했습니다`.
- Failure: keep the previous boxes, restore the image status, and show
  `자동 박스 생성 실패. 기존 박스는 유지됩니다`.

The feedback can be a snackbar, inline canvas notice, or inspector message, but
it must be visible without opening a modal.

## Right Inspector

The right inspector becomes a review and details panel only.

Keep:

- Selected image file name.
- Image dimensions.
- Image status.
- Confirm or confirm-no-object action.
- Remove image action.
- Box list.
- Selected box coordinates and area.
- Delete selected box action.

Remove:

- `Auto boxes`.
- `Clear boxes`.
- `Labels`.
- `20 labels` summary.
- Any duplicated full label-management surface.

This makes the inspector narrower and gives more space back to the canvas.

## Global Quick-Label Bar

The quick-label bar moves out of the center viewer and becomes a full-width
bottom bar under the entire workbench.

It should show up to the supported shortcut slots:

```text
[1 color label] [2 color label] ... [p color label] [+]
```

Rules:

- Each chip shows shortcut, label color, and label name.
- Two rows are allowed so the 20 shortcut labels are visible at the default
  window size.
- If the window is still too narrow, horizontal scrolling is allowed.
- Clicking a chip assigns that label to the selected box.
- Pressing the shortcut key assigns that label to the selected box.
- If no box is selected, the action does nothing and should not interrupt the
  user with a modal.
- The `+` action opens label management.

## Existing Project Shortcut Migration

Existing projects may contain labels without shortcuts. On project load, the app
should backfill shortcuts so old projects immediately work with the global
quick-label bar.

Migration rules:

- Keep existing shortcuts as-is when they are valid and unique.
- For labels without shortcuts, assign the next free shortcut from the supported
  sequence `1` through `p`.
- Do not assign unsupported shortcuts.
- If there are more labels than available shortcuts, leave the remaining labels
  without shortcuts.
- Mark the project dirty or autosave after migration using the existing save
  path.
- Migration must not change label ids, names, colors, boxes, or category ids.

## Shortcut Fallback And Empty State

The quick-label bar must not collapse to only a `+` button.

Fallback behavior:

- If labels exist but no shortcut labels are available, show a compact empty
  state: `라벨 단축키가 없습니다`.
- Provide the label-management `+` button next to that message.
- If migration can assign shortcuts, the user should see real chips instead of
  the empty state.
- If a project intentionally has no labels, show `라벨을 추가하세요` with the
  same management action.

## Label Management

Label management continues to show the full label list and allow editing:

- Label name.
- Label color.
- Shortcut key.

It should remain reachable from the global quick-label bar. It does not need to
appear in the right inspector.

## Korean-First Copy

The app should use Korean-first UI copy for the main workflow.

Recommended labels:

- `자동 박스`
- `박스 전체 삭제`
- `선택`
- `박스 그리기`
- `이동`
- `맞춤`
- `원본 크기`
- `확대`
- `축소`
- `이미지`
- `박스`
- `미확정`
- `확정`
- `오류`
- `미라벨`
- `객체 없음으로 확정`
- `COCO 내보내기`

Technical file names, category names, and COCO terminology can remain in their
native form when that is clearer.

## Data Semantics

- Project files still store original-image pixel coordinates.
- Auto-generated boxes still use `proposal` status.
- COCO export still includes only valid labeled boxes.
- Unlabeled proposal boxes are not exported.
- Confirmed and unconfirmed image export behavior is unchanged.
- Label shortcut migration must not affect category id stability.

## Error Handling

- Detection failure does not delete existing boxes.
- Coordinate conversion errors should be caught by tests before export.
- Save failures after shortcut migration should use the existing save-error
  path.
- Label shortcut conflicts should be resolved by the existing label-management
  rules or by migration choosing only free slots.

## Testing

Unit tests:

- Coordinate transform round trips for displayed image origin, scale, pan, and
  zoom.
- Screen drag to original-pixel box conversion.
- Original-pixel box to displayed overlay conversion.
- Existing project shortcut migration fills missing shortcuts.
- Migration preserves existing valid shortcuts.
- Migration does not change label ids or box label ids.
- `Auto boxes` uses detector defaults when no proposal count option exists.
- Detection failure preserves previous boxes.

Widget tests:

- Current-image action toolbar shows `자동 박스` and `박스 전체 삭제` above the
  canvas.
- Right inspector no longer shows label summary or auto/clear controls.
- Global quick-label bar spans the full workbench width.
- Quick-label chips show shortcut, color, and label name.
- Empty shortcut state shows a message instead of only a `+` button.
- Pressing a shortcut assigns the label after migrating an old project.
- `Auto boxes` shows running, success, zero-result, and failure feedback.

Manual checks:

- Open an existing project whose labels have no shortcuts and verify shortcuts
  appear automatically.
- Label several boxes using shortcuts on dataset images.
- Run `자동 박스` on the current image and confirm boxes align with objects.
- Clear boxes, then Undo, and verify the previous boxes return.
- Confirm the 20-label bar is readable at the default window size.
- Resize the window smaller and verify labels scroll instead of disappearing.

## Acceptance Criteria

- Bounding boxes no longer appear consistently shifted relative to the image.
- Drawing, moving, resizing, saving, loading, and exporting boxes all preserve
  original-image coordinate correctness.
- `자동 박스` and `박스 전체 삭제` are in the center canvas toolbar, not the
  right inspector.
- The proposal-count toggle and input are removed.
- The right inspector no longer shows duplicated label information.
- The quick-label bar spans the whole app bottom area.
- Existing projects get usable label shortcuts automatically.
- Projects with no shortcut labels show a clear fallback or empty state.
- `Auto boxes` provides visible running, success, zero-result, and failure
  feedback.
- Main workflow UI copy is Korean-first and no longer appears as a confusing
  mix of Korean and English.
