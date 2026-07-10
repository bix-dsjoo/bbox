# Project Structure Maintenance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the largest workbench UI and widget test files into responsibility-based units while preserving current demo behavior.

**Architecture:** Keep the current Flutter `ChangeNotifier` controller and domain folders. Use Dart `part` files for the first workbench split so existing private widgets, constants, and helper functions can remain library-private while physical files become smaller. Keep `lib/ui/workbench_screen.dart` as a compatibility export for existing imports.

**Tech Stack:** Flutter desktop, Dart, Material widgets, `flutter_test`, existing `path`, `image`, `filepicker_windows`, and `forui` dependencies.

## Global Constraints

- Do not change user-facing behavior.
- Do not redesign the product UI.
- Do not replace the current state management approach.
- Do not rewrite detector behavior.
- Do not change COCO export semantics.
- Do not move user data or generated artifacts automatically.
- Keep `WorkbenchScreen` available to existing callers through `lib/ui/workbench_screen.dart`.
- Preserve existing widget keys and visible labels unless a failing test proves a key or label is already unused.
- `C:\workspace\bbox` is not currently recognized as a Git repository, so commit steps are replaced with changed-file summaries unless `.git` exists during execution.
- The current shell cannot find `flutter` on `PATH`; verification steps must first locate Flutter or explicitly record that Flutter verification is blocked.

---

## File Structure

Create these files:

- `docs/project-structure.md`: short repository map for source, generated outputs, local data, runtime, and packaging folders.
- `lib/ui/workbench/workbench_screen.dart`: main workbench library with imports, constants, `WorkbenchScreen`, and `part` directives.
- `lib/ui/workbench/workbench_shared.dart`: shared small widgets and visual wrappers used across panels.
- `lib/ui/workbench/image_queue_panel.dart`: image list panel and image queue row.
- `lib/ui/workbench/viewer_panel.dart`: viewer panel state, viewport state, and center viewer composition.
- `lib/ui/workbench/center_toolbar.dart`: center toolbar rail, automation toolbar, action toolbar, and toolbar groups.
- `lib/ui/workbench/image_canvas.dart`: interactive image canvas, pointer handling, zoom handling, draw preview, overlay, resize handles, and overlay painter.
- `lib/ui/workbench/inspector_panel.dart`: right inspector panel, completion footer, box groups, box list rows, selected box details, and remove-image dialog helper.
- `lib/ui/workbench/quick_label_bar.dart`: quick label bar, quick label chips, and label popover handling.
- `lib/ui/workbench/workbench_feedback.dart`: auto-box feedback, import progress banner, empty states, and progress text.
- `lib/ui/workbench/workbench_helpers.dart`: top-level workbench helper functions such as label lookup, shortcut mapping, display numbering, and validation grouping.
- `test/ui/workbench/workbench_test_support.dart`: shared test fixtures, fake picker, delayed detector, and workbench pump helpers.
- `test/ui/workbench/workbench_shell_test.dart`: top bar, import entry, project context, and empty shell tests.
- `test/ui/workbench/image_queue_panel_test.dart`: image queue, status summary, selection, and responsive queue tests.
- `test/ui/workbench/canvas_interaction_test.dart`: draw, pan, select, drag, zoom, resize, and keyboard canvas tests.
- `test/ui/workbench/canvas_overlay_test.dart`: overlay labels, resize handles, z-order, contrast, and semantics tests.
- `test/ui/workbench/center_toolbar_test.dart`: toolbar grouping, automation controls, clear boxes, and shortcut tests.
- `test/ui/workbench/inspector_panel_test.dart`: inspector summary, box rows, selected details, completion footer, and remove-image tests.
- `test/ui/workbench/quick_label_bar_test.dart`: quick label chips, shortcuts, label creation, and empty label state tests.
- `test/ui/workbench/export_and_completion_test.dart`: confirm, object-none, complete-and-next, and export warning tests.

Modify these files:

- `README.md`: add a link to `docs/project-structure.md`.
- `lib/ui/workbench_screen.dart`: replace with a compatibility export.
- `test/ui/workbench_widget_test.dart`: reduce to a compatibility import file or delete after all tests are moved. Prefer deletion once the split tests pass.

---

### Task 1: Repository Map And Verification Baseline

**Files:**
- Create: `docs/project-structure.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: existing root folders and `.gitignore` policy.
- Produces: a stable documentation target linked from `README.md`.

- [ ] **Step 1: Check whether Flutter is available**

Run:

```powershell
where.exe flutter
```

Expected when available: one or more Flutter executable paths.

Expected in the current shell:

```text
INFO: Could not find files for the given pattern(s).
```

- [ ] **Step 2: Run baseline analyzer when Flutter is available**

Run:

```powershell
flutter analyze
```

Expected when available: analyzer completes. Record all output before changing source files.

Expected in the current shell: skip this command because `where.exe flutter` returned no executable path.

- [ ] **Step 3: Run baseline tests when Flutter is available**

Run:

```powershell
flutter test
```

Expected when available: tests complete. Record failures before changing source files.

Expected in the current shell: skip this command because `where.exe flutter` returned no executable path.

- [ ] **Step 4: Add repository structure documentation**

Create `docs/project-structure.md` with this content:

```markdown
# Project Structure

This project is a Flutter Windows desktop app for local COCO bounding-box labeling.

## Product Source

- `lib/annotation/`: annotation domain models, bbox rules, label defaults, and label migrations.
- `lib/project/`: project persistence and local project library indexing.
- `lib/image_import/`: supported image scanning and image metadata extraction.
- `lib/detector/`: detector contracts and current automatic-box detector implementations.
- `lib/export/`: COCO JSON export and export validation.
- `lib/viewer/`: viewport coordinate transforms for original-image to screen-space mapping.
- `lib/ui/`: Flutter UI, app controller, workbench, dialogs, theme, and UI copy.
- `assets/`: app branding and bundled font assets used by the Flutter app.
- `windows/`: Flutter Windows runner and native Windows app metadata.

## Tests

- `test/annotation/`: bbox, label, and annotation rule tests.
- `test/project/`: project save/load and project library tests.
- `test/image_import/`: scanner tests for supported image inputs.
- `test/detector/`: detector contract and detector implementation tests.
- `test/export/`: COCO export tests.
- `test/viewer/`: viewport transform tests.
- `test/ui/`: widget and controller tests.
- `test/integration/`: MVP workflow tests.
- `test/packaging/`: installer and version consistency tests.

## Tooling And Packaging

- `tools/detectors/`: Python detector sidecar scripts used by automatic-box proposals.
- `tools/packaging/`: Windows release and detector runtime packaging helpers.
- `installer/`: Inno Setup script and installer images.
- `docs/`: release notes, design specs, implementation plans, and project documentation.

## Local Data And Generated Artifacts

These folders can exist in a developer workspace, but they are not normal product source:

- `build/`: Flutter, installer, and local build outputs.
- `dist/`: generated installer artifacts.
- `runtime/python/`: generated bundled Python detector runtime.
- `datasets/`: local development images.
- `train/`: local training or sample images.
- `qa_samples/`: local QA image samples.
- `outputs/`: generated analysis, overlay, or export outputs.

The repository `.gitignore` excludes these large or generated folders. Do not depend on them for normal source builds unless a test or release procedure explicitly says so.
```

- [ ] **Step 5: Link the repository map from README**

Add this section after the "Data Policy" section in `README.md`:

```markdown
## Project Structure

For a map of source folders, tests, packaging tools, local datasets, and generated artifacts, see `docs/project-structure.md`.
```

- [ ] **Step 6: Verify documentation links**

Run:

```powershell
Test-Path docs\project-structure.md
Select-String -Path README.md -Pattern 'docs/project-structure.md'
```

Expected:

```text
True
README.md:...:For a map of source folders, tests, packaging tools, local datasets, and generated artifacts, see `docs/project-structure.md`.
```

- [ ] **Step 7: Record changed files instead of committing when no Git repository exists**

Run:

```powershell
Test-Path .git
```

Expected in the current workspace:

```text
False
```

When the result is `False`, record this changed-file summary:

```text
Changed files:
- docs/project-structure.md
- README.md
Git commit skipped because C:\workspace\bbox is not a Git repository.
```

---

### Task 2: Workbench Part-File Scaffold

**Files:**
- Create: `lib/ui/workbench/workbench_screen.dart`
- Create: `lib/ui/workbench/workbench_shared.dart`
- Create: `lib/ui/workbench/image_queue_panel.dart`
- Create: `lib/ui/workbench/viewer_panel.dart`
- Create: `lib/ui/workbench/center_toolbar.dart`
- Create: `lib/ui/workbench/image_canvas.dart`
- Create: `lib/ui/workbench/inspector_panel.dart`
- Create: `lib/ui/workbench/quick_label_bar.dart`
- Create: `lib/ui/workbench/workbench_feedback.dart`
- Create: `lib/ui/workbench/workbench_helpers.dart`
- Modify: `lib/ui/workbench_screen.dart`

**Interfaces:**
- Consumes: current `WorkbenchScreen` public constructor:

```dart
const WorkbenchScreen({
  super.key,
  required this.controller,
  this.imageImportPicker = const WindowsImageImportPicker(),
});
```

- Produces: the same `WorkbenchScreen` class exported from `lib/ui/workbench_screen.dart`.

- [ ] **Step 1: Create the workbench folder**

Run:

```powershell
New-Item -ItemType Directory -Force -Path lib\ui\workbench
```

Expected:

```text
Directory: C:\workspace\bbox\lib\ui
...
workbench
```

- [ ] **Step 2: Move the current workbench library into the new folder**

Run:

```powershell
Move-Item -LiteralPath lib\ui\workbench_screen.dart -Destination lib\ui\workbench\workbench_screen.dart
```

Expected:

```powershell
Test-Path lib\ui\workbench\workbench_screen.dart
```

returns:

```text
True
```

- [ ] **Step 3: Add the compatibility export**

Create a new `lib/ui/workbench_screen.dart` containing exactly:

```dart
export 'workbench/workbench_screen.dart';
```

- [ ] **Step 4: Adjust imports in the moved workbench library**

In `lib/ui/workbench/workbench_screen.dart`, replace the current relative imports:

```dart
import '../annotation/annotation_rules.dart';
import '../annotation/models.dart';
import '../viewer/viewport_transform.dart';
import 'app_controller.dart';
import 'app_theme.dart';
import 'canvas_interaction.dart';
import 'image_import_picker.dart';
import 'label_management_popover.dart';
import 'workbench_copy.dart';
import 'windows_dialog_service.dart';
```

with:

```dart
import '../../annotation/annotation_rules.dart';
import '../../annotation/models.dart';
import '../../viewer/viewport_transform.dart';
import '../app_controller.dart';
import '../app_theme.dart';
import '../canvas_interaction.dart';
import '../image_import_picker.dart';
import '../label_management_popover.dart';
import '../workbench_copy.dart';
import '../windows_dialog_service.dart';
```

- [ ] **Step 5: Add part directives to the moved workbench library**

In `lib/ui/workbench/workbench_screen.dart`, add these lines after the imports and before the first constant:

```dart
part 'workbench_shared.dart';
part 'image_queue_panel.dart';
part 'viewer_panel.dart';
part 'center_toolbar.dart';
part 'image_canvas.dart';
part 'inspector_panel.dart';
part 'quick_label_bar.dart';
part 'workbench_feedback.dart';
part 'workbench_helpers.dart';
```

- [ ] **Step 6: Create empty part files**

Create each new part file with a single `part of` declaration:

```dart
part of 'workbench_screen.dart';
```

The files are:

```text
lib/ui/workbench/workbench_shared.dart
lib/ui/workbench/image_queue_panel.dart
lib/ui/workbench/viewer_panel.dart
lib/ui/workbench/center_toolbar.dart
lib/ui/workbench/image_canvas.dart
lib/ui/workbench/inspector_panel.dart
lib/ui/workbench/quick_label_bar.dart
lib/ui/workbench/workbench_feedback.dart
lib/ui/workbench/workbench_helpers.dart
```

- [ ] **Step 7: Verify the scaffold without moving classes yet**

Run when Flutter is available:

```powershell
flutter analyze
```

Expected: no new missing-import errors from `lib/ui/workbench_screen.dart` compatibility export or the moved `lib/ui/workbench/workbench_screen.dart` imports.

If Flutter is unavailable, run:

```powershell
Select-String -Path lib\ui\workbench\workbench_screen.dart -Pattern "part 'workbench_shared.dart';"
Get-Content -LiteralPath lib\ui\workbench_screen.dart
```

Expected:

```text
lib\ui\workbench\workbench_screen.dart:...:part 'workbench_shared.dart';
export 'workbench/workbench_screen.dart';
```

---

### Task 3: Split Workbench UI Classes Into Part Files

**Files:**
- Modify: `lib/ui/workbench/workbench_screen.dart`
- Modify: `lib/ui/workbench/workbench_shared.dart`
- Modify: `lib/ui/workbench/image_queue_panel.dart`
- Modify: `lib/ui/workbench/viewer_panel.dart`
- Modify: `lib/ui/workbench/center_toolbar.dart`
- Modify: `lib/ui/workbench/image_canvas.dart`
- Modify: `lib/ui/workbench/inspector_panel.dart`
- Modify: `lib/ui/workbench/quick_label_bar.dart`
- Modify: `lib/ui/workbench/workbench_feedback.dart`
- Modify: `lib/ui/workbench/workbench_helpers.dart`

**Interfaces:**
- Consumes: the part-file scaffold from Task 2.
- Produces: smaller physical UI files within one Dart library. All private identifiers keep their current names and remain accessible across parts.

- [ ] **Step 1: Keep only imports, constants, shortcut lists, `WorkbenchScreen`, and part directives in the main workbench library**

After this step, `lib/ui/workbench/workbench_screen.dart` keeps:

```dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../annotation/annotation_rules.dart';
import '../../annotation/models.dart';
import '../../viewer/viewport_transform.dart';
import '../app_controller.dart';
import '../app_theme.dart';
import '../canvas_interaction.dart';
import '../image_import_picker.dart';
import '../label_management_popover.dart';
import '../workbench_copy.dart';
import '../windows_dialog_service.dart';

part 'workbench_shared.dart';
part 'image_queue_panel.dart';
part 'viewer_panel.dart';
part 'center_toolbar.dart';
part 'image_canvas.dart';
part 'inspector_panel.dart';
part 'quick_label_bar.dart';
part 'workbench_feedback.dart';
part 'workbench_helpers.dart';
```

It also keeps the current constants, `_quickLabelShortcutLabels`, `_quickLabelShortcutKeys`, and the full `WorkbenchScreen` class including its private methods.

- [ ] **Step 2: Move shared widgets to `workbench_shared.dart`**

Move these declarations, preserving their code exactly:

```text
_ToolbarSeparator
_ImageImportMenuButton
_SaveStatusIndicator
_CanvasToolButton
_ShortcutBadge
_EmptyActionState
_PanelSurface
_PanelHeader
```

The file starts with:

```dart
part of 'workbench_screen.dart';
```

- [ ] **Step 3: Move image queue widgets to `image_queue_panel.dart`**

Move these declarations, preserving their code exactly:

```text
_ImageListPanel
_ImageQueueRow
```

The file starts with:

```dart
part of 'workbench_screen.dart';
```

- [ ] **Step 4: Move viewer panel state to `viewer_panel.dart`**

Move these declarations, preserving their code exactly:

```text
_ViewerPanel
_ViewerPanelState
```

The file starts with:

```dart
part of 'workbench_screen.dart';
```

- [ ] **Step 5: Move center toolbar widgets to `center_toolbar.dart`**

Move these declarations, preserving their code exactly:

```text
_CenterToolbarRail
_CenterAutoBoxesToolbar
_ToolbarGroup
_CanvasActionToolbar
```

The file starts with:

```dart
part of 'workbench_screen.dart';
```

- [ ] **Step 6: Move canvas and overlay widgets to `image_canvas.dart`**

Move these declarations, preserving their code exactly:

```text
_ImageCanvas
_ImageCanvasState
_CanvasBoxProjection
_DrawPreview
_AutomationEditingLockedBadge
_BoxOverlay
_ResizeHandle
_OverlayBadgePainter
```

The file starts with:

```dart
part of 'workbench_screen.dart';
```

- [ ] **Step 7: Move inspector widgets to `inspector_panel.dart`**

Move these declarations, preserving their code exactly:

```text
_InspectorPanel
_InspectorCompletionFooter
_SidebarBoxGroups
_SidebarBoxRowState
_SidebarBoxList
_SectionTitle
_BoxRow
_SelectedBoxDetails
```

The file starts with:

```dart
part of 'workbench_screen.dart';
```

- [ ] **Step 8: Move quick label widgets to `quick_label_bar.dart`**

Move these declarations, preserving their code exactly:

```text
_QuickLabelBar
_QuickLabelBarState
_QuickLabelChip
```

The file starts with:

```dart
part of 'workbench_screen.dart';
```

- [ ] **Step 9: Move feedback widgets and progress text to `workbench_feedback.dart`**

Move these declarations, preserving their code exactly:

```text
_AutoBoxesFeedback
_ImageImportProgressBanner
_importProgressText
```

The file starts with:

```dart
part of 'workbench_screen.dart';
```

- [ ] **Step 10: Move top-level helper functions to `workbench_helpers.dart`**

Move these declarations, preserving their code exactly:

```text
_keyboardModifierPressed
_imageWorkSummary
_boxOverlayDisplayLabel
_overlayBadgeSize
_boxDisplayNumbers
_boxDisplayNumber
_labelFor
_labelForShortcut
_shortcutForKey
_sidebarBoxGroups
_boxNeedsLabel
_boxIsInvalid
```

The file starts with:

```dart
part of 'workbench_screen.dart';
```

- [ ] **Step 11: Confirm no duplicate class declarations remain**

Run:

```powershell
rg "^(class|enum) " lib\ui\workbench -n
```

Expected: each moved class or enum appears exactly once in the workbench folder.

- [ ] **Step 12: Run focused analyzer or syntax check**

Run when Flutter is available:

```powershell
flutter analyze
```

Expected: no analyzer errors caused by missing private identifiers, missing imports, or duplicate declarations.

If Flutter is unavailable, run:

```powershell
rg "part of 'workbench_screen.dart';" lib\ui\workbench -n
rg "class WorkbenchScreen" lib\ui -n
```

Expected:

```text
lib\ui\workbench\workbench_shared.dart:1:part of 'workbench_screen.dart';
...
lib\ui\workbench\workbench_screen.dart:...:class WorkbenchScreen extends StatelessWidget {
```

---

### Task 4: Split Workbench Widget Tests

**Files:**
- Create: `test/ui/workbench/workbench_test_support.dart`
- Create: `test/ui/workbench/workbench_shell_test.dart`
- Create: `test/ui/workbench/image_queue_panel_test.dart`
- Create: `test/ui/workbench/canvas_interaction_test.dart`
- Create: `test/ui/workbench/canvas_overlay_test.dart`
- Create: `test/ui/workbench/center_toolbar_test.dart`
- Create: `test/ui/workbench/inspector_panel_test.dart`
- Create: `test/ui/workbench/quick_label_bar_test.dart`
- Create: `test/ui/workbench/export_and_completion_test.dart`
- Modify or delete: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: existing workbench widget tests and their helper classes.
- Produces: the same test coverage grouped by workbench responsibility.

- [ ] **Step 1: Create the test folder**

Run:

```powershell
New-Item -ItemType Directory -Force -Path test\ui\workbench
```

Expected:

```text
Directory: C:\workspace\bbox\test\ui
...
workbench
```

- [ ] **Step 2: Move shared test helpers into `workbench_test_support.dart`**

Move helper declarations from the bottom of `test/ui/workbench_widget_test.dart` into `test/ui/workbench/workbench_test_support.dart`, including:

```text
_FakeImageImportPicker
_DelayedWorkbenchDetector
```

Also move shared pump/build helpers and fixture helpers used by multiple tests. Keep their existing names during the first move.

The support file must import the same app, controller, annotation, detector, and Flutter test packages currently used by those helpers.

- [ ] **Step 3: Add a support import to each new split test file**

Each split test file starts with imports equivalent to:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workbench_test_support.dart';
```

Add any additional imports already required by the tests moved into that file.

- [ ] **Step 4: Move shell and top-bar tests**

Move tests whose names mention empty project, top bar, project context, global actions, save status, import menu, and import progress into:

```text
test/ui/workbench/workbench_shell_test.dart
```

Move these test name groups:

```text
empty project shows image folder as the primary next action
top bar presents project context and global actions
top bar groups context status document and edit actions
top bar action rail is visually subtle and aligned
workbench palette uses orange accent colors
top bar uses Korean undo redo tooltips
top bar image add appears after images exist
empty import menu can add an image folder
workbench shows importing progress
workbench shows scanning state before import total is known
```

- [ ] **Step 5: Move image queue tests**

Move queue, status, selection, and responsive side panel tests into:

```text
test/ui/workbench/image_queue_panel_test.dart
```

Move these test name groups:

```text
selecting an image updates the box list
desktop workbench gives queue and inspector more room
image queue rows use restrained desktop radius
medium workbench keeps compact side panel widths
image queue summarizes review progress
image list shows all images without status filters
```

- [ ] **Step 6: Move canvas interaction tests**

Move draw, pan, selection, keyboard, dragging, zoom, actual-size, fit, and resize gesture tests into:

```text
test/ui/workbench/canvas_interaction_test.dart
```

Move tests whose names include:

```text
canvas toolbar exposes select draw and pan tools
keyboard switches canvas tools predictably
default background drag pans instead of creating a box
draw tool creates
pan tool never creates boxes
select tool empty-space drag pans
mouse wheel zoom
space temporarily prioritizes panning
dragging a selected box moves
zoomed selected box drag
zoom keeps overlay box aligned
actual size and fit
dragging the resize handle
```

- [ ] **Step 7: Move canvas overlay tests**

Move overlay rendering, labels, resize handle visuals, z-order, semantics, and contrast tests into:

```text
test/ui/workbench/canvas_overlay_test.dart
```

Move tests whose names include:

```text
selected resize handles
selected box renders eight resize handles
overlay label
unselected unlabeled canvas boxes
selected unlabeled canvas box
canvas boxes expose the selection semantics label
selected box is rendered after overlapping unselected boxes
selected automatic box keeps high contrast gray styling
contrast layer does not block box interaction
```

- [ ] **Step 8: Move center toolbar tests**

Move toolbar grouping, auto boxes, clear boxes, and toolbar delete tests into:

```text
test/ui/workbench/center_toolbar_test.dart
```

Move tests whose names include:

```text
center toolbar
clear all boxes
auto boxes feedback
ctrl b runs auto boxes
ctrl b does not run auto boxes
automation toolbar exposes only auto boxes
center toolbar delete button removes selected box
```

- [ ] **Step 9: Move inspector tests**

Move right sidebar, box list, selected details, remove image, and inspector duplication tests into:

```text
test/ui/workbench/inspector_panel_test.dart
```

Move tests whose names include:

```text
right sidebar
box list selection updates overlay selection state
selected box details
selected box delete is not duplicated in the inspector
removes selected image from project after confirmation
inspector no longer duplicates labels or auto controls
```

- [ ] **Step 10: Move quick label tests**

Move global quick label and label creation tests into:

```text
test/ui/workbench/quick_label_bar_test.dart
```

Move tests whose names include:

```text
quick label
label shortcuts assign
drawn unlabeled box stays selected and shows quick labels
creates labels from the label management popover
```

- [ ] **Step 11: Move completion and export tests**

Move confirm, object-none, complete-and-next, disabled completion, and export warning tests into:

```text
test/ui/workbench/export_and_completion_test.dart
```

Move tests whose names include:

```text
proposal boxes keep confirm disabled until labeled
complete and next advances
ctrl enter completes and advances
enter alone does not complete
ctrl enter does not complete when a text input has focus
enter does not complete when a text input has focus
empty images can be confirmed as object none
export button shows warnings for unfinished work
```

- [ ] **Step 12: Remove the original monolithic test file after all tests are moved**

Run:

```powershell
rg "testWidgets\\(" test\ui\workbench_widget_test.dart
```

Expected after all test moves:

```text
```

Delete `test/ui/workbench_widget_test.dart` once it has no remaining tests.

- [ ] **Step 13: Verify test names still exist in split files**

Run:

```powershell
rg "testWidgets\\(" test\ui\workbench -n
```

Expected: split test files contain the moved workbench tests.

- [ ] **Step 14: Run split workbench tests when Flutter is available**

Run:

```powershell
flutter test test\ui\workbench
```

Expected: all split workbench tests pass.

If Flutter is unavailable, run:

```powershell
rg "_FakeImageImportPicker|_DelayedWorkbenchDetector" test\ui\workbench -n
rg "testWidgets\\(" test\ui\workbench -n
```

Expected: shared helper declarations appear in `workbench_test_support.dart`, and split test declarations appear across the new test files.

---

### Task 5: Final Verification And Cleanup

**Files:**
- Modify: any workbench or test file requiring import cleanup after Tasks 2-4.

**Interfaces:**
- Consumes: split workbench source and split widget tests.
- Produces: a verified, behavior-preserving structural cleanup.

- [ ] **Step 1: Check for stale imports or stale original files**

Run:

```powershell
rg "import 'workbench_screen.dart'|import \"workbench_screen.dart\"" lib test -n
rg "workbench_widget_test.dart" . -n
```

Expected: imports of `lib/ui/workbench_screen.dart` may remain because it is a compatibility export. No source file should reference deleted `test/ui/workbench_widget_test.dart`.

- [ ] **Step 2: Check workbench file sizes**

Run:

```powershell
Get-ChildItem -File -LiteralPath lib\ui\workbench | Select-Object Name,Length | Sort-Object Length -Descending
Get-ChildItem -File -LiteralPath test\ui\workbench | Select-Object Name,Length | Sort-Object Length -Descending
```

Expected: no single workbench source or split workbench test file is close to the original 100 KB monolith size.

- [ ] **Step 3: Run analyzer when Flutter is available**

Run:

```powershell
flutter analyze
```

Expected:

```text
No issues found!
```

If the project already had analyzer warnings before Task 1, expected output is the same baseline warnings and no new warnings caused by the split.

- [ ] **Step 4: Run full tests when Flutter is available**

Run:

```powershell
flutter test
```

Expected: all tests pass, or the same baseline failures recorded in Task 1 remain with no new failures from the split.

- [ ] **Step 5: Record final changed files instead of committing when no Git repository exists**

Run:

```powershell
Test-Path .git
```

Expected in the current workspace:

```text
False
```

When the result is `False`, record this final changed-file summary:

```text
Changed areas:
- docs/project-structure.md
- README.md
- lib/ui/workbench_screen.dart
- lib/ui/workbench/
- test/ui/workbench/

Git commit skipped because C:\workspace\bbox is not a Git repository.
```

When the result is `True`, commit with:

```powershell
git add docs README.md lib\ui test\ui
git commit -m "refactor: split workbench structure"
```

Expected:

```text
[branch ...] refactor: split workbench structure
```

---

## Self-Review

Spec coverage:

- Workbench UI split is covered by Tasks 2 and 3.
- Workbench test split is covered by Task 4.
- Repository and generated-artifact boundaries are covered by Task 1.
- Behavior preservation is covered by the global constraints and final verification in Task 5.
- Controller and detector non-goals are explicitly preserved by avoiding behavior changes to `AppController` and `lib/detector/detector.dart`.

Placeholder scan:

- No placeholder markers or empty implementation slots are present.
- Conditional verification behavior is explicit for the current no-Flutter and no-Git workspace.

Type consistency:

- `WorkbenchScreen` keeps the existing constructor.
- Part files use `part of 'workbench_screen.dart';`.
- The compatibility file exports `workbench/workbench_screen.dart`.
