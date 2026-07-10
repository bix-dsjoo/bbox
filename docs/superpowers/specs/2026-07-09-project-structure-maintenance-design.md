# Project Structure Maintenance Design

## Context

After the first demo, the project has enough working product surface to justify a maintenance pass before more features are added. The current codebase already has useful domain folders:

- `lib/annotation`
- `lib/project`
- `lib/image_import`
- `lib/detector`
- `lib/export`
- `lib/viewer`
- `lib/ui`

The main maintainability pressure is concentrated in a few large files:

- `lib/ui/workbench_screen.dart`, about 104 KB
- `test/ui/workbench_widget_test.dart`, about 105 KB
- `lib/ui/app_controller.dart`, about 33 KB
- `lib/detector/detector.dart`, about 23 KB

The workspace also contains generated artifacts and local data folders such as `build`, `dist`, `runtime`, `datasets`, `train`, `outputs`, and `qa_samples`. These are mostly ignored by `.gitignore`, but their presence at the project root makes the source boundary harder to read.

The current shell cannot find `flutter` on `PATH`, so implementation verification must first locate the Flutter SDK or be run from an environment where `flutter analyze` and `flutter test` are available.

## Goal

Improve maintainability and extension readiness without changing user-facing behavior.

The pass should make it easier to:

- Find UI components by responsibility.
- Add future workbench features without editing one very large file.
- Run focused widget tests without searching one very large test file.
- Understand which root folders are source, tooling, generated runtime, sample data, and release artifacts.
- Preserve the existing demo behavior and current MVP workflows.

## Non-Goals

This pass will not:

- Redesign the product UI.
- Replace the current state management approach.
- Rewrite detector behavior.
- Change COCO export semantics.
- Move user data or generated artifacts automatically.
- Introduce cloud, account, collaboration, or model training features.

## Recommended Approach

Use a behavior-preserving structural cleanup.

The first phase should split files along existing responsibility boundaries and keep public behavior stable. This is safer than a controller rewrite immediately after the demo, but still creates useful extension points for later work.

## Proposed Module Shape

Keep the existing top-level domain folders. Add subfolders only where they reduce real file size and search cost.

### UI Workbench

Split `lib/ui/workbench_screen.dart` into a workbench feature folder:

- `lib/ui/workbench/workbench_screen.dart`
- `lib/ui/workbench/workbench_shell.dart`
- `lib/ui/workbench/image_queue_panel.dart`
- `lib/ui/workbench/viewer_panel.dart`
- `lib/ui/workbench/image_canvas.dart`
- `lib/ui/workbench/canvas_overlay.dart`
- `lib/ui/workbench/center_toolbar.dart`
- `lib/ui/workbench/inspector_panel.dart`
- `lib/ui/workbench/box_list.dart`
- `lib/ui/workbench/quick_label_bar.dart`
- `lib/ui/workbench/import_progress_banner.dart`
- `lib/ui/workbench/workbench_dialogs.dart`

Keep `WorkbenchScreen` as the public entry point so callers and app routing do not need to change.

Private helper widgets can become private to their new files where possible. Shared helper types that must cross files should use intentionally named library-private files or small public classes in the workbench folder.

### Controller

Do not split `AppController` in the first pass unless needed to unblock UI extraction.

Instead, document its current responsibilities and extract only low-risk pure helpers if they are already clearly independent. Candidate later extractions:

- selection repair helpers
- import progress helpers
- auto-save orchestration
- selected image completion helpers
- project library commands

This avoids changing notification timing, undo stack behavior, auto-save sequencing, and detector interaction during the first cleanup.

### Detector

Do not change detector behavior in the first pass.

Add a future note that `lib/detector/detector.dart` can later be split into:

- detector contract and result models
- FastSAM sidecar implementation
- dummy detector
- image-processing detector
- shared bbox post-processing helpers

Detector behavior is connected to release packaging and should be separated only with focused tests in place.

### Tests

Split `test/ui/workbench_widget_test.dart` into files that mirror the workbench modules:

- `test/ui/workbench/workbench_shell_test.dart`
- `test/ui/workbench/image_queue_panel_test.dart`
- `test/ui/workbench/canvas_interaction_test.dart`
- `test/ui/workbench/canvas_overlay_test.dart`
- `test/ui/workbench/center_toolbar_test.dart`
- `test/ui/workbench/inspector_panel_test.dart`
- `test/ui/workbench/quick_label_bar_test.dart`
- `test/ui/workbench/export_and_completion_test.dart`

Move common test setup into:

- `test/ui/workbench/workbench_test_support.dart`

The initial split should preserve existing test names and assertions where practical. The goal is easier navigation, not broad test rewriting.

### Repository Boundary Documentation

Add or update a short repository map in `README.md` or a new `docs/project-structure.md`.

It should identify:

- source code folders
- test folders
- packaging tools
- generated build outputs
- generated Python detector runtime
- local datasets and QA samples
- release artifacts

The documentation should state that `train`, `datasets`, `qa_samples`, `outputs`, `dist`, and generated `runtime/python` content are local development or generated artifacts, not normal product source.

## Data Flow Preservation

The cleanup must preserve the current flow:

1. Start screen creates or opens a project.
2. Workbench receives `AppController`.
3. User imports image files or folders.
4. Controller updates project images, selected image, progress, and save state.
5. Workbench panels render from controller state.
6. Canvas interactions call explicit controller actions.
7. Label changes, box edits, confirmation, and export continue through existing controller methods.

No new state management framework should be introduced in this pass.

## Error Handling

Existing user-facing error behavior should remain unchanged.

The refactor should preserve:

- detector failure messages
- image import failures
- save failure state
- export warning dialogs
- missing image handling
- disabled editing during automatic box generation or import

Any extracted widget that shows an error should receive already-prepared state or callbacks rather than perform new file I/O or detector work.

## Testing Strategy

Before changes:

- Locate Flutter SDK or confirm the user environment that can run Flutter.
- Run `flutter analyze` if available.
- Run `flutter test` if available.

During the split:

- Move tests in small batches.
- After each batch, run the smallest relevant test file where possible.
- Keep existing keys and visible labels stable unless a test explicitly proves they are dead or accidental.

After changes:

- Run `flutter analyze`.
- Run `flutter test`.
- If full Flutter verification is unavailable in this shell, report that explicitly and provide the exact commands that need to be run in the configured Flutter environment.

## Implementation Order

1. Add repository structure documentation.
2. Create `lib/ui/workbench/` and move workbench UI pieces one group at a time.
3. Keep `lib/ui/workbench_screen.dart` as a compatibility export or thin wrapper if needed.
4. Split workbench widget tests into matching files with shared test support.
5. Run analyze and tests.
6. Revisit `AppController` only for obvious pure helper extraction if the UI split reveals a low-risk seam.

## Success Criteria

The cleanup is complete when:

- Workbench UI responsibilities are split into smaller files.
- `WorkbenchScreen` remains available to existing callers.
- Existing user-facing behavior is unchanged.
- Workbench tests are grouped by responsibility.
- Repository structure and generated-artifact boundaries are documented.
- Analyzer and tests pass in a Flutter-enabled environment, or any inability to run them is clearly reported.

