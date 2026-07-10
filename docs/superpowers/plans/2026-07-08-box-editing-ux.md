# Box Editing UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make box editing feel correct under zoom, add eight resize anchors, keep selected boxes in their semantic color, and expose selected-box deletion in the center toolbar.

**Architecture:** Add small pure interaction helpers in `lib/ui/canvas_interaction.dart` for zoom-normalized deltas, resize handles, and resized rectangle calculation. Wire those helpers into `WorkbenchScreen` and `AppController` so the canvas renders eight handles and updates original-image coordinates safely.

**Tech Stack:** Flutter desktop, Dart, existing `ChangeNotifier` controller, existing `flutter_test` unit/widget tests.

## Global Constraints

- Project data must keep original-image pixel coordinates.
- COCO export behavior must not change.
- Delete and Backspace shortcuts must keep working.
- Selection must not replace proposal gray or label color with yellow.
- This workspace is not a git repository, so verification replaces commit steps.

---

## File Structure

- Modify `lib/ui/canvas_interaction.dart`: add `CanvasResizeHandle`, handle hit rects, zoom-normalized delta helper, and resize rectangle helper.
- Modify `lib/ui/app_controller.dart`: add `setSelectedBoxGeometry` for x/y/width/height updates from resize handles.
- Modify `lib/ui/workbench_screen.dart`: pass current `InteractiveViewer` zoom into overlays, render eight resize handles, update selected style, and add toolbar delete button.
- Modify `lib/ui/workbench_copy.dart`: add/delete toolbar copy if needed.
- Test `test/ui/canvas_interaction_test.dart`: pure resize and zoom math.
- Test `test/ui/app_controller_test.dart`: selected box geometry update clamps correctly.
- Test `test/ui/workbench_widget_test.dart`: eight handles, toolbar delete, selected color style.

---

### Task 1: Pure Resize And Zoom Helpers

**Files:**
- Modify: `lib/ui/canvas_interaction.dart`
- Test: `test/ui/canvas_interaction_test.dart`

**Interfaces:**
- Produces: `enum CanvasResizeHandle`
- Produces: `double originalDeltaFromScreenDelta({required double screenDelta, required double displayScale, required double zoom})`
- Produces: `Rect resizeOriginalRect({required Rect startRect, required Offset originalDelta, required CanvasResizeHandle handle, required Size imageSize, double minSize = 2})`

- [ ] **Step 1: Write failing tests**

Add tests for zoom delta and every handle:

```dart
test('screen deltas are divided by display scale and zoom', () {
  expect(
    originalDeltaFromScreenDelta(screenDelta: 20, displayScale: 2, zoom: 1),
    10,
  );
  expect(
    originalDeltaFromScreenDelta(screenDelta: 20, displayScale: 2, zoom: 4),
    2.5,
  );
});

test('topLeft resize moves top and left while keeping bottom right fixed', () {
  final rect = resizeOriginalRect(
    startRect: const Rect.fromLTWH(20, 20, 40, 30),
    originalDelta: const Offset(5, 6),
    handle: CanvasResizeHandle.topLeft,
    imageSize: const Size(100, 100),
  );

  expect(rect, const Rect.fromLTWH(25, 26, 35, 24));
});

test('right resize changes only the right side', () {
  final rect = resizeOriginalRect(
    startRect: const Rect.fromLTWH(20, 20, 40, 30),
    originalDelta: const Offset(10, 7),
    handle: CanvasResizeHandle.right,
    imageSize: const Size(100, 100),
  );

  expect(rect, const Rect.fromLTWH(20, 20, 50, 30));
});

test('resize clamps at minimum size instead of flipping', () {
  final rect = resizeOriginalRect(
    startRect: const Rect.fromLTWH(20, 20, 40, 30),
    originalDelta: const Offset(100, 100),
    handle: CanvasResizeHandle.topLeft,
    imageSize: const Size(100, 100),
    minSize: 2,
  );

  expect(rect.left, 58);
  expect(rect.top, 48);
  expect(rect.width, 2);
  expect(rect.height, 2);
});
```

- [ ] **Step 2: Run failing tests**

Run: `C:\tools\flutter\bin\flutter.bat test test\ui\canvas_interaction_test.dart`

Expected: fails because helper APIs do not exist.

- [ ] **Step 3: Implement helpers**

Add the enum and functions to `lib/ui/canvas_interaction.dart`.

- [ ] **Step 4: Run tests**

Run: `C:\tools\flutter\bin\flutter.bat test test\ui\canvas_interaction_test.dart`

Expected: pass.

---

### Task 2: Controller Geometry Update

**Files:**
- Modify: `lib/ui/app_controller.dart`
- Test: `test/ui/app_controller_test.dart`

**Interfaces:**
- Consumes: `AnnotationRules.clampBox`
- Produces: `void setSelectedBoxGeometry({required double x, required double y, required double width, required double height})`

- [ ] **Step 1: Write failing controller test**

Add:

```dart
test('setSelectedBoxGeometry updates all selected box coordinates', () {
  final controller = AppController()..loadProject(_project());
  controller.selectBox('box-1');

  controller.setSelectedBoxGeometry(x: 10, y: 12, width: 30, height: 28);

  final box = controller.selectedImage!.visibleBoxes.single;
  expect(box.x, 10);
  expect(box.y, 12);
  expect(box.width, 30);
  expect(box.height, 28);
});
```

- [ ] **Step 2: Run failing test**

Run: `C:\tools\flutter\bin\flutter.bat test test\ui\app_controller_test.dart`

Expected: fails because `setSelectedBoxGeometry` does not exist.

- [ ] **Step 3: Implement controller method**

Use `_editSelectedBox` and `AnnotationRules.clampBox` to update x/y/width/height.

- [ ] **Step 4: Run test**

Run: `C:\tools\flutter\bin\flutter.bat test test\ui\app_controller_test.dart`

Expected: pass.

---

### Task 3: Wire Zoom-Correct Move And Eight Handles

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Test: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: `originalDeltaFromScreenDelta`, `resizeOriginalRect`, `CanvasResizeHandle`
- Consumes: `AppController.setSelectedBoxGeometry`
- Produces: handle keys `resize-handle-<boxId>-<handleName>`

- [ ] **Step 1: Write failing widget tests**

Add tests that selected boxes render eight handles and zoomed movement is slower in original coordinates:

```dart
testWidgets('selected box renders eight resize handles', (tester) async {
  final controller = AppController()..loadProject(_project());
  controller.selectBox('box-1');

  await tester.pumpWidget(_app(controller));

  for (final handle in [
    'topLeft',
    'top',
    'topRight',
    'left',
    'right',
    'bottomLeft',
    'bottom',
    'bottomRight',
  ]) {
    expect(find.byKey(ValueKey('resize-handle-box-1-$handle')), findsOneWidget);
  }
});
```

- [ ] **Step 2: Run failing test**

Run: `C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart`

Expected: fails because only one handle exists.

- [ ] **Step 3: Pass current zoom into `_ImageCanvas` and `_OverlayBox`**

Use `_transform.value.getMaxScaleOnAxis()` from `_ViewerPanelState`, add a listener to rebuild when the transform changes, and pass `zoom` down.

- [ ] **Step 4: Render eight handles**

Replace the single bottom-right aligned handle with handle widgets positioned around the selected box.

- [ ] **Step 5: Use zoom-normalized deltas**

Move: divide pointer screen delta by `scale * zoom`.

Resize: convert pointer screen delta to original delta, call `resizeOriginalRect`, then call `setSelectedBoxGeometry`.

- [ ] **Step 6: Run widget tests**

Run: `C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart`

Expected: pass.

---

### Task 4: Toolbar Delete And Selected Style

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `lib/ui/workbench_copy.dart`
- Test: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: `AppController.deleteSelectedBox`
- Produces: toolbar key `delete-selected-box-toolbar`

- [ ] **Step 1: Write failing tests**

Add tests:

```dart
testWidgets('center toolbar delete button removes selected box', (tester) async {
  final controller = AppController()..loadProject(_project());
  controller.selectBox('box-1');

  await tester.pumpWidget(_app(controller));
  await tester.tap(find.byKey(const ValueKey('delete-selected-box-toolbar')));
  await tester.pump();

  expect(controller.selectedImage!.visibleBoxes, isEmpty);
});

testWidgets('selected proposal box keeps gray semantic color', (tester) async {
  final controller = AppController()..loadProject(_project());
  controller.selectBox('box-1');

  await tester.pumpWidget(_app(controller));

  final box = tester.widget<Container>(
    find.byKey(const ValueKey('selected-box-box-1')),
  );
  final decoration = box.decoration! as BoxDecoration;
  expect(decoration.border!.top.color, isNot(Colors.amberAccent));
});
```

- [ ] **Step 2: Run failing tests**

Run: `C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart`

Expected: fails because toolbar delete is missing and selected color is yellow.

- [ ] **Step 3: Add toolbar delete button**

Add `선택 박스 삭제` to `_CanvasActionToolbar`, disabled when `selectedBoxId == null`.

- [ ] **Step 4: Remove duplicate inspector delete button**

Remove the bottom inspector delete button so deletion is no longer hidden in the scroll area.

- [ ] **Step 5: Update selected style**

Use the box base color for selected border and fill. Increase border width/fill alpha instead of switching to yellow.

- [ ] **Step 6: Run tests**

Run: `C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart`

Expected: pass.

---

### Task 5: Full Verification

**Files:**
- Verify all modified files.

- [ ] **Step 1: Format**

Run: `C:\tools\flutter\bin\dart.bat format lib test`

- [ ] **Step 2: Analyze**

Run: `C:\tools\flutter\bin\flutter.bat analyze`

Expected: no issues.

- [ ] **Step 3: Test**

Run: `C:\tools\flutter\bin\flutter.bat test`

Expected: all tests pass.

- [ ] **Step 4: Build**

Run: `C:\tools\flutter\bin\flutter.bat build windows`

Expected: build succeeds and updates `build\windows\x64\runner\Release\bbox_labeler.exe`.

## Self-Review Notes

- Spec coverage: zoom-correct editing, eight anchors, toolbar delete, selection style, tests, and verification are covered.
- Placeholder scan: no placeholder steps remain.
- Type consistency: helper names and widget keys are consistent across tasks.
