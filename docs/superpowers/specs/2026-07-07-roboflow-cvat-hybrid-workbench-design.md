# Roboflow + CVAT Hybrid Workbench Design

## Context

The user reviewed three visual directions for the annotation workbench and
selected the hybrid direction:

- Roboflow-style modern, fast canvas labeling.
- CVAT-style dense object review and management in the inspector.
- Keep the app focused on local desktop COCO dataset creation.

This design extends the existing workbench refresh direction rather than
replacing it. The current code already has a three-panel Flutter desktop layout,
canvas tools, image queue, labels, boxes, save status, and COCO export. The next
UI pass should make those pieces feel like one polished labeling product.

The visual reference should be used as product inspiration, not copied pixel for
pixel. The app must remain a local Windows-first annotation tool with clear
states, Korean UI copy, and stable COCO export semantics.

## Goals

- Make the workbench feel modern, direct, and fast like Roboflow Annotate.
- Preserve CVAT's best idea: the user can always inspect and manage every box in
  a reliable object list.
- Reduce the distance between drawing a box and assigning a label.
- Make proposal, unlabeled, labeled, selected, confirmed, and error states easy
  to distinguish without relying only on color.
- Keep the workflow dense enough for repeated desktop labeling work.
- Avoid adding advanced CVAT features that do not serve the MVP.

## Non-Goals

- Do not add cloud, account, collaboration, review assignment, or multi-user
  workflows.
- Do not add CVAT track, propagate, layer ordering, pin, lock, hide, or
  occlusion controls in the MVP UI.
- Do not imply that dummy or algorithmic proposals are real AI model results.
- Do not change annotation domain models unless required by the UI workflow.
- Do not change COCO export rules.
- Do not create a marketing landing page or tutorial-heavy onboarding flow.

## Recommended Direction

Use a three-panel desktop workbench:

```text
Top project bar
Left image queue | Center annotation canvas | Right inspector
```

The center canvas should borrow Roboflow's speed:

- A compact floating tool rail for select/move, draw box, and pan.
- Clear crosshair feedback in draw-box mode.
- Immediate label assignment after drawing or selecting a box.
- A lightweight class selector popover near the selected box or near the right
  inspector edge.

The right inspector should borrow CVAT's reliability:

- Selected image summary.
- Confirmation controls.
- Label/class management.
- Box list with one row per visible box.
- Selected box details and destructive actions.

## Visual Language

### Overall Feel

The app should feel like a modern desktop labeling tool, not a web landing page.
Use restrained surfaces, crisp borders, and compact controls. The work surface
should be visually quieter than the boxes and selected actions.

### Palette

- App background: very light neutral gray.
- Panels and popovers: white.
- Primary accent: violet or blue-violet, inspired by Roboflow's modern tooling
  feel.
- Confirmed: green.
- Needs review or warning: amber.
- Error: red.
- Proposal boxes: neutral gray.
- Labeled boxes: project label color.
- Selected box: visible highlight over the label/proposal color.

Avoid a single-hue interface. The current domain benefits from neutral panels,
colored annotations, and clear status badges.

### Surfaces

- Top bar: white, subtle bottom border.
- Left image queue: white panel, compact list rows.
- Center workspace: neutral gray, explicit image stage.
- Tool rail: small floating white controls, active tool filled with primary
  accent.
- Label selector: popover with search/input, class rows, color dots, keyboard
  hints.
- Right inspector: white panel with compact sections.

Do not use nested cards. Cards are acceptable for repeated rows only if they
stay compact and do not make the inspector feel like stacked marketing blocks.

## Center Canvas UX

### Tool Modes

The visible canvas tool modes are:

- Select/move: default.
- Draw box: entered by toolbar button or `B`.
- Pan: entered by toolbar button or temporary `Space`.

Default behavior:

- Background drag pans the image.
- Box click selects a box.
- Selected box drag moves it.
- Selected resize handle drag resizes it.
- Draw-box mode background drag creates a new box.
- `Esc` cancels drawing or clears selection.
- `Delete` and `Backspace` delete the selected box.

This follows the current canvas interaction design and reinforces the Roboflow
pattern where drawing is explicit and accidental boxes are avoided.

### Box Creation Flow

After the user completes a new box:

1. The box is selected.
2. The app opens the label selector.
3. The user can choose an existing label, filter labels by typing, or create a
   new label from the typed value.
4. Assigning a label changes the box from proposal/unlabeled styling to the
   label color.
5. The box appears selected in both the overlay and the right box list.

If the user cancels the label selector immediately after drawing, the new box
remains selected as an unlabeled box. It is visible in the overlay and box list,
keeps the image unconfirmable, and is excluded from COCO export until a label is
assigned. The user can press `Delete` or `Backspace` to remove it.

### Label Selector

The label selector should be closer to Roboflow than CVAT:

- Search/input at the top.
- Existing labels listed with color dots.
- Numeric shortcut hints for the first labels when available.
- `Enter` assigns the active option.
- If text does not match an existing label, show a `Create label` row.
- `Esc` closes the selector without assigning.

The selector should not be a modal. Repeated labeling must keep the user in the
canvas.

## Right Inspector UX

### Sections

The inspector has four sections:

1. Image
   - File name.
   - Dimensions.
   - Status badge.
   - Confirm button or `No objects` confirm button.
   - Remove image action kept secondary.

2. Labels
   - Compact label creation/search input.
   - Existing labels as rows or compact buttons with color dots.
   - Assigning a label applies to the selected box.

3. Boxes
   - One row per visible box.
   - Label or `Unlabeled`.
   - Status marker: proposal, labeled, selected, invalid.
   - Coordinates: `x, y, w, h`.
   - Area.
   - Delete action for the selected row or row menu.

4. Selected Box
   - Only shown when a box is selected.
   - Label dropdown or selector trigger.
   - Coordinate fields can be read-only in the first pass; editable numeric
     fields are a later enhancement.
   - Delete button.

### CVAT Features To Keep Later

The UI should leave room for later row actions, but not implement them now:

- Hide/show box.
- Lock box.
- Duplicate box.
- Change instance color.

For MVP, these stay out of the main inspector to avoid slowing down first-time
use.

## Left Image Queue UX

The image queue remains a compact operational list:

- Thumbnail or thumbnail fallback.
- File name.
- Status badge.
- Total boxes.
- Unlabeled boxes.
- Labeled boxes when space allows.

Filters:

- All.
- Needs review.
- Confirmed.
- Error.
- Has unlabeled boxes.

Rows should feel closer to a production queue than a card gallery. The user is
working through many files, so scanning density matters.

## Status And Data Semantics

The visual states must match the project model:

- Proposal boxes are suggestions and are not exported as COCO annotations.
- Labeled boxes are valid annotations and are exported.
- Deleted boxes are not shown in normal UI.
- An image can be exported even when it is not confirmed.
- An image can be confirmed with zero boxes as `No objects`.
- The confirm button is enabled only when the current image is loadable, all
  visible boxes are valid, and all visible boxes have labels.

The UI must never imply that a candidate box has been accepted until the user
labels and confirms it.

## Component Plan

### Workbench Shell

Keep `WorkbenchScreen` as the shell for now, but extract small presentation
widgets when a section becomes hard to read:

- `WorkbenchCopy`.
- Workbench color/style constants.
- Image queue row.
- Canvas tool rail.
- Label selector popover.
- Inspector section header.
- Box row.

Avoid introducing a new design dependency unless the app already uses it.

### Canvas

Continue using the existing `CanvasTool` and `CanvasPointerActionKind` model.
The visual pass should add better feedback without changing coordinate storage:

- Active tool styling.
- Cursor changes.
- Selected box highlight.
- Proposal vs labeled styling.
- Label selector trigger after creation/selection.

All coordinates remain original image pixel coordinates.

### Inspector

Convert the existing right panel from a simple form/list into a CVAT-inspired
object management panel:

- More structured sections.
- Denser box rows.
- Better selected row styling.
- Clear label color dots.
- Secondary actions kept visually quiet.

## Error Handling

- If a selected image file cannot load, the canvas shows an inline error surface
  and the inspector shows the error status.
- If label creation fails due to duplicate name, keep focus in the selector or
  label input and show a short inline error.
- If save fails after label or box changes, preserve the existing save status
  failure indicator and snack/error behavior.
- If export has warnings, keep the existing export warning flow.

## Accessibility

- Tool buttons and icon-only actions need tooltips and semantic labels.
- Status must be conveyed with text badges as well as color.
- Selected box state must be visible through outline/handles, not only color.
- The label selector must be keyboard usable.
- Button and row text must fit at common desktop widths.

## Testing

Widget tests should cover:

- The tool rail shows select, draw box, and pan tools.
- Draw-box mode creates a box and selects it.
- Creating or selecting a box makes label assignment available.
- Assigning a label changes the selected box's displayed label and color marker.
- Box list selection and overlay selection stay synchronized.
- Unlabeled/proposal boxes keep confirm disabled.
- All labeled valid boxes enable confirm.
- Zero-box images can be confirmed as `No objects`.
- COCO export remains available when unconfirmed images exist.

Unit tests should continue covering:

- Coordinate conversion.
- Box clamp and area.
- Label duplicate rules.
- Confirm eligibility.
- COCO export excluding unlabeled/proposal boxes.

Manual visual checks:

- 1366x768 desktop with no images.
- 1366x768 with imported images and one selected image.
- Dense image with many boxes.
- Long file names and Korean file names.
- Label selector with many labels.
- Error image state.

## Implementation Phasing

1. Fix visible Korean copy corruption and ignore `.superpowers/` local
   brainstorm artifacts.
2. Apply visual shell polish: palette, top bar, panels, image queue rows.
3. Add Roboflow-style canvas tool rail and label selector popover.
4. Upgrade inspector with CVAT-style box rows and selected-box details.
5. Verify widget tests, unit tests, full test suite, and Windows build.

## Acceptance Criteria

- The selected direction is recognizable as the hybrid: fast Roboflow-like
  labeling in the center, reliable CVAT-like review in the right inspector.
- A newly drawn box can be labeled without opening a modal or moving through a
  long form.
- The user can inspect every visible box from the right panel.
- Proposal, unlabeled, labeled, selected, confirmed, and error states are
  visibly distinct and text-labeled where appropriate.
- The UI remains compact and work-focused on desktop.
- Existing save, undo/redo, image import, confirmation, project reopen, and COCO
  export behavior still works.
