# Bounding Box Labeler MVP Design

## Context

The workspace starts as a greenfield Flutter project with only `AGENTS.md`.
The MVP target is Windows desktop. Flutter 3.44.4 is available at
`C:\tools\flutter`, Visual Studio Build Tools are available, and Android is
not required for this release.

Git is installed outside PATH, but `C:\workspace\bbox` is not currently a Git
repository. Worktree isolation and commits are therefore not applicable unless
the project is initialized later.

## Product Scope

The app is a local desktop labeling tool. Users create or open a project,
choose an image folder, review generated proposal boxes, edit boxes, create
labels, assign labels, confirm images, save project state, reopen projects,
and export COCO JSON.

The detector is explicitly an algorithmic dummy detector. It exists to produce
reviewable proposal boxes and to preserve an interface for a later real model.
The UI must not describe it as AI.

Out of scope for the MVP: accounts, cloud sync, collaboration, model training,
detector model selection, train/valid/test split export, and label statistics.

## Architecture

The Flutter app is split into small modules:

- `lib/annotation`: pure domain models and rules for images, boxes, labels,
  statuses, validation, and undoable annotation edits.
- `lib/project`: project creation, JSON serialization, save/load, relative
  paths, and version checks.
- `lib/image_import`: image folder scanning, supported file filtering, image
  dimensions, and progressive import hooks.
- `lib/detector`: detector interface and deterministic dummy detector.
- `lib/viewer`: coordinate transforms, overlay painting, hit testing, drag,
  resize, and drawing interactions.
- `lib/export`: COCO validation summary and JSON generation.
- `lib/ui`: app controller, shell layout, image list, viewer, box list, label
  panel, export dialog, and keyboard shortcuts.

The UI uses `ChangeNotifier` from Flutter foundation for state management to
avoid extra framework complexity. UI actions call controller methods; widgets
do not mutate domain objects directly.

## Data Model

Projects store:

- name, project file path, image folder path, schema version
- labels with stable integer IDs, names, and colors
- images with stable integer IDs, relative paths, original dimensions, status,
  error text, and annotation boxes
- boxes with stable string IDs, original-pixel `x`, `y`, `width`, `height`,
  `proposal` or `labeled` status, optional label ID, and confidence

Coordinates are always stored in original image pixels. Viewer zoom, pan, and
fit values are display state only.

Project files are UTF-8 JSON with app metadata. COCO export is separate and
contains only standard COCO fields plus optional `info` and `licenses`.

## Workflow

First launch shows a practical start screen with actions to create a new
project, open an existing project, and choose an image folder once a project
exists. The workbench uses the AGENTS.md three-column layout:

- left: image list with thumbnail, file name, status, box count, unlabeled
  count, labeled count, and filters
- center: image viewer with overlay boxes, zoom controls, fit, pan, drawing,
  selection, move, resize handles, and keyboard delete
- right: selected image summary, box list, label selector/creator, box
  coordinates, confirm button, and export action

Import scans `jpg`, `jpeg`, and `png` files recursively enough for normal
folders while preserving relative paths. Each imported image starts as
`queued`, becomes `detecting` during dummy detection, and ends as
`needsReview` with gray proposal boxes or `error` if metadata/detection fails.

Users can draw a box, select a box from the overlay or list, move and resize it,
delete it with undo support, create labels, and assign labels. Assigning a label
changes a proposal box to `labeled` and displays the label color.

Confirm is enabled when the image is loaded, all non-deleted boxes are valid,
and every box is labeled. An image with no boxes can still be confirmed as
"object none".

## Export

Before export, the controller computes a validation summary:

- unconfirmed image count
- unlabeled proposal box count
- error image count
- blocking structural errors, such as invalid labeled boxes

The user can continue when only warnings exist. Export includes selected images
according to options and includes only valid labeled boxes as annotations.
Proposal boxes are never exported. Category IDs are the stable label IDs sorted
by label ID.

## Error Handling

Recoverable failures surface as concise UI messages and image/project error
state:

- inaccessible folder
- unsupported or corrupt image
- metadata decode failure
- detector failure
- save/load schema mismatch
- save/export I/O failure

The app never modifies source images. Save failures do not silently discard
state; the controller keeps dirty state and exposes the error.

## Testing And QA Evidence

Automated tests must cover:

- box area, validity, clamp, and minimum size
- coordinate transform round trips, fit, zoom, pan, and clamp
- label uniqueness, rename/delete policy, and color persistence
- confirmation rules, including proposals blocking confirm and empty images
  being confirmable
- project JSON save/load with relative paths and Korean file names
- dummy detector proposal status
- COCO export structure, stable category IDs, labeled-only annotations, area,
  original-pixel coordinates, and warnings for unfinished work
- widget flows for image selection, overlay/list selection sync, label color
  change, confirm button state, empty-image confirm, and export warning dialog

Verification commands:

- `flutter pub get`
- `dart format --set-exit-if-changed .`
- `flutter analyze`
- `flutter test`
- `flutter build windows`

Manual QA follows the 20-step scenario from the goal objective using a temporary
folder with sample images, Korean file names, proposal boxes, edited boxes,
labels, confirmation, export, and project reopen.

## Self Review

No placeholders remain. The scope is the AGENTS.md MVP and excludes post-MVP
items. The detector is identified as dummy/algorithmic, not AI. Coordinates,
persistence, and COCO export rules are explicit and testable.
