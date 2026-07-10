# Comprehensive Release QA Design

## Purpose

This document defines the complete QA program for BBox Labeler. QA does not
stop at confirming that controls respond. It verifies functional correctness,
annotation data integrity, first-time usability, repetitive-work efficiency,
Toss UI/UX principles, visual design, accessibility, performance, packaging,
and recovery behavior. Every reproducible issue from P0 through P3 is fixed and
reverified before the release is considered complete.

## Product Context

BBox Labeler is a Flutter Windows desktop application for creating COCO object
detection datasets from local image folders. Its critical user loop is:

1. Create or reopen a project.
2. Import images.
3. Review detector proposals or draw boxes manually.
4. Assign project labels.
5. Confirm the image.
6. Continue to the next image.
7. Export valid labeled boxes to COCO JSON.

The product must optimize annotation speed without sacrificing original-image
pixel accuracy or recoverability. Detector boxes are suggestions only and must
remain unconfirmed proposals until a user reviews them.

## Approved Operating Model

QA uses sequential quality gates. A failed gate triggers root-cause analysis,
a focused correction, a fresh Windows Release build, and regression testing.

1. Freeze the current source and Release baseline.
2. Verify functional behavior and data integrity.
3. Verify usability, workflow efficiency, and complexity.
4. Evaluate Toss UI/UX principles.
5. Verify visual design, accessibility, performance, and stability.
6. Run complete regression and release acceptance.

The alternative approaches of one large audit followed by one large patch, or
immediate screen-by-screen correction, are rejected. They make regressions and
cross-screen inconsistencies harder to identify.

## Baseline and Safety Boundary

The source of truth is the current Git HEAD in `C:\workspace\bbox`. QA must
build and test this executable only:

`C:\workspace\bbox\build\windows\x64\runner\Release\bbox_labeler.exe`

Before UI testing begins, record:

- Full and short Git commit hashes.
- Git working-tree status.
- `pubspec.yaml` application version.
- Flutter and Dart versions.
- Release build completion time.
- Executable product and file versions.
- Executable SHA-256 hash.

An installed copy under the user's profile is not a valid test target. If the
running process does not resolve to the Release path above, QA stops until the
correct process is launched.

QA uses a dedicated project and test dataset. Existing user projects are not
opened, edited, renamed, or deleted. Source images are never modified. The QA
dataset contains normal images, Korean names, spaces in paths, corrupt files,
large images, an empty folder, duplicate content, bright and dark backgrounds,
busy backgrounds, small objects, and overlapping objects. Destructive tests
operate only on the dedicated QA project.

Unrelated existing source changes are preserved. A QA fix changes only files
required to resolve a reproduced issue.

## Gate 0: Build and Packaging Baseline

Run the complete automated baseline before controlling the app:

- `flutter test`
- `flutter analyze`
- mandatory detector runtime preparation or validation
- `flutter build windows --release`
- release model allow-list verification

Verify that the Release directory contains the mandatory Python runtime,
coordinate-only detector worker, and tray detector model. Verify that it does
not contain `train`, `datasets`, `outputs`, `qa_samples`, `research`, FastSAM,
classifier weights, or other retired models. Verify Windows executable metadata,
brand icon, license files, and third-party notices.

Failure in this gate blocks UI QA because the resulting executable is not a
valid release candidate.

## Gate 1: Functional and Data-Integrity QA

### Project Lifecycle

- Create a project using a non-default Korean name.
- Verify the name in the workbench, home list, persisted project data, and after
  restart.
- Save explicitly, rely on autosave, return home, close, relaunch, and reopen.
- Verify that separate projects never share images, labels, or completion state.

### Image Import and Scanning

- Import a folder and individual image files.
- Exercise Korean filenames, spaces, long paths, empty folders, unsupported
  files, corrupt images, and duplicate content.
- Verify progressive list population and usable cancellation.
- Verify that one bad image does not block valid images.
- Verify queued, detecting, needs-review, confirmed, and error state counts,
  filters, and visible labels against persisted state.

### Detector Proposals

- Verify startup warm-up without blocking the UI.
- Run automatic boxes on at least two images.
- Verify both requests use one persistent worker PID and one model load.
- Verify source image bytes are streamed without exposing source paths to the
  worker.
- Verify returned boxes are unlabeled proposals and never auto-confirmed.
- Exercise cancellation, worker failure, malformed response, and recovery.

### Canvas and Coordinates

- Create boxes manually.
- Select boxes from both overlay and list.
- Move and resize boxes with all eight handles.
- Delete, undo, redo, cancel drawing, and clear selection.
- Repeat editing in fit, 100%, zoomed, and panned views.
- Verify minimum box size and clamping at every image boundary.
- Verify overlay selection, list selection, coordinates, and area remain
  synchronized.

For every saved or exported box, assert:

- `x >= 0`
- `y >= 0`
- `width > 0`
- `height > 0`
- `x + width <= image.width`
- `y + height <= image.height`
- `area == width * height`

Coordinates in project files and COCO JSON must use original image pixels and
must not change merely because display zoom, fit, pan, or window size changed.

### Labels and Confirmation

- Create labels, reject duplicate names, edit names and colors, and assign or
  replace box labels.
- Verify label changes in overlay, list, persisted project data, and COCO
  categories.
- Prevent deletion of an in-use label unless a valid replacement flow is
  completed.
- Disable confirmation while any live box is invalid or unlabeled.
- Enable confirmation when all live boxes are valid and labeled.
- Allow deliberate confirmation of a zero-box image as containing no objects.
- Verify confirmation and confirm-next keyboard flows.

### Undo, Redo, and Autosave

- Verify create, move, resize, delete, label, and confirmation actions undo and
  redo one command at a time.
- Verify shortcuts do not fire while a text field owns the same key input.
- Close after edits without an explicit save, relaunch, and verify the last
  completed autosave.
- Simulate a save failure and verify that the app reports cause, impact, and a
  recovery action without claiming that data was saved.

### COCO Export

Exercise all supported combinations: all images, confirmed images only, empty
images included or excluded, image copying enabled or disabled, incomplete
projects, unlabeled proposals, and error images.

Parse the exported JSON independently and verify:

- required top-level keys exist;
- every image has a unique valid ID, relative filename, width, and height;
- every annotation references an existing image and category;
- every bbox and area satisfies the coordinate assertions;
- `iscrowd` is `0`;
- only valid labeled boxes are annotations;
- proposals and deleted boxes are absent;
- category names and IDs remain stable across repeated exports;
- incomplete-project warnings match actual project counts;
- incomplete but valid exports can continue after acknowledgement.

### Mandatory End-to-End Scenarios

Run at least these scenarios on the final Release:

1. Normal: import, manual box, label, confirm, export.
2. Incomplete: needs-review images, unlabeled proposals, and an error image,
   followed by warning acknowledgement and export.
3. No-object: confirm a zero-box image and export it as an empty image.
4. Restore: edit, close, relaunch, reopen, continue editing, and export.

## Gate 2: Usability and Complexity QA

### User Perspectives

Evaluate two perspectives:

- A first-time user who receives no explanation before starting.
- A repeat annotator processing many images for speed and accuracy.

During the first-time pass, do not inspect help or tooltips until the user flow
becomes blocked. This reveals whether the primary interface itself communicates
the next action.

For every task, record:

- time to first correct action;
- total completion time;
- mouse clicks and key presses;
- incorrect actions and backtracking;
- panel crossings and excessive pointer travel;
- modal or confirmation count;
- places where the next action had to be guessed;
- terms, buttons, and icons that were misunderstood;
- delayed or missing feedback.

### Feature Necessity and Complexity

Evaluate every visible feature with these questions:

1. Does it directly support the core labeling loop?
2. Is it used frequently enough for permanent visibility?
3. Does it duplicate another control or workflow?
4. Can it move to progressive disclosure without blocking completion?
5. Can the user complete the goal if it is removed?

Required but infrequent controls move to an appropriate menu or secondary
surface. Redundant controls are removed unless their contextual placement
materially reduces labor. Information density is not reduced mechanically:
the workbench is one expert task surface whose single goal is to review and
confirm the current image accurately and quickly.

### UX Writing

Audit all visible strings and accessibility labels for:

- clear everyday Korean instead of developer terminology;
- concise active sentences;
- no duplicate title and description;
- one message per sentence;
- predictable action labels;
- consistent meanings for save, complete, confirm, review, and export;
- errors that state cause, impact, and next action;
- neutral language that respects user choice;
- no information hidden merely to increase completion.

## Gate 3: Toss UI/UX Principle Evaluation

Use the following rubric and rate each item `conformant`, `partially
conformant`, or `non-conformant`, with screen evidence and user impact:

- One-second understanding of current state and next action.
- One clear screen goal.
- Clear and predictable calls to action.
- Low cognitive cost.
- Low labor cost.
- Low psychological cost.
- Smooth contextual flow.
- Only currently necessary information emphasized.
- Clear, concise, casual, respectful, and empathetic writing.
- No forced choices or unexpected interruptions.
- Consistent components, states, placement, and language.
- Equivalent meaning and flow for keyboard and assistive-technology users.

This rubric applies Toss's simplicity principles, not a superficial imitation
of Toss colors or mobile layouts. Desktop expert-workflow density remains valid
when every visible element contributes to the current annotation task.

Primary reference material:

- <https://toss.tech/article/mydoc>
- <https://toss.tech/article/8-writing-principles-of-toss>
- <https://toss.tech/article/toss-design-system>
- <https://toss.tech/article/toss-design-system-guide>
- <https://toss.tech/article/tds-color-system-update>
- <https://developers-apps-in-toss.toss.im/design/consumer-ux-guide.html>

## Gate 4: Visual Design QA

Evaluate design using observable rules and user impact, not subjective
statements such as "looks bad."

### Visual Hierarchy and Layout

- Current image, selected box, labeling state, and confirmation action have the
  correct priority.
- Panel boundaries, headings, buttons, rows, and coordinate fields share clear
  alignment anchors.
- Spacing follows a consistent scale.
- Empty space and dense regions remain balanced.
- The canvas retains sufficient working area.

### Typography and Content Stress

- Pretendard is applied consistently.
- Type sizes, weights, line heights, and contrast express hierarchy.
- Korean, English, numbers, and shortcut hints align correctly.
- Long filenames, long label names, large coordinates, many boxes, and localized
  error text do not clip or overlap.

### Components and Interaction States

- Buttons, fields, menus, panels, badges, and rows use consistent heights,
  radii, borders, icon sizes, and spacing.
- Hover, focus, pressed, selected, disabled, loading, success, warning, and
  error states are present and distinguishable.
- Semantic colors represent the same meaning everywhere.
- Color is never the only carrier of state.

### Overlay Readability

Verify boxes, labels, handles, and selection outlines on bright, dark, busy,
and low-contrast images, including small and overlapping objects. The overlay
must remain distinguishable without obscuring the object being annotated.

### Representative Window Sizes

Test these logical work areas:

- 1280 x 720
- 1440 x 900
- 1920 x 1080

Verify clipping, overlap, unwanted horizontal scroll, text truncation, lost
controls, and usable canvas area. Test 100%, 125%, and 150% equivalent logical
scales through a controlled Flutter test environment rather than modifying the
user's Windows display settings.

## Gate 5: Accessibility, Performance, and Stability

### Accessibility

Complete the core flow using only the keyboard. Verify:

- focus order matches visual and task order;
- focus indicators are always visible;
- Escape, Delete, label shortcuts, and undo/redo respect text-field focus;
- every icon button has a useful tooltip and accessible name;
- Windows UI Automation exposes buttons, state, selection, and progress;
- state and error meaning do not depend on color;
- normal text contrast is at least 4.5:1;
- large text and essential UI boundaries reach at least 3:1;
- progress and errors are announced to assistive technology.

### Performance Dataset Sizes

- Small: 10 images.
- Medium: 500 images.
- Large: at least 2,000 images.

Measure startup and project-open time, first visible image and thumbnail, image
switch latency, zoom/pan/box-edit smoothness, scanning and detector
responsiveness, cancellation latency, autosave blocking, memory growth, and
long-session stability. The app must never enter a Windows "Not Responding"
state during supported operations.

Compare a corrected build to its recorded baseline under the same dataset and
environment. A degradation greater than 20% in a measured metric is a
performance regression unless the underlying measurement is shown to be
unstable and is replaced with a reliable measure.

## Defect Model

- P0: data loss or corruption, invalid COCO coordinates, unrecoverable project,
  or application launch failure.
- P1: blocked core flow, save/export/confirmation failure, serious coordinate
  editing error, or unusable detector workflow.
- P2: recoverable problem that causes confusion, rework, a large speed penalty,
  or a major layout/accessibility failure.
- P3: copy, spacing, alignment, polish, minor consistency, or small workflow
  friction.

All P0 through P3 issues are fixed. Priority determines order, not whether an
issue is resolved.

Every issue record contains:

- stable ID and category;
- severity;
- exact reproduction steps;
- expected and actual results;
- reproduction frequency;
- user and data impact;
- screenshot, persisted-data, JSON, log, or timing evidence;
- root cause;
- changed files and correction summary;
- automated and Release UI verification results;
- affected regression scenarios.

## Correction and Verification Loop

For each reproducible issue:

1. Reproduce and capture evidence.
2. Trace the behavior to a root cause.
3. Add a failing unit, widget, integration, or validation test when automation
   can represent the behavior.
4. Apply the smallest complete correction.
5. Run the issue-specific test.
6. Run related module tests.
7. Run the complete Flutter test suite and static analysis.
8. Build a fresh Windows Release executable.
9. Repeat the original UI reproduction on that Release.
10. Run all affected end-to-end regression scenarios.
11. Close the issue only when evidence shows the expected result.

If a design or writing correction changes a shared pattern, audit every use of
that pattern before closing the issue.

## Final Acceptance Criteria

The QA program is complete only when all of these conditions are freshly
verified on the same final Release build:

- Git HEAD, application version, build metadata, path, and executable hash are
  recorded and consistent.
- `flutter test` passes completely.
- `flutter analyze` reports no errors or warnings.
- Windows Release build succeeds.
- Required detector runtime and release-model checks pass.
- All mandatory end-to-end scenarios pass.
- Close and reopen restores the complete project state.
- Independent COCO structure and coordinate validation passes.
- Two-image detector smoke test confirms worker reuse and a single model load.
- There are zero open P0, P1, P2, or P3 defects.
- There are zero non-conformant Toss principle findings.
- There are zero unresolved visual-design checklist findings.
- Keyboard-only core flow and accessibility checks pass.
- Large-project QA has no hang, crash, leak, or unexplained performance
  regression.
- The final core flow passes twice consecutively on the final Release.

Any unverified item prevents a completion claim. Environment-dependent items
remain open until the required environment is available and the check is run.

## QA Artifacts

The final handoff includes:

- baseline commit, version, build time, executable metadata, and hash;
- complete test matrix with pass/fail evidence;
- defect and correction history;
- before-and-after visual evidence;
- functional, usability, Toss-principle, visual, accessibility, and performance
  assessments;
- COCO validation results;
- final release decision;
- an explicit list of any unverified conditions, which must be empty for a
  complete result.
