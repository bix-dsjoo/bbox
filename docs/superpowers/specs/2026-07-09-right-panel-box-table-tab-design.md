# Right Panel Box Table Tab Design

## Goal

Add a read-only table tab to the right workbench panel so a labeling worker can
check the current image's box numbers, classes, and pixel coordinates in a dense
spreadsheet-like view.

The table is for review only in this version. It must not introduce direct cell
editing, coordinate editing, sorting, search, copy/export, or changes to the
annotation data model.

## Accepted Direction

Use the existing right inspector panel and add two tabs below the current image
header:

- `작업`: the existing workflow view with grouped box rows and the completion
  action.
- `표 보기`: a read-only table for the selected image's visible boxes.

The default tab is `작업`. The table tab is an alternate view of the same current
image boxes, not a separate dataset screen.

The selected tab is local UI state only. It is not saved to the project file and
does not affect annotation persistence or export output. If the user switches
images while `표 보기` is selected, the table updates to the newly selected image.

## User Value

The current right panel is optimized for finishing the image quickly. That
should stay intact. The new table tab supports a different moment in the work:
checking whether box order, class names, and exact coordinates match an external
reference like a spreadsheet.

This keeps the repeated labeling loop fast while giving users a dense review
mode when they need precision.

## UI Structure

`_InspectorPanel` owns the selected tab state and keeps the existing image
header and completion footer.

Because the current inspector is stateless, implementation can either convert
the inspector to a small `StatefulWidget` or place a tiny stateful tab wrapper
inside it. The state should remain scoped to the right panel.

The panel body becomes:

1. Current image header with file name, work summary, and remove action.
2. Tab bar with `작업` and `표 보기`.
3. Selected tab content.
4. Pinned completion footer.

The `작업` tab keeps the existing selected box details and grouped box list.

The `표 보기` tab renders `_BoxTableView`, which uses the current
`AnnotatedImage.visibleBoxes` and the existing `_boxDisplayNumbers(image)` helper
so numbering stays consistent with the canvas and workflow list.

## Table Columns

The first version uses the same core fields as the provided reference image:

| Column | Source | Display Rule |
| --- | --- | --- |
| `Number` | box display order | Numeric display number without `#` |
| `Class` | matching `LabelClass.name` | Label name, or `미라벨` when no label exists |
| `X` | `BoundingBox.x` | Original image pixel coordinate, rounded with `toStringAsFixed(0)` |
| `Y` | `BoundingBox.y` | Original image pixel coordinate, rounded with `toStringAsFixed(0)` |
| `Width` | `BoundingBox.width` | Original image pixel size, rounded with `toStringAsFixed(0)` |
| `Height` | `BoundingBox.height` | Original image pixel size, rounded with `toStringAsFixed(0)` |

Deleted boxes are excluded because they are also excluded from normal visible
box workflows.

## Interaction

The table is read-only.

- Clicking a row selects the same box on the canvas with
  `controller.selectBox(box.id)`.
- A box selected from the canvas or the workflow list is highlighted in the
  table when the table tab is visible.
- Direct editing, double-click editing, keyboard cell navigation, sorting,
  filtering, and copying are out of scope for this pass.
- If selected-row auto-scroll is straightforward within the existing widget
  structure, include it. Otherwise keep it as a later enhancement.

## Empty And Edge States

- No selected image: keep the existing inspector empty state.
- Selected image with no visible boxes: show `박스 없음` inside the table tab.
- Unlabeled box: show `미라벨` in the `Class` column.
- Invalid box: keep the row visible and add a warning treatment, such as a small
  warning icon or error-colored row accent. Coordinates should still be shown so
  the user can inspect the problem.
- Automation/import busy state: follow existing workbench interaction locking.
  If normal row selection is disabled while busy, table row selection should be
  disabled the same way.
- Narrow right panel: allow horizontal table scrolling rather than squeezing
  columns until text becomes unreadable.

## Non-Goals

- Do not edit labels or coordinates from the table.
- Do not add project-wide annotation tables.
- Do not change save/load/export behavior.
- Do not change category IDs, box IDs, or display-number ordering.
- Do not add table sorting, search, filtering, CSV copy, or Excel export.
- Do not change the canvas overlay or box geometry logic.

## Implementation Notes

Add focused widgets near the current inspector implementation:

- `_InspectorTabBar`
- `_InspectorTab`
- `_BoxTableView`
- `_BoxTableRow`

Keep the implementation in the workbench UI layer and reuse existing helpers
where possible:

- `_boxDisplayNumbers(image)`
- `_boxDisplayNumber(...)`
- `_labelFor(project, box.labelId)`
- existing selected-box styling conventions

The table view should not compute or store alternate coordinates. It displays
the persisted original-image pixel coordinates already on each `BoundingBox`.

## Test Coverage

Widget tests should cover:

- The right inspector shows `작업` and `표 보기` tabs when an image is selected.
- The default selected tab is `작업`.
- Selecting `표 보기` shows the table headers
  `Number`, `Class`, `X`, `Y`, `Width`, `Height`.
- The table displays visible boxes with consistent display numbers.
- The table displays label names for labeled boxes.
- The table displays `미라벨` for unlabeled boxes.
- The table displays rounded original pixel coordinates.
- Clicking a table row updates `controller.selectedBoxId`.
- A selected box is visually highlighted in the table.
- Deleted boxes are not displayed in the table.
- An image with no visible boxes shows `박스 없음`.
- Existing workflow-tab tests for grouped rows and completion footer continue to
  pass.

Manual checks:

- Image with only labeled boxes.
- Image with mixed labeled and unlabeled boxes.
- Image with no boxes.
- Image with enough boxes to require vertical scrolling.
- Narrow right panel width requiring horizontal table scrolling.

## Acceptance Criteria

- Users can switch between the existing work view and a dense table view in the
  right panel.
- The existing work view remains the default and keeps its current completion
  workflow.
- The table shows the selected image's current visible boxes with number, class,
  and original pixel bbox values.
- Table rows and canvas boxes remain selection-synchronized.
- The table is clearly read-only in this version.
- No annotation persistence, COCO export, detector, or coordinate-transform
  behavior changes.
