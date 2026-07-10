# Workbench UI Information Structure Refinement

## Goal

Improve the labeling workbench so it feels less crowded without removing core
speed features.

The target user is repeatedly reviewing images, assigning labels to proposed
boxes, and moving to the next image. The UI should make this sequence obvious:

1. Choose an image from the queue.
2. Inspect boxes on the canvas.
3. Select a box and understand which row it corresponds to.
4. Assign a label quickly.
5. Complete the image and move to the next one.

The change should preserve the current three-panel workbench and global quick
label bar. It should refine information structure, visual hierarchy, spacing,
and safety around destructive actions.

## Current Issues

The current workbench has a sound base structure:

- Left panel: image queue and progress.
- Center panel: image canvas and editing tools.
- Right panel: selected image, selected box, box list, completion action.
- Bottom bar: quick labels.

The perceived complexity comes from three specific causes:

- The center toolbar mixes automation, editing, view controls, and destructive
  actions at the same visual level.
- Box rows and canvas labels repeat `라벨 필요`, which makes individual boxes
  hard to distinguish.
- The left and right panels are slightly narrow for the amount of repeated
  operational information they carry.

This is not primarily a visual decoration problem. It is an information
structure and action hierarchy problem.

## Recommended Approach

Use the existing workbench architecture and refine the layout in place.

Do not introduce tabs, a wizard, or modal-heavy flows. Those would make the
screen look simpler but slow down repeated labeling.

Recommended changes:

- Keep the three-panel layout.
- Increase the left and right panel widths on normal desktop windows.
- Split the center controls into clear groups: automation, editing, view.
- Move `박스 전체 삭제` out of the main primary toolbar path.
- Add stable box numbers shared between canvas overlays and right-side rows.
- Reduce repeated canvas text for unlabeled boxes.
- Keep `완료하고 다음` fixed at the bottom of the right panel.

## Layout Widths

Current approximate desktop widths:

- Left panel: `280px`.
- Right panel: `340px`.

New desktop widths:

- Left panel: `320px`.
- Right panel: `400px`.

Compact widths:

- For medium windows, use left `260px` and right `340px`.
- Keep the existing compact-layout branch and avoid making the center canvas
  unusably narrow.

The left panel needs more room because image filenames and status text are
operational information. The right panel needs more room because it is the
review and completion area, not merely an inspector.

## Center Toolbar Structure

The center area should present controls as three conceptual groups.

Automation group:

- `자동 박스`
- `자동 라벨`
- Built-in reference status text, when useful
- Overflow menu for less frequent automation actions

Editing group:

- `선택`
- `박스 그리기`
- `이동`
- `선택 박스 삭제`

View group:

- Zoom out
- Fit
- Zoom in

`박스 전체 삭제` should not sit beside the primary automation action as a peer
action. It is destructive and lower-frequency. Keep it visually separated.

When all boxes are deleted, show a clear feedback message that includes an undo
path, using the existing undo behavior.

## Right Sidebar Structure

Keep the current fixed flow:

1. Selected image summary.
2. Selected box details, if a box is selected.
3. Scrollable box list.
4. Fixed completion footer.

The right sidebar should read as a work-progress panel, not a technical
inspector.

Selected box details should stay above the scrollable list. The completion
button should remain fixed at the bottom, outside the scroll area.

## Box Identity And Numbering

Add a stable display number for each visible box in the selected image.

The number should be derived from the visible box order for that image and used
consistently in:

- Canvas overlay badge.
- Right sidebar row.
- Selected box detail heading.
- Accessibility labels.

Example right sidebar rows:

- `#1 라벨 필요`
- `#2 Croffle`
- `#3 라벨 필요`

Example selected box details:

- `#2 · 라벨 필요`
- `x 262 · y 615 · w 591 · h 1091`

This is display identity only. It must not replace persistent `BoundingBox.id`
or affect COCO export.

## Canvas Overlay Labeling

Reduce repeated text in dense images.

Default unlabeled box display:

- Show a compact number badge such as `#1`.
- Keep the gray proposal styling.

Selected unlabeled box display:

- Show `#1 라벨 필요`.
- Keep resize handles and selected outline prominent.

Labeled box display:

- Show label name, optionally prefixed with the number when space allows.

This makes the canvas easier to scan while preserving the ability to map a box
to the right-side list.

## Destructive Action Safety

`박스 전체 삭제` should move to an overflow menu or danger-separated section.

Before deletion:

- Confirm the action.
- Mention the exact number of boxes affected.

After deletion:

- Show feedback such as `박스 9개를 삭제했습니다.`
- Provide or mention undo.

The app already supports undo, so the primary implementation can reuse the
existing undo path.

## Accessibility Requirements

Each major control must have a meaningful label or tooltip.

Specific requirements:

- Canvas box accessibility should read like `박스 #2, 라벨 필요, 선택됨`.
- Right row accessibility should read like `박스 #2, 라벨 필요`.
- Zoom tooltips should be localized consistently.
- State must not be conveyed by color alone.
- Focus order should follow the visible work flow: image list, automation and
  edit tools, canvas, right sidebar, quick labels, completion action.

The current accessibility tree exposes repeated `라벨 필요` text from the canvas.
The numbering change should reduce that repetition.

## Code Boundaries

Primary file:

- `lib/ui/workbench_screen.dart`

Expected affected components:

- `WorkbenchScreen`
- `_ViewerPanel`
- `_CenterAutoBoxesToolbar`
- `_CanvasActionToolbar`
- `_InspectorPanel`
- `_SidebarBoxList`
- `_BoxRow`
- Canvas overlay rendering widgets

Visible copy should remain centralized in:

- `lib/ui/workbench_copy.dart`

Do not change domain models for display numbering. Add local presentation
helpers in the UI layer unless a shared display model becomes clearly necessary.

## Testing Plan

Widget tests should cover:

- Normal desktop layout uses wider left and right panel widths.
- The completion button remains fixed below the sidebar scroll area.
- Selected box details remain above the sidebar scroll area.
- Box rows show display numbers.
- Canvas unlabeled boxes do not repeat full `라벨 필요` text for every box.
- `박스 전체 삭제` is no longer a primary visible peer of `자동 박스`.
- Automatic label unavailable state is shown without exposing `train`.
- Existing complete-and-next behavior still works.

Verification commands:

- `C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart`
- `C:\tools\flutter\bin\flutter.bat analyze`
- `C:\tools\flutter\bin\flutter.bat build windows`

## Out Of Scope

- No new project workflow.
- No COCO export changes.
- No changes to automatic label matching thresholds.
- No new label management redesign.
- No change to stored box IDs or exported category IDs.
- No full responsive mobile redesign.

## Acceptance Criteria

- The workbench still supports fast image-by-image labeling.
- Left and right panels have enough room for operational text on desktop.
- Center controls read as grouped work areas rather than one mixed toolbar.
- Destructive actions are visually separated from primary automation actions.
- A user can reliably match canvas boxes to right sidebar rows.
- Dense images show less repeated text while preserving review clarity.
- Keyboard shortcuts and existing completion flow continue to work.
- Relevant widget tests, analyzer, and Windows build pass.
