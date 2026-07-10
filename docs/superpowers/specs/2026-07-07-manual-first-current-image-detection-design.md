# Manual-First Current Image Detection Design

## Context

The current product direction includes automatic proposal generation during
image import. After hands-on use, this creates friction for repeated annotation:
the user must wait for full-folder detection, and it is hard to intentionally
rerun automatic proposals for only the image currently being edited.

The revised direction is manual-first. Importing images should make them
available immediately. Automatic detection remains useful, but it should be an
explicit action for the currently selected image only.

## Goals

- Make image import feel immediate.
- Remove the full-image detection queue from the normal import flow.
- Let the user rerun automatic proposals for the current image at any time.
- Make rerunning proposals a full replacement of all boxes on the current
  image.
- Keep repetitive work fast by avoiding confirmation modals for box reset
  actions.
- Move label assignment closer to the canvas with a bottom quick-label bar.
- Reduce duplicated label UI in the right inspector.

## Non-Goals

- Do not add cloud, account, collaboration, or model training features.
- Do not run automatic detection for every imported image by default.
- Do not preserve labeled boxes when rerunning current-image detection.
- Do not imply that proposal count guarantees better accuracy.
- Do not change COCO export semantics.
- Do not store display coordinates instead of original image pixel
  coordinates.

## Revised Workflow

1. The user adds image files or an image folder.
2. The app scans supported image files and shows them in the image list
   immediately.
3. Imported images start without automatic proposal generation.
4. The user selects an image.
5. The user can draw boxes manually, assign labels, edit boxes, or press
   `Auto boxes`.
6. `Auto boxes` runs detection only for the selected image.
7. `Auto boxes` immediately removes all existing boxes on that image and
   replaces them with new `proposal` boxes.
8. The app does not show a confirmation modal before replacing boxes.
9. The user can undo the replacement with the existing Undo flow.
10. The user can also press `Clear boxes` to remove all boxes on the selected
    image without running detection.
11. Labels are assigned primarily through the bottom quick-label bar.
12. The image can be confirmed when all visible boxes are valid and labeled, or
    when it intentionally has no objects.
13. COCO export remains available even when unconfirmed images exist.

## Layout

Use the existing three-panel desktop workbench, but adjust responsibilities:

```text
Top bar
Left image queue | Center image viewer | Right inspector
Bottom quick-label bar attached to the center work area
```

### Top Bar

The top bar keeps project-level actions:

- Project home.
- Project name.
- Save status.
- Add images.
- Save.
- Undo.
- Redo.
- COCO export.

### Left Image Queue

The left panel stays focused on image navigation:

- Thumbnail or fallback.
- File name.
- Status.
- Total boxes.
- Unlabeled boxes.
- Labeled boxes when space allows.
- Filters for all, needs review, confirmed, error, and unlabeled.

Images should appear as soon as scanning has enough metadata. The user should
not have to wait for detection before selecting and editing an image.

### Center Viewer

The center remains the primary annotation surface:

- Select and move boxes.
- Draw boxes.
- Pan and zoom.
- Resize selected boxes.
- Delete selected boxes.
- Show proposal, labeled, selected, and invalid states distinctly.

The bottom quick-label bar belongs visually to this area because it supports
the most frequent action after selecting or drawing a box.

### Bottom Quick-Label Bar

The quick-label bar shows labels from `1` through `p` shortcut slots:

```text
[1 red bread] [2 blue cream] [3 green package] ... [p yellow label] [+]
```

Each visible label item shows:

- Shortcut key.
- Label color.
- Label name.

Clicking an item or pressing its shortcut assigns that label to the selected
box. If no box is selected, the action does nothing and should not interrupt
the user with a modal.

The `+` action opens label management.

### Label Management

Label management opens as a compact bottom popover anchored from the `+` button
in the quick-label bar. It must show the full label list with:

- Shortcut.
- Color.
- Name.

It must allow:

- Creating a label.
- Editing a label name.
- Editing a label color.
- Assigning or changing a shortcut.
- Rejecting duplicate label names.
- Handling duplicate shortcuts by showing the conflict inline and moving the
  shortcut to the newly edited label when the user applies the change.

The right inspector should not duplicate the full label-management surface.

### Right Inspector

The right inspector becomes a review and current-image control panel:

- Current image file name.
- Image size.
- Image status.
- `Auto boxes` control.
- `Clear boxes` control.
- Box list.
- Selected box coordinates and area.
- Selected box delete action.
- Confirm image action.

The right inspector may show the selected box label for context, but it should
not contain a second full label list when the bottom quick-label bar is present.

## Current-Image Auto Boxes

`Auto boxes` is an immediate action:

1. Save the current project state into the undo stack.
2. Mark the selected image as `detecting`.
3. Run the detector for the selected image only.
4. Remove all existing visible boxes on that image.
5. Add detector results as new `proposal` boxes.
6. Set the image status to `needsReview` unless detection fails.
7. Select the first new proposal when at least one proposal exists; otherwise
   clear the selected box.
8. Trigger autosave.

There is no confirmation dialog. The recovery path is Undo.

Detection failure must not destroy the current boxes. The app should run the
detector first, replace boxes only after a successful result, restore the image
status after failure, and show a short error message in the inspector or canvas.

## Clear Boxes

`Clear boxes` removes every visible box from the selected image immediately.

Rules:

- No confirmation modal.
- Push the previous state to the undo stack.
- Clear selected box.
- Set image status to `needsReview`.
- Allow confirming the image as `No objects` afterward.
- Trigger autosave.

The button should be visually quieter than `Auto boxes` because it is a reset
action without a constructive detector step.

## Proposal Count Option

Candidate count is an optional advanced control, not a permanently visible
required field.

Default behavior:

- The option is off.
- `Auto boxes` uses the detector's default proposal count.

When enabled:

- Show a numeric `Proposal count` input near `Auto boxes`.
- Apply the value only to the selected image's next `Auto boxes` run.
- Treat the value as a maximum number of proposals.
- Use the valid range 1 to 100.
- Keep the last chosen value in memory for the current app session.

The UI must not say that a higher count increases accuracy. The practical
meaning is:

- Higher count may reduce missed objects.
- Higher count may add more unnecessary proposals.
- Lower count may reduce cleanup work.

## Detector Interface Implications

The existing detector abstraction can stay, but current-image detection needs a
way to pass optional run settings.

Preferred shape:

- Add a lightweight detection options object with `maxProposals`.
- Keep `maxProposals` nullable so detector defaults remain available.
- Detectors that cannot pass the option into their implementation must trim
  results after detection.

The current FastSAM sidecar already has a max proposal concept, so the option
can map naturally to that detector.

## Data Semantics

- Auto-generated boxes are `proposal`.
- Manual boxes without labels remain unconfirmed/unlabeled and are excluded
  from COCO export.
- Label assignment changes a proposal or unlabeled box into a labeled box.
- Rerunning auto boxes replaces all current visible boxes on the selected
  image, including labeled boxes.
- Deleted boxes may be tracked for undo during the session but are not shown in
  normal UI.
- COCO export still includes only valid labeled boxes.
- Unconfirmed images can still be exported.

## Error Handling

- Image import errors stay image-specific and should not block other images.
- Detection failure on the current image should show a short inline error in
  the inspector or canvas.
- Save failure should reuse the existing save status failure path.
- Duplicate label names are rejected inline in label management.
- Duplicate shortcuts must be resolved explicitly by replacing or clearing the
  previous shortcut.

## Accessibility And Speed

- `Auto boxes`, `Clear boxes`, quick-label items, and label management actions
  need tooltips or semantic labels.
- Shortcut assignment must be visible as text, not color alone.
- Label color must be paired with label name and shortcut.
- Quick-label bar text must truncate cleanly at narrow widths.
- Keyboard assignment should not steal focus from canvas operations.
- Undo/Redo must remain available after auto replacement and clear operations.

## Testing

Unit tests:

- Importing images does not automatically add proposal boxes.
- Current-image detection replaces all existing boxes with proposals.
- Current-image detection can receive a proposal count option.
- Proposal count off uses detector defaults.
- Clear boxes removes all visible boxes and supports no-object confirmation.
- COCO export still excludes proposals and unlabeled boxes.
- Label shortcut uniqueness rules work.

Widget tests:

- Imported images appear without waiting for detection.
- Right inspector shows `Auto boxes` and `Clear boxes` for a selected image.
- Pressing `Auto boxes` replaces existing labeled and unlabeled boxes.
- Pressing `Clear boxes` removes all boxes without a confirmation dialog.
- Undo restores boxes after auto replacement.
- Bottom quick-label bar shows shortcut, color, and label name.
- Pressing a quick-label shortcut assigns the label to the selected box.
- Label management can create a label with shortcut, color, and name.

Manual checks:

- Add a folder with many images and verify the list is usable immediately.
- Rerun `Auto boxes` repeatedly on the same image.
- Clear boxes and confirm as no objects.
- Use shortcut labels from `1` through `p`.
- Verify Korean file names and long file names still render correctly.

## Acceptance Criteria

- Image import no longer waits for full-folder automatic detection.
- Automatic boxes are generated only by explicit action on the selected image.
- `Auto boxes` fully replaces all boxes on the current image without a
  confirmation modal.
- `Clear boxes` removes all boxes on the current image without a confirmation
  modal.
- Both destructive current-image actions are recoverable through Undo.
- Proposal count is optional and can be turned on or off.
- The right inspector no longer duplicates full label management.
- The bottom quick-label bar shows shortcut, color, and label name.
- Label creation and editing includes shortcut, color, and name.
- COCO export behavior remains unchanged.
