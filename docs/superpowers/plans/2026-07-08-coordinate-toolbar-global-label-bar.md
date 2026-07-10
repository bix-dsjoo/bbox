# Coordinate Toolbar Global Label Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix bounding-box coordinate alignment, simplify current-image auto actions, move label shortcuts to a full-width bottom bar, and make existing projects work with shortcut labels.

**Architecture:** Keep the current Flutter app structure, but make the viewer use one coordinate transform for image layout and box interactions. Move current-image actions out of the right inspector into the center viewer toolbar, make the quick-label bar a workbench-level component, and add a small migration helper for label shortcuts during project load.

**Tech Stack:** Flutter desktop, Dart, existing `ChangeNotifier` controller pattern, existing `AnnotationProject` domain model, existing `flutter_test` widget/unit tests.

## Global Constraints

- Project files must store original-image pixel coordinates only.
- COCO export semantics must not change.
- `Auto boxes` replaces all visible boxes only after successful detection.
- `Auto boxes` must not expose a proposal-count toggle or numeric input.
- `Clear boxes` removes visible boxes immediately and must be recoverable with Undo.
- Existing label ids, names, colors, box label ids, and category ids must not change during shortcut migration.
- Main workflow UI copy should be Korean-first.
- This workspace is not a git repository, so each task ends with verification commands instead of commits.

---

## File Structure

- Modify `lib/viewer/viewport_transform.dart`: extend or reuse the transform API so canvas widgets can convert between original image coordinates and local display coordinates.
- Modify `lib/ui/workbench_screen.dart`: refactor viewer toolbar, canvas sizing, right inspector content, and global quick-label placement.
- Modify `lib/ui/app_controller.dart`: remove proposal-count state, add auto-box feedback state, and run shortcut migration after loading projects.
- Create `lib/annotation/label_shortcut_migration.dart`: pure helper for assigning missing shortcuts to existing labels.
- Modify `lib/ui/workbench_copy.dart`: Korean-first labels and feedback text.
- Modify `windows/runner/main.cpp`: increase default Windows window size.
- Test `test/viewer/viewport_transform_test.dart`: coordinate display/original conversion.
- Test `test/ui/workbench_widget_test.dart`: toolbar placement, inspector cleanup, global label bar, feedback.
- Test `test/ui/app_controller_test.dart`: shortcut migration, auto feedback, proposal-count removal behavior.
- Test `test/annotation/label_shortcut_migration_test.dart`: pure migration rules.

---

### Task 1: Unify Canvas Coordinate Mapping

**Files:**
- Modify: `lib/viewer/viewport_transform.dart`
- Modify: `lib/ui/workbench_screen.dart`
- Test: `test/viewer/viewport_transform_test.dart`
- Test: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: `AnnotatedImage.width`, `AnnotatedImage.height`, existing `ViewportTransform.fit`.
- Produces: `ViewportTransform.fitInside({required Size imageSize, required Size viewportSize, double paddingFactor = 0.92})`, `originalRectToScreen`, `screenRectToOriginal`.

- [ ] **Step 1: Add failing transform tests for padded fit**

Add tests to `test/viewer/viewport_transform_test.dart`:

```dart
test('fits portrait image with symmetric horizontal padding', () {
  final transform = ViewportTransform.fitInside(
    imageSize: const Size(3024, 4032),
    viewportSize: const Size(600, 600),
    paddingFactor: 0.92,
  );

  expect(transform.scale, closeTo(0.13690476, 0.000001));
  expect(transform.renderedImageSize.width, closeTo(414, 0.5));
  expect(transform.renderedImageSize.height, closeTo(552, 0.5));
  expect(transform.imageOrigin.dx, closeTo(93, 0.5));
  expect(transform.imageOrigin.dy, closeTo(24, 0.5));
});

test('converts overlay rectangles through the same origin and scale', () {
  final transform = ViewportTransform.fitInside(
    imageSize: const Size(3024, 4032),
    viewportSize: const Size(600, 600),
    paddingFactor: 0.92,
  );

  final original = Rect.fromLTWH(100, 200, 500, 600);
  final screen = transform.originalRectToScreen(original);
  final restored = transform.screenRectToOriginal(screen);

  expect(restored.left, closeTo(original.left, 0.0001));
  expect(restored.top, closeTo(original.top, 0.0001));
  expect(restored.width, closeTo(original.width, 0.0001));
  expect(restored.height, closeTo(original.height, 0.0001));
});
```

- [ ] **Step 2: Run transform tests and verify failure**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\viewer\viewport_transform_test.dart
```

Expected: fails because `ViewportTransform.fitInside` does not exist.

- [ ] **Step 3: Implement `ViewportTransform.fitInside`**

In `lib/viewer/viewport_transform.dart`, add:

```dart
  factory ViewportTransform.fitInside({
    required Size imageSize,
    required Size viewportSize,
    double paddingFactor = 1,
    double zoom = 1,
    Offset pan = Offset.zero,
  }) {
    final safePadding = paddingFactor.isFinite && paddingFactor > 0
        ? paddingFactor.clamp(0.05, 1).toDouble()
        : 1.0;
    final paddedViewport = Size(
      viewportSize.width * safePadding,
      viewportSize.height * safePadding,
    );
    final widthScale = paddedViewport.width / imageSize.width;
    final heightScale = paddedViewport.height / imageSize.height;
    final baseScale = widthScale < heightScale ? widthScale : heightScale;
    return ViewportTransform(
      imageSize: imageSize,
      viewportSize: viewportSize,
      baseScale: baseScale.isFinite && baseScale > 0 ? baseScale : 1,
      zoom: zoom <= 0 ? 1 : zoom,
      pan: pan,
    );
  }
```

- [ ] **Step 4: Run transform tests and verify pass**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\viewer\viewport_transform_test.dart
```

Expected: all tests pass.

- [ ] **Step 5: Update `_ImageCanvas` to use the same transform**

In `lib/ui/workbench_screen.dart`, replace scale-only layout in `_ImageCanvasState.build` with a transform:

```dart
final transform = ViewportTransform.fitInside(
  imageSize: Size(widget.image.width.toDouble(), widget.image.height.toDouble()),
  viewportSize: widget.viewerSize,
  paddingFactor: 0.92,
);
final canvasSize = transform.renderedImageSize;
final scale = transform.scale;
```

Keep the `SizedBox(width: canvasSize.width, height: canvasSize.height)` so the local canvas origin is the image origin inside the centered `InteractiveViewer` child. Use `BoxFit.fill` only inside this exact image-sized canvas. The important invariant is: the image, overlay boxes, drawing preview, move deltas, and resize deltas all use this same `scale`.

- [ ] **Step 6: Add widget regression for box alignment dimensions**

In `test/ui/workbench_widget_test.dart`, add a test that pumps a project with a known `3024 x 4032` image and a known box. Assert the rendered box widget has size proportional to the displayed image scale and does not exceed the canvas bounds:

```dart
testWidgets('overlay boxes use the same scale as the displayed image', (tester) async {
  final project = _project().copyWith(
    images: [
      _image().copyWith(
        id: 1,
        width: 3024,
        height: 4032,
        boxes: const [
          BoundingBox(
            id: 1,
            x: 100,
            y: 200,
            width: 500,
            height: 600,
            status: BoxStatus.proposal,
          ),
        ],
      ),
    ],
  );
  final controller = _controllerWith(project);
  controller.selectImage(1);

  await tester.pumpWidget(_workbench(controller));
  await tester.pumpAndSettle();

  final boxSize = tester.getSize(find.byKey(const ValueKey('box-1')));
  expect(boxSize.width / boxSize.height, closeTo(500 / 600, 0.01));
});
```

- [ ] **Step 7: Run focused viewer/widget tests**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\viewer\viewport_transform_test.dart test\ui\workbench_widget_test.dart
```

Expected: pass.

---

### Task 2: Add Existing Project Shortcut Migration

**Files:**
- Create: `lib/annotation/label_shortcut_migration.dart`
- Modify: `lib/ui/app_controller.dart`
- Test: `test/annotation/label_shortcut_migration_test.dart`
- Test: `test/ui/app_controller_test.dart`

**Interfaces:**
- Produces: `AnnotationProject migrateMissingLabelShortcuts(AnnotationProject project)`.
- Consumes: `quickLabelShortcutSet` and `LabelClass.copyWith`.

- [ ] **Step 1: Write migration unit tests**

Create `test/annotation/label_shortcut_migration_test.dart`:

```dart
import 'package:bbox_labeler/annotation/label_shortcut_migration.dart';
import 'package:bbox_labeler/annotation/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fills missing shortcuts without changing label ids or names', () {
    final project = AnnotationProject(
      name: 'Old',
      imageFolderPath: 'C:/images',
      labels: const [
        LabelClass(id: 10, name: 'Bread', color: 0xff111111),
        LabelClass(id: 20, name: 'Cream', color: 0xff222222),
      ],
    );

    final migrated = migrateMissingLabelShortcuts(project);

    expect(migrated.labels[0].id, 10);
    expect(migrated.labels[0].name, 'Bread');
    expect(migrated.labels[0].shortcut, '1');
    expect(migrated.labels[1].id, 20);
    expect(migrated.labels[1].shortcut, '2');
  });

  test('preserves valid existing shortcuts and fills free slots', () {
    final project = AnnotationProject(
      name: 'Mixed',
      imageFolderPath: 'C:/images',
      labels: const [
        LabelClass(id: 1, name: 'Bread', color: 0xff111111, shortcut: '3'),
        LabelClass(id: 2, name: 'Cream', color: 0xff222222),
      ],
    );

    final migrated = migrateMissingLabelShortcuts(project);

    expect(migrated.labels[0].shortcut, '3');
    expect(migrated.labels[1].shortcut, '1');
  });
}
```

- [ ] **Step 2: Run migration tests and verify failure**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\annotation\label_shortcut_migration_test.dart
```

Expected: fails because the file/function does not exist.

- [ ] **Step 3: Implement migration helper**

Create `lib/annotation/label_shortcut_migration.dart`:

```dart
import 'annotation_rules.dart';
import 'models.dart';

AnnotationProject migrateMissingLabelShortcuts(AnnotationProject project) {
  final used = <String>{};
  for (final label in project.labels) {
    final shortcut = label.shortcut;
    if (shortcut != null && quickLabelShortcutSet.contains(shortcut)) {
      used.add(shortcut);
    }
  }

  final free = quickLabelShortcutSet.where((shortcut) => !used.contains(shortcut)).iterator;
  var changed = false;
  final migratedLabels = <LabelClass>[];
  for (final label in project.labels) {
    final shortcut = label.shortcut;
    if (shortcut != null && quickLabelShortcutSet.contains(shortcut)) {
      migratedLabels.add(label);
      continue;
    }
    if (free.moveNext()) {
      migratedLabels.add(label.copyWith(shortcut: free.current));
      changed = true;
    } else {
      migratedLabels.add(label.copyWith(shortcut: null));
      changed = changed || shortcut != null;
    }
  }

  return changed ? project.copyWith(labels: migratedLabels) : project;
}
```

- [ ] **Step 4: Add controller migration test**

In `test/ui/app_controller_test.dart`, add a load/open-project test using the existing memory project library pattern. It should verify labels without shortcuts gain `1` and `2` after opening and that box label ids are unchanged:

```dart
test('opening an old project migrates missing label shortcuts', () async {
  final project = _project().copyWith(
    labels: const [
      LabelClass(id: 10, name: 'Bread', color: 0xff111111),
      LabelClass(id: 20, name: 'Cream', color: 0xff222222),
    ],
    images: [
      _image().copyWith(
        boxes: const [
          BoundingBox(id: 1, x: 1, y: 2, width: 3, height: 4, labelId: 20),
        ],
      ),
    ],
  );
  final controller = AppController(projectLibrary: MemoryProjectLibrary(project));

  await controller.openRecentProject(project.projectFilePath!);

  expect(controller.project!.labels[0].shortcut, '1');
  expect(controller.project!.labels[1].shortcut, '2');
  expect(controller.project!.images.first.boxes.first.labelId, 20);
});
```

- [ ] **Step 5: Wire migration into project open/load**

In `lib/ui/app_controller.dart`, import the helper and run it immediately after loading a project from storage/library:

```dart
final loaded = await _projectLibrary.open(projectFilePath);
final migrated = migrateMissingLabelShortcuts(loaded);
_project = migrated;
if (!identical(migrated, loaded)) {
  _scheduleAutoSave();
}
```

Apply the same migration path wherever existing projects are loaded.

- [ ] **Step 6: Run focused migration tests**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\annotation\label_shortcut_migration_test.dart test\ui\app_controller_test.dart
```

Expected: pass.

---

### Task 3: Remove Proposal Count And Add Auto Feedback State

**Files:**
- Modify: `lib/ui/app_controller.dart`
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `lib/ui/workbench_copy.dart`
- Test: `test/ui/app_controller_test.dart`
- Test: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Produces: `String? AppController.lastUserMessage`.
- Removes UI dependency on `proposalCountEnabled`, `proposalCount`, `setProposalCountEnabled`, and `_ProposalCountInput`.
- Keeps detector interface compatible by calling `detectSelectedImage()` without `DetectionOptions(maxProposals: ...)`.

- [ ] **Step 1: Add controller feedback tests**

In `test/ui/app_controller_test.dart`, add tests:

```dart
test('auto boxes reports success count', () async {
  final controller = _controllerWith(_projectWithSelectedImage());
  await controller.detectSelectedImage(detector: FakeDetector(boxes: [
    const BoundingBox(id: 1, x: 1, y: 1, width: 10, height: 10, status: BoxStatus.proposal),
  ]));

  expect(controller.lastUserMessage, '후보 박스 1개 생성됨');
});

test('auto boxes reports zero result', () async {
  final controller = _controllerWith(_projectWithSelectedImage());
  await controller.detectSelectedImage(detector: FakeDetector(boxes: const []));

  expect(controller.lastUserMessage, '후보를 찾지 못했습니다');
});

test('auto boxes failure reports that existing boxes are preserved', () async {
  final controller = _controllerWith(_projectWithSelectedImage());
  await controller.detectSelectedImage(detector: ThrowingDetector());

  expect(controller.lastUserMessage, '자동 박스 생성 실패. 기존 박스는 유지됩니다');
});
```

- [ ] **Step 2: Run controller tests and verify failure**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\app_controller_test.dart
```

Expected: fails because `lastUserMessage` does not exist or messages are not set.

- [ ] **Step 3: Add Korean feedback copy**

In `lib/ui/workbench_copy.dart`, add:

```dart
static const autoBoxesRunning = '자동 박스 생성 중';
static const autoBoxesEmpty = '후보를 찾지 못했습니다';
static const autoBoxesFailed = '자동 박스 생성 실패. 기존 박스는 유지됩니다';
static String autoBoxesCreated(int count) => '후보 박스 $count개 생성됨';
```

- [ ] **Step 4: Add feedback state to controller**

In `lib/ui/app_controller.dart`, add:

```dart
String? lastUserMessage;
void clearLastUserMessage() {
  lastUserMessage = null;
  notifyListeners();
}
```

Set `lastUserMessage` in `detectSelectedImage`:

```dart
lastUserMessage = WorkbenchCopy.autoBoxesRunning;
notifyListeners();
```

On success:

```dart
lastUserMessage = result.boxes.isEmpty
    ? WorkbenchCopy.autoBoxesEmpty
    : WorkbenchCopy.autoBoxesCreated(result.boxes.length);
```

On thrown or returned error:

```dart
lastUserMessage = WorkbenchCopy.autoBoxesFailed;
```

- [ ] **Step 5: Remove proposal-count controller state and UI**

Remove these from `AppController` and tests:

```dart
bool proposalCountEnabled;
int proposalCount;
void setProposalCountEnabled(bool value);
void setProposalCount(int value);
```

Remove `_ProposalCountInput` from `lib/ui/workbench_screen.dart` and remove `WorkbenchCopy.proposalCount` / `WorkbenchCopy.proposalCountOption`.

- [ ] **Step 6: Update auto button call**

In `_InspectorPanelState._runAutoBoxes` or the moved toolbar action, call:

```dart
await widget.controller.detectSelectedImage();
```

No `DetectionOptions(maxProposals: ...)` should be created from UI state.

- [ ] **Step 7: Add widget feedback assertion**

In `test/ui/workbench_widget_test.dart`, assert that when `controller.lastUserMessage` is set, the workbench shows it in a `SnackBar` or inline status widget with key `auto-boxes-feedback`:

```dart
expect(find.byKey(const ValueKey('auto-boxes-feedback')), findsOneWidget);
expect(find.text('후보 박스 1개 생성됨'), findsOneWidget);
```

- [ ] **Step 8: Run focused tests**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\app_controller_test.dart test\ui\workbench_widget_test.dart
```

Expected: pass.

---

### Task 4: Move Auto/Clear Controls To Center Toolbar And Clean Inspector

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `lib/ui/workbench_copy.dart`
- Test: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: `AppController.detectSelectedImage`, `AppController.clearSelectedImageBoxes`, `AppController.lastUserMessage`.
- Produces: toolbar widgets with keys `center-auto-boxes-toolbar`, `auto-boxes-current-image`, `clear-current-image-boxes`.

- [ ] **Step 1: Add widget tests for toolbar location and inspector cleanup**

In `test/ui/workbench_widget_test.dart`, add:

```dart
testWidgets('auto and clear boxes live in the center toolbar', (tester) async {
  final controller = _controllerWith(_projectWithSelectedImage());
  await tester.pumpWidget(_workbench(controller));

  expect(find.byKey(const ValueKey('center-auto-boxes-toolbar')), findsOneWidget);
  expect(find.descendant(
    of: find.byKey(const ValueKey('center-auto-boxes-toolbar')),
    matching: find.byKey(const ValueKey('auto-boxes-current-image')),
  ), findsOneWidget);
  expect(find.descendant(
    of: find.byKey(const ValueKey('center-auto-boxes-toolbar')),
    matching: find.byKey(const ValueKey('clear-current-image-boxes')),
  ), findsOneWidget);
});

testWidgets('inspector no longer duplicates labels or auto controls', (tester) async {
  final controller = _controllerWith(_projectWithSelectedImage());
  await tester.pumpWidget(_workbench(controller));

  final inspector = find.byKey(const ValueKey('inspector-panel'));
  expect(find.descendant(of: inspector, matching: find.text('라벨')), findsNothing);
  expect(find.descendant(of: inspector, matching: find.byKey(const ValueKey('auto-boxes-current-image'))), findsNothing);
  expect(find.descendant(of: inspector, matching: find.byKey(const ValueKey('clear-current-image-boxes'))), findsNothing);
});
```

- [ ] **Step 2: Run widget tests and verify failure**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart
```

Expected: fails because controls are still in the inspector.

- [ ] **Step 3: Add top action toolbar to `_ViewerPanel`**

In `_ViewerPanelState.build`, above the existing canvas tool buttons, add:

```dart
SizedBox(
  height: 48,
  child: Center(
    child: _CanvasActionToolbar(
      controller: widget.controller,
      image: image,
    ),
  ),
),
```

Create `_CanvasActionToolbar` in `workbench_screen.dart`:

```dart
class _CanvasActionToolbar extends StatelessWidget {
  const _CanvasActionToolbar({required this.controller, required this.image});

  final AppController controller;
  final AnnotatedImage image;

  @override
  Widget build(BuildContext context) {
    final detecting = image.status == ImageStatus.detecting;
    return Row(
      key: const ValueKey('center-auto-boxes-toolbar'),
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.icon(
          key: const ValueKey('auto-boxes-current-image'),
          onPressed: detecting ? null : controller.detectSelectedImage,
          icon: detecting
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_fix_high),
          label: Text(detecting ? WorkbenchCopy.autoBoxesRunning : WorkbenchCopy.autoBoxes),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          key: const ValueKey('clear-current-image-boxes'),
          onPressed: controller.clearSelectedImageBoxes,
          icon: const Icon(Icons.layers_clear_outlined),
          label: const Text(WorkbenchCopy.clearBoxes),
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: Remove auto/clear/labels section from `_InspectorPanel`**

Delete the inspector section that renders:

```dart
const _SectionTitle('Auto boxes')
FilledButton.icon(key: ValueKey('auto-boxes-current-image'), ...)
SwitchListTile(key: ValueKey('proposal-count-toggle'), ...)
_ProposalCountInput(...)
OutlinedButton.icon(key: ValueKey('clear-current-image-boxes'), ...)
const _SectionTitle(WorkbenchCopy.labels)
Text('${widget.project.labels.length} labels')
```

Keep the `Boxes` section and selected-box details.

- [ ] **Step 5: Account for taller toolbar in viewer viewport**

Change the viewport height subtraction from `48` to `96` because the center viewer now has two toolbar rows:

```dart
final canvasViewport = Size(viewerSize.width, viewerSize.height - 96);
```

- [ ] **Step 6: Run widget tests**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart
```

Expected: pass.

---

### Task 5: Make Quick Labels A Global Bottom Bar With Fallback

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `lib/ui/workbench_copy.dart`
- Test: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: existing `_QuickLabelBar`, `LabelManagementPopover`, `AppController.assignSelectedBoxLabel`.
- Produces: global bar key `global-quick-label-bar`; fallback keys `quick-label-empty-state`, `open-label-management`.

- [ ] **Step 1: Add widget tests for global bar and fallback**

In `test/ui/workbench_widget_test.dart`, add:

```dart
testWidgets('quick label bar is global below the full workbench', (tester) async {
  final controller = _controllerWith(_projectWithSelectedImage());
  await tester.pumpWidget(_workbench(controller));

  expect(find.byKey(const ValueKey('global-quick-label-bar')), findsOneWidget);
  expect(find.byKey(const ValueKey('center-quick-label-bar')), findsNothing);
});

testWidgets('quick label bar shows empty shortcut state', (tester) async {
  final project = _projectWithSelectedImage().copyWith(
    labels: const [
      LabelClass(id: 1, name: 'Bread', color: 0xff111111),
    ],
  );
  final controller = _controllerWith(project);
  await tester.pumpWidget(_workbench(controller));

  expect(find.byKey(const ValueKey('quick-label-empty-state')), findsOneWidget);
  expect(find.text('라벨 단축키가 없습니다'), findsOneWidget);
  expect(find.byKey(const ValueKey('open-label-management')), findsOneWidget);
});
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart
```

Expected: fails because the quick-label bar still lives inside `_ViewerPanel`.

- [ ] **Step 3: Move `_QuickLabelBar` to the workbench root column**

In `WorkbenchScreen.build`, change the main `Column` so the `Expanded` workbench row is followed by:

```dart
Container(
  key: const ValueKey('global-quick-label-bar'),
  decoration: const BoxDecoration(
    color: _workbenchPanel,
    border: Border(top: BorderSide(color: _workbenchBorder)),
  ),
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  child: _QuickLabelBar(
    controller: controller,
    project: project,
  ),
),
```

Remove the `center-quick-label-bar` container from `_ViewerPanelState.build`.

- [ ] **Step 4: Update `_QuickLabelBar` layout for full width**

Keep two rows, but make the bar height stable and put the `+` management button at the end of the rows:

```dart
return SizedBox(
  height: 82,
  child: SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabelRow(firstRow),
        const SizedBox(height: 6),
        Row(children: [
          ..._chipsFor(secondRow),
          _buildManageLabelsButton(),
        ]),
      ],
    ),
  ),
);
```

- [ ] **Step 5: Add fallback empty state**

Inside `_QuickLabelBarState.build`, before splitting rows:

```dart
if (quickLabels.isEmpty) {
  final message = widget.project.labels.isEmpty
      ? WorkbenchCopy.addLabelsEmpty
      : WorkbenchCopy.noLabelShortcuts;
  return SizedBox(
    height: 48,
    child: Row(
      key: const ValueKey('quick-label-empty-state'),
      children: [
        Text(message),
        const SizedBox(width: 8),
        _buildManageLabelsButton(),
      ],
    ),
  );
}
```

Add copy:

```dart
static const noLabelShortcuts = '라벨 단축키가 없습니다';
static const addLabelsEmpty = '라벨을 추가하세요';
static const manageLabels = '라벨 관리';
```

- [ ] **Step 6: Run widget tests**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart
```

Expected: pass.

---

### Task 6: Korean-First Copy And Larger Windows Default Size

**Files:**
- Modify: `lib/ui/workbench_copy.dart`
- Modify: `lib/ui/label_management_popover.dart`
- Modify: `windows/runner/main.cpp`
- Test: `test/ui/workbench_widget_test.dart`
- Test: `test/ui/label_management_popover_test.dart`

**Interfaces:**
- Produces Korean-first strings through `WorkbenchCopy`.
- Produces default Windows size `1600 x 950`.

- [ ] **Step 1: Add copy expectation tests**

In `test/ui/workbench_widget_test.dart`, update visible text expectations to Korean:

```dart
expect(find.text('이미지'), findsOneWidget);
expect(find.text('자동 박스'), findsOneWidget);
expect(find.text('박스 전체 삭제'), findsOneWidget);
```

In `test/ui/label_management_popover_test.dart`, update label management expectations:

```dart
expect(find.text('라벨 이름'), findsOneWidget);
expect(find.text('키'), findsOneWidget);
expect(find.text('추가'), findsOneWidget);
```

- [ ] **Step 2: Run UI tests and verify failure**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart test\ui\label_management_popover_test.dart
```

Expected: fails while English copy remains.

- [ ] **Step 3: Replace main workflow copy in `WorkbenchCopy`**

Use these exact values:

```dart
static const projectHome = '프로젝트 홈';
static const imageAdd = '이미지 추가';
static const cocoExport = 'COCO 내보내기';
static const saved = '저장됨';
static const saving = '저장 중';
static const saveFailed = '저장 실패';
static const images = '이미지';
static const all = '전체';
static const needsReview = '미확정';
static const confirmed = '확정';
static const error = '오류';
static const unlabeled = '미라벨';
static const selectedImage = '선택 이미지';
static const boxes = '박스';
static const selectedBox = '선택 박스';
static const noBoxes = '박스 없음';
static const unlabeledBox = '미라벨';
static const proposalBox = '후보';
static const confirm = '확정';
static const confirmNoObject = '객체 없음으로 확정';
static const deleteSelectedBox = '선택 박스 삭제';
static const removeImageFromProject = '이미지 제거';
static const selectMoveTool = '선택';
static const drawBoxTool = '박스 그리기';
static const panTool = '이동';
static const autoBoxes = '자동 박스';
static const clearBoxes = '박스 전체 삭제';
```

Update `imageStatusLabel` to return Korean values.

- [ ] **Step 4: Update label management popover copy**

In `lib/ui/label_management_popover.dart`, replace inline text:

```dart
labelText: '라벨 이름'
labelText: '키'
Text(isEditing ? '수정' : '추가')
```

Use Korean error messages for empty name and unsupported shortcut.

- [ ] **Step 5: Increase Windows default window size**

In `windows/runner/main.cpp`, change:

```cpp
Win32Window::Size size(1600, 950);
```

- [ ] **Step 6: Run UI tests**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart test\ui\label_management_popover_test.dart
```

Expected: pass.

---

### Task 7: Full Verification And Manual Smoke

**Files:**
- Verify all modified files.

**Interfaces:**
- Consumes all previous tasks.
- Produces a working Windows build.

- [ ] **Step 1: Run analyzer**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat analyze
```

Expected: `No issues found!`

- [ ] **Step 2: Run all tests**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test
```

Expected: all tests pass.

- [ ] **Step 3: Build Windows app**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat build windows
```

Expected: build succeeds and updates `build\windows\x64\runner\Release\bbox_labeler.exe`.

- [ ] **Step 4: Manual smoke test**

Open the built app and verify:

- Existing dataset project opens.
- Labels with missing shortcuts are visible in the global bottom bar.
- Selecting a box and pressing `1` assigns the first label.
- `자동 박스` and `박스 전체 삭제` appear above the canvas.
- The right inspector does not show label summary.
- `박스 전체 삭제` removes boxes and Undo restores them.
- `자동 박스` shows visible feedback.
- Boxes visually align with objects in the sample dataset.

---

## Self-Review Notes

- Spec coverage: all coordinate, toolbar, global label bar, migration, feedback, Korean copy, proposal-count removal, and window-size requirements are covered.
- Placeholder scan: no `TBD`, `TODO`, or incomplete implementation placeholders are intentionally left.
- Type consistency: introduced `migrateMissingLabelShortcuts(AnnotationProject)`, `lastUserMessage`, `clearLastUserMessage`, and `ViewportTransform.fitInside`; later tasks use the same names.
