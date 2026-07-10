# Canvas Interaction Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the central image canvas mouse interactions predictable by separating select/pan, draw-box, and pan-only tool modes.

**Architecture:** Add a small testable canvas interaction model for tool state, hit targets, pointer action resolution, and coordinate conversion. Then wire that model into `WorkbenchScreen` so background drags pan by default, new boxes are only created in draw-box mode, and box move/resize gestures remain explicit.

**Tech Stack:** Flutter desktop, Dart, Material 3, existing `AppController`, widget tests with `flutter_test`, `C:\tools\flutter\bin\flutter.bat`, and `C:\tools\flutter\bin\cache\dart-sdk\bin\dart.exe`.

## Global Constraints

- Do not change annotation data models.
- Do not change COCO export behavior.
- Do not change project save/load behavior.
- Keep all coordinates stored in original image pixel coordinates.
- Keep existing undo/redo/delete shortcuts.
- Default canvas mode must be select/move, not draw.
- Background drag in select/move mode must pan the image and must not create boxes.
- New boxes must be created only in draw-box mode.
- `Space` held down must temporarily prioritize image panning.
- `Esc` must cancel drawing and return to select/move mode.
- Visible UI copy must use clean Korean text via `WorkbenchCopy`.
- Do not add a new design dependency.
- In this workspace, `Test-Path .git` is currently `False` and `git` is not on `PATH`; if still true during execution, skip commit steps and report it.

---

## File Structure

- Create `lib/ui/canvas_interaction.dart`
  - Owns `CanvasTool`, `CanvasPointerActionKind`, hit target types, gesture resolution, and coordinate conversion helpers.
  - Does not depend on app state or widgets beyond Flutter geometry types.

- Create `test/ui/canvas_interaction_test.dart`
  - Unit-tests gesture priority and coordinate conversion.

- Modify `lib/ui/workbench_copy.dart`
  - Adds stable Korean tooltip labels for canvas tools.

- Modify `lib/ui/workbench_screen.dart`
  - Adds selected canvas tool state to `_ViewerPanelState`.
  - Adds tool buttons to the canvas toolbar.
  - Wires `B`, `Esc`, and `Space` keyboard behavior.
  - Changes `_ImageCanvas` so background drag draws only in `CanvasTool.drawBox`.
  - Keeps box movement/resizing explicit and adds cursor feedback.

- Modify `test/ui/workbench_widget_test.dart`
  - Adds widget tests for default panning behavior, draw mode box creation, tool buttons, and box edit gestures.

---

### Task 1: Canvas Interaction Model

**Files:**
- Create: `lib/ui/canvas_interaction.dart`
- Create: `test/ui/canvas_interaction_test.dart`

**Interfaces:**
- Produces:
  - `enum CanvasTool { select, drawBox, pan }`
  - `enum CanvasPointerActionKind { idle, panningCanvas, drawingBox, movingBox, resizingBox, selectingBox }`
  - `enum CanvasHitTargetType { background, box, resizeHandle }`
  - `class CanvasHitTarget`
  - `class CanvasBoxHitArea`
  - `CanvasPointerActionKind resolveCanvasPointerAction({required CanvasTool tool, required bool spacePressed, required String? selectedBoxId, required CanvasHitTarget hitTarget})`
  - `CanvasHitTarget hitTestCanvas({required Offset canvasPoint, required Iterable<CanvasBoxHitArea> boxes, required String? selectedBoxId, required double handleSize})`
  - `Rect normalizedImageRectFromCanvasDrag({required Offset start, required Offset end, required double scale})`
- Consumes:
  - `Offset`, `Rect` from Flutter geometry.

- [ ] **Step 1: Write failing unit tests for gesture priority**

Create `test/ui/canvas_interaction_test.dart`:

```dart
import 'package:bbox_labeler/ui/canvas_interaction.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveCanvasPointerAction', () {
    test('resize handle has priority over moving and drawing', () {
      final action = resolveCanvasPointerAction(
        tool: CanvasTool.drawBox,
        spacePressed: false,
        selectedBoxId: 'box-1',
        hitTarget: const CanvasHitTarget.resizeHandle('box-1'),
      );

      expect(action, CanvasPointerActionKind.resizingBox);
    });

    test('selected box drag moves the box', () {
      final action = resolveCanvasPointerAction(
        tool: CanvasTool.select,
        spacePressed: false,
        selectedBoxId: 'box-1',
        hitTarget: const CanvasHitTarget.box('box-1'),
      );

      expect(action, CanvasPointerActionKind.movingBox);
    });

    test('unselected box click selects the box', () {
      final action = resolveCanvasPointerAction(
        tool: CanvasTool.select,
        spacePressed: false,
        selectedBoxId: 'box-1',
        hitTarget: const CanvasHitTarget.box('box-2'),
      );

      expect(action, CanvasPointerActionKind.selectingBox);
    });

    test('space pressed forces canvas panning over drawing', () {
      final action = resolveCanvasPointerAction(
        tool: CanvasTool.drawBox,
        spacePressed: true,
        selectedBoxId: null,
        hitTarget: CanvasHitTarget.background,
      );

      expect(action, CanvasPointerActionKind.panningCanvas);
    });

    test('draw tool creates boxes only on the background', () {
      final action = resolveCanvasPointerAction(
        tool: CanvasTool.drawBox,
        spacePressed: false,
        selectedBoxId: null,
        hitTarget: CanvasHitTarget.background,
      );

      expect(action, CanvasPointerActionKind.drawingBox);
    });

    test('select tool background drag pans instead of drawing', () {
      final action = resolveCanvasPointerAction(
        tool: CanvasTool.select,
        spacePressed: false,
        selectedBoxId: null,
        hitTarget: CanvasHitTarget.background,
      );

      expect(action, CanvasPointerActionKind.panningCanvas);
    });
  });

  group('hitTestCanvas', () {
    test('selected box resize handle wins over box body', () {
      final hit = hitTestCanvas(
        canvasPoint: const Offset(100, 80),
        boxes: const [
          CanvasBoxHitArea(
            id: 'box-1',
            screenRect: Rect.fromLTWH(40, 40, 60, 40),
          ),
        ],
        selectedBoxId: 'box-1',
        handleSize: 14,
      );

      expect(hit, const CanvasHitTarget.resizeHandle('box-1'));
    });

    test('topmost box is selected first when boxes overlap', () {
      final hit = hitTestCanvas(
        canvasPoint: const Offset(50, 50),
        boxes: const [
          CanvasBoxHitArea(
            id: 'bottom',
            screenRect: Rect.fromLTWH(10, 10, 80, 80),
          ),
          CanvasBoxHitArea(
            id: 'top',
            screenRect: Rect.fromLTWH(20, 20, 80, 80),
          ),
        ],
        selectedBoxId: null,
        handleSize: 14,
      );

      expect(hit, const CanvasHitTarget.box('top'));
    });

    test('background is returned when no box contains the point', () {
      final hit = hitTestCanvas(
        canvasPoint: const Offset(4, 4),
        boxes: const [
          CanvasBoxHitArea(
            id: 'box-1',
            screenRect: Rect.fromLTWH(20, 20, 80, 80),
          ),
        ],
        selectedBoxId: null,
        handleSize: 14,
      );

      expect(hit, CanvasHitTarget.background);
    });
  });

  group('normalizedImageRectFromCanvasDrag', () {
    test('converts canvas drag to normalized original image coordinates', () {
      final rect = normalizedImageRectFromCanvasDrag(
        start: const Offset(80, 60),
        end: const Offset(20, 10),
        scale: 2,
      );

      expect(rect.left, 10);
      expect(rect.top, 5);
      expect(rect.width, 30);
      expect(rect.height, 25);
    });
  });
}
```

- [ ] **Step 2: Run the new test and verify it fails**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\canvas_interaction_test.dart -r expanded
```

Expected: FAIL because `package:bbox_labeler/ui/canvas_interaction.dart` does not exist.

- [ ] **Step 3: Implement `canvas_interaction.dart`**

Create `lib/ui/canvas_interaction.dart`:

```dart
import 'package:flutter/widgets.dart';

enum CanvasTool { select, drawBox, pan }

enum CanvasPointerActionKind {
  idle,
  panningCanvas,
  drawingBox,
  movingBox,
  resizingBox,
  selectingBox,
}

enum CanvasHitTargetType { background, box, resizeHandle }

class CanvasHitTarget {
  const CanvasHitTarget._(this.type, this.boxId);

  const CanvasHitTarget.box(String boxId)
      : this._(CanvasHitTargetType.box, boxId);

  const CanvasHitTarget.resizeHandle(String boxId)
      : this._(CanvasHitTargetType.resizeHandle, boxId);

  static const background = CanvasHitTarget._(
    CanvasHitTargetType.background,
    null,
  );

  final CanvasHitTargetType type;
  final String? boxId;

  @override
  bool operator ==(Object other) {
    return other is CanvasHitTarget &&
        other.type == type &&
        other.boxId == boxId;
  }

  @override
  int get hashCode => Object.hash(type, boxId);
}

class CanvasBoxHitArea {
  const CanvasBoxHitArea({required this.id, required this.screenRect});

  final String id;
  final Rect screenRect;
}

CanvasPointerActionKind resolveCanvasPointerAction({
  required CanvasTool tool,
  required bool spacePressed,
  required String? selectedBoxId,
  required CanvasHitTarget hitTarget,
}) {
  if (hitTarget.type == CanvasHitTargetType.resizeHandle) {
    return CanvasPointerActionKind.resizingBox;
  }
  if (hitTarget.type == CanvasHitTargetType.box) {
    return hitTarget.boxId == selectedBoxId
        ? CanvasPointerActionKind.movingBox
        : CanvasPointerActionKind.selectingBox;
  }
  if (spacePressed || tool == CanvasTool.pan) {
    return CanvasPointerActionKind.panningCanvas;
  }
  if (tool == CanvasTool.drawBox) {
    return CanvasPointerActionKind.drawingBox;
  }
  return CanvasPointerActionKind.panningCanvas;
}

CanvasHitTarget hitTestCanvas({
  required Offset canvasPoint,
  required Iterable<CanvasBoxHitArea> boxes,
  required String? selectedBoxId,
  required double handleSize,
}) {
  final selectedBox = _firstBoxOrNull(
    boxes,
    (box) => box.id == selectedBoxId,
  );
  if (selectedBox != null &&
      _resizeHandleRect(selectedBox.screenRect, handleSize).contains(
        canvasPoint,
      )) {
    return CanvasHitTarget.resizeHandle(selectedBox.id);
  }

  for (final box in boxes.toList().reversed) {
    if (box.screenRect.contains(canvasPoint)) {
      return CanvasHitTarget.box(box.id);
    }
  }

  return CanvasHitTarget.background;
}

Rect normalizedImageRectFromCanvasDrag({
  required Offset start,
  required Offset end,
  required double scale,
}) {
  final rect = Rect.fromPoints(start, end);
  return Rect.fromLTWH(
    rect.left / scale,
    rect.top / scale,
    rect.width / scale,
    rect.height / scale,
  );
}

Rect _resizeHandleRect(Rect boxRect, double handleSize) {
  return Rect.fromCenter(
    center: boxRect.bottomRight,
    width: handleSize,
    height: handleSize,
  );
}

CanvasBoxHitArea? _firstBoxOrNull(
  Iterable<CanvasBoxHitArea> boxes,
  bool Function(CanvasBoxHitArea box) test,
) {
  for (final box in boxes) {
    if (test(box)) {
      return box;
    }
  }
  return null;
}
```

- [ ] **Step 4: Run the new unit tests and verify they pass**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\canvas_interaction_test.dart -r expanded
```

Expected: all tests in `canvas_interaction_test.dart` pass.

- [ ] **Step 5: Commit or record skipped commit**

Run:

```powershell
Test-Path .git
Get-Command git -ErrorAction SilentlyContinue
```

If both git checks pass:

```powershell
git add lib\ui\canvas_interaction.dart test\ui\canvas_interaction_test.dart
git commit -m "feat: add canvas interaction model"
```

If either git check fails, record: `Commit skipped because this workspace has no .git directory or git executable.`

---

### Task 2: Canvas Tool State, Toolbar, And Shortcuts

**Files:**
- Modify: `lib/ui/workbench_copy.dart`
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes:
  - `CanvasTool` from `lib/ui/canvas_interaction.dart`
- Produces:
  - Toolbar keys `canvas-tool-select`, `canvas-tool-draw-box`, `canvas-tool-pan`
  - Draw mode label/tooltip through `WorkbenchCopy.drawBoxTool`
  - Select mode label/tooltip through `WorkbenchCopy.selectMoveTool`
  - Pan mode label/tooltip through `WorkbenchCopy.panTool`
  - `B` shortcut changes current tool to `CanvasTool.drawBox`
  - `Esc` changes current tool to `CanvasTool.select`

- [ ] **Step 1: Add failing widget test for the canvas tool buttons**

Add this test inside the existing `group('WorkbenchScreen', () {` block in `test/ui/workbench_widget_test.dart`:

```dart
    testWidgets('canvas toolbar exposes select draw and pan tools', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());

      await tester.pumpWidget(_app(controller));

      expect(find.byKey(const ValueKey('canvas-tool-select')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('canvas-tool-draw-box')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('canvas-tool-pan')), findsOneWidget);
      expect(find.text(WorkbenchCopy.selectMoveTool), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('canvas-tool-draw-box')));
      await tester.pump();

      expect(find.text(WorkbenchCopy.drawBoxTool), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('canvas-tool-pan')));
      await tester.pump();

      expect(find.text(WorkbenchCopy.panTool), findsOneWidget);
    });
```

- [ ] **Step 2: Add failing widget test for keyboard switching**

Add this test in the same group:

```dart
    testWidgets('keyboard switches canvas tools predictably', (tester) async {
      final controller = AppController();
      controller.loadProject(_project());

      await tester.pumpWidget(_app(controller));

      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.pump();

      expect(find.text(WorkbenchCopy.drawBoxTool), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(find.text(WorkbenchCopy.selectMoveTool), findsOneWidget);
    });
```

If `LogicalKeyboardKey` is not imported in the test file, add:

```dart
import 'package:flutter/services.dart';
```

- [ ] **Step 3: Run the focused test and verify it fails**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart -r expanded
```

Expected: FAIL because the canvas tool buttons and copy constants do not exist.

- [ ] **Step 4: Add tool copy**

In `lib/ui/workbench_copy.dart`, add constants near the other workbench labels:

```dart
  static const selectMoveTool = '선택/이동';
  static const selectMoveTooltip = '박스 선택, 이동, 크기 변경';
  static const drawBoxTool = '박스 그리기';
  static const drawBoxTooltip = '새 박스 그리기 (B)';
  static const panTool = '이미지 이동';
  static const panTooltip = '이미지 이동 (Space)';
```

- [ ] **Step 5: Import the interaction model in `workbench_screen.dart`**

Add this import:

```dart
import 'canvas_interaction.dart';
```

- [ ] **Step 6: Add tool state to `_ViewerPanelState`**

Inside `_ViewerPanelState`, add fields:

```dart
  final FocusNode _focusNode = FocusNode(debugLabel: 'annotation-canvas');
  CanvasTool _tool = CanvasTool.select;
  bool _spacePressed = false;
```

Update `dispose()`:

```dart
  @override
  void dispose() {
    _focusNode.dispose();
    _transform.dispose();
    super.dispose();
  }
```

Add helper methods inside `_ViewerPanelState`:

```dart
  CanvasTool get _effectiveTool =>
      _spacePressed ? CanvasTool.pan : _tool;

  void _setTool(CanvasTool tool) {
    setState(() => _tool = tool);
    _focusNode.requestFocus();
  }

  KeyEventResult _handleCanvasKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.keyB) {
      _setTool(CanvasTool.drawBox);
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _setTool(CanvasTool.select);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.space) {
      final pressed = event is KeyDownEvent;
      if (_spacePressed != pressed) {
        setState(() => _spacePressed = pressed);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
```

- [ ] **Step 7: Wrap selected-image viewer content in a focused keyboard handler**

In `_ViewerPanelState.build`, inside the `LayoutBuilder` branch where `image != null`, change the start of the selected-image return from:

```dart
        return DecoratedBox(
          key: const ValueKey('annotation-canvas-panel'),
```

to:

```dart
        return Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _handleCanvasKey,
          child: DecoratedBox(
            key: const ValueKey('annotation-canvas-panel'),
```

At the end of the current `DecoratedBox` return, add one extra `)` so the new `Focus` closes after the `DecoratedBox`.

- [ ] **Step 8: Add `_CanvasToolButton`**

Add this private widget below `_ImageQueueRow`:

```dart
class _CanvasToolButton extends StatelessWidget {
  const _CanvasToolButton({
    super.key,
    required this.selected,
    required this.tooltip,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final bool selected;
  final String tooltip;
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        key: key,
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: selected
              ? colorScheme.onPrimaryContainer
              : colorScheme.onSurfaceVariant,
          backgroundColor: selected
              ? colorScheme.primaryContainer
              : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
    );
  }
}
```

- [ ] **Step 9: Add tool buttons to the canvas toolbar**

In `_ViewerPanelState.build`, inside the `Row` before the existing zoom buttons, add:

```dart
                    _CanvasToolButton(
                      key: const ValueKey('canvas-tool-select'),
                      selected: _tool == CanvasTool.select && !_spacePressed,
                      tooltip: WorkbenchCopy.selectMoveTooltip,
                      label: WorkbenchCopy.selectMoveTool,
                      icon: Icons.near_me_outlined,
                      onPressed: () => _setTool(CanvasTool.select),
                    ),
                    const SizedBox(width: 6),
                    _CanvasToolButton(
                      key: const ValueKey('canvas-tool-draw-box'),
                      selected: _tool == CanvasTool.drawBox && !_spacePressed,
                      tooltip: WorkbenchCopy.drawBoxTooltip,
                      label: WorkbenchCopy.drawBoxTool,
                      icon: Icons.crop_square,
                      onPressed: () => _setTool(CanvasTool.drawBox),
                    ),
                    const SizedBox(width: 6),
                    _CanvasToolButton(
                      key: const ValueKey('canvas-tool-pan'),
                      selected: _effectiveTool == CanvasTool.pan,
                      tooltip: WorkbenchCopy.panTooltip,
                      label: WorkbenchCopy.panTool,
                      icon: Icons.pan_tool_alt_outlined,
                      onPressed: () => _setTool(CanvasTool.pan),
                    ),
                    const SizedBox(width: 12),
```

- [ ] **Step 10: Make the toolbar horizontally scrollable before testing**

Change the toolbar wrapper from:

```dart
child: Row(
  mainAxisAlignment: MainAxisAlignment.center,
  children: [
```

to:

```dart
child: SingleChildScrollView(
  scrollDirection: Axis.horizontal,
  child: Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
```

Close the extra `SingleChildScrollView` after the `Row`. This prevents the added tool buttons and existing zoom buttons from overflowing on narrower desktop windows.

- [ ] **Step 11: Run workbench tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart -r expanded
```

Expected: PASS.

- [ ] **Step 12: Commit or record skipped commit**

Run:

```powershell
Test-Path .git
Get-Command git -ErrorAction SilentlyContinue
```

If both git checks pass:

```powershell
git add lib\ui\workbench_copy.dart lib\ui\workbench_screen.dart test\ui\workbench_widget_test.dart
git commit -m "feat: add canvas tool modes"
```

If either git check fails, record: `Commit skipped because this workspace has no .git directory or git executable.`

---

### Task 3: Draw Boxes Only In Draw Mode

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes:
  - `CanvasTool`
  - `normalizedImageRectFromCanvasDrag({required Offset start, required Offset end, required double scale})`
  - `_ViewerPanelState._effectiveTool`
- Produces:
  - `_ImageCanvas.tool`
  - `_ImageCanvas.onBoxDrawn`
  - `_ImageCanvas.onDrawingComplete`
  - Canvas key `image-canvas`

- [ ] **Step 1: Add failing test that default background drag does not create boxes**

Add this test in `test/ui/workbench_widget_test.dart`:

```dart
    testWidgets('default background drag pans instead of creating a box', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());
      final initialCount = controller.selectedImage!.boxCount;

      await tester.pumpWidget(_app(controller));
      await tester.drag(
        find.byKey(const ValueKey('image-canvas')),
        const Offset(80, 60),
      );
      await tester.pump();

      expect(controller.selectedImage!.boxCount, initialCount);
      expect(find.text(WorkbenchCopy.selectMoveTool), findsOneWidget);
    });
```

- [ ] **Step 2: Add failing test that draw mode creates a box and returns to select mode**

Add this test:

```dart
    testWidgets('draw tool creates one box and returns to select mode', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());
      final initialCount = controller.selectedImage!.boxCount;

      await tester.pumpWidget(_app(controller));
      await tester.tap(find.byKey(const ValueKey('canvas-tool-draw-box')));
      await tester.pump();

      await tester.drag(
        find.byKey(const ValueKey('image-canvas')),
        const Offset(80, 60),
      );
      await tester.pump();

      expect(controller.selectedImage!.boxCount, initialCount + 1);
      expect(controller.selectedBoxId, startsWith('manual-'));
      expect(find.text(WorkbenchCopy.selectMoveTool), findsOneWidget);
    });
```

- [ ] **Step 3: Add failing test that pan tool does not create boxes**

Add this test:

```dart
    testWidgets('pan tool never creates boxes from background drag', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());
      final initialCount = controller.selectedImage!.boxCount;

      await tester.pumpWidget(_app(controller));
      await tester.tap(find.byKey(const ValueKey('canvas-tool-pan')));
      await tester.pump();

      await tester.drag(
        find.byKey(const ValueKey('image-canvas')),
        const Offset(80, 60),
      );
      await tester.pump();

      expect(controller.selectedImage!.boxCount, initialCount);
      expect(find.text(WorkbenchCopy.panTool), findsOneWidget);
    });
```

- [ ] **Step 4: Run workbench tests and verify they fail**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart -r expanded
```

Expected: FAIL because `image-canvas` key and draw-mode-only behavior are not implemented.

- [ ] **Step 5: Update `_ImageCanvas` constructor**

Change `_ImageCanvas` to accept tool state and callbacks:

```dart
class _ImageCanvas extends StatefulWidget {
  const _ImageCanvas({
    required this.controller,
    required this.project,
    required this.image,
    required this.viewerSize,
    required this.tool,
    required this.onDrawingComplete,
  });

  final AppController controller;
  final AnnotationProject project;
  final AnnotatedImage image;
  final Size viewerSize;
  final CanvasTool tool;
  final VoidCallback onDrawingComplete;
```

- [ ] **Step 6: Pass tool state from `_ViewerPanelState`**

Where `_ImageCanvas` is created, add:

```dart
                        tool: _effectiveTool,
                        onDrawingComplete: () => _setTool(CanvasTool.select),
```

- [ ] **Step 7: Change `_ImageCanvasState` drag handlers to draw only in draw mode**

In `_ImageCanvasState.build`, replace the current unconditional `GestureDetector` drag callbacks with:

```dart
      child: GestureDetector(
        key: const ValueKey('image-canvas'),
        behavior: HitTestBehavior.translucent,
        onTap: widget.controller.selectedBoxId == null
            ? null
            : () => widget.controller.selectBox(null),
        onPanStart: widget.tool == CanvasTool.drawBox
            ? (details) {
                setState(() {
                  _dragStart = details.localPosition;
                  _dragCurrent = details.localPosition;
                });
              }
            : null,
        onPanUpdate: widget.tool == CanvasTool.drawBox
            ? (details) {
                if (_dragStart == null) {
                  return;
                }
                setState(() => _dragCurrent = details.localPosition);
              }
            : null,
        onPanEnd: widget.tool == CanvasTool.drawBox
            ? (_) {
                final start = _dragStart;
                final current = _dragCurrent;
                setState(() {
                  _dragStart = null;
                  _dragCurrent = null;
                });
                if (start == null || current == null) {
                  return;
                }
                final rect = normalizedImageRectFromCanvasDrag(
                  start: start,
                  end: current,
                  scale: scale,
                );
                if (rect.width < 4 / scale || rect.height < 4 / scale) {
                  return;
                }
                widget.controller.addBox(
                  x: rect.left,
                  y: rect.top,
                  width: rect.width,
                  height: rect.height,
                );
                widget.onDrawingComplete();
              }
            : null,
```

Keep the current `Stack` child exactly where it is; only the surrounding `GestureDetector` callbacks change in this task.

- [ ] **Step 8: Ensure `InteractiveViewer` can pan outside draw mode**

In the `InteractiveViewer` inside `_ViewerPanelState.build`, set pan behavior:

```dart
                    panEnabled: _effectiveTool != CanvasTool.drawBox,
                    scaleEnabled: true,
```

This keeps image panning available in select/pan modes and prevents drag competition while drawing.

- [ ] **Step 9: Add cursor feedback for draw mode**

In `_ImageCanvasState.build`, change the start of the return from:

```dart
    return SizedBox(
      width: canvasSize.width,
      height: canvasSize.height,
      child: GestureDetector(
```

to:

```dart
    return MouseRegion(
      cursor: widget.tool == CanvasTool.drawBox
          ? SystemMouseCursors.precise
          : SystemMouseCursors.basic,
      child: SizedBox(
        width: canvasSize.width,
        height: canvasSize.height,
        child: GestureDetector(
```

At the end of the current `SizedBox` return, add one extra `)` so the new `MouseRegion` closes after the `SizedBox`.

- [ ] **Step 10: Run workbench widget tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart -r expanded
```

Expected: PASS for all workbench widget tests.

- [ ] **Step 11: Commit or record skipped commit**

Run:

```powershell
Test-Path .git
Get-Command git -ErrorAction SilentlyContinue
```

If both git checks pass:

```powershell
git add lib\ui\workbench_screen.dart test\ui\workbench_widget_test.dart
git commit -m "fix: draw boxes only in draw mode"
```

If either git check fails, record: `Commit skipped because this workspace has no .git directory or git executable.`

---

### Task 4: Explicit Box Move And Resize Feedback

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes:
  - Existing `AppController.moveSelectedBox(double dx, double dy)`
  - Existing `AppController.resizeSelectedBox(double width, double height)`
  - Existing `selected-box-*` and `resize-handle-*` keys
- Produces:
  - Move cursor over selected boxes.
  - Resize cursor over resize handle.
  - Box body drag moves only selected boxes.
  - Resize handle drag resizes only selected boxes.

- [ ] **Step 1: Add failing widget test for selected box movement**

Add this test in `test/ui/workbench_widget_test.dart`:

```dart
    testWidgets('dragging a selected box moves the box', (tester) async {
      final controller = AppController();
      controller.loadProject(_project());

      await tester.pumpWidget(_app(controller));
      controller.selectBox('box-1');
      await tester.pump();

      final before = controller.selectedImage!.boxes.single;
      await tester.drag(
        find.byKey(const ValueKey('selected-box-box-1')),
        const Offset(12, 8),
      );
      await tester.pump();

      final after = controller.selectedImage!.boxes.single;
      expect(after.x, greaterThan(before.x));
      expect(after.y, greaterThan(before.y));
      expect(after.width, before.width);
      expect(after.height, before.height);
    });
```

- [ ] **Step 2: Add failing widget test for selected box resize**

Add this test:

```dart
    testWidgets('dragging the resize handle changes box size only', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());

      await tester.pumpWidget(_app(controller));
      controller.selectBox('box-1');
      await tester.pump();

      final before = controller.selectedImage!.boxes.single;
      await tester.drag(
        find.byKey(const ValueKey('resize-handle-box-1')),
        const Offset(14, 10),
      );
      await tester.pump();

      final after = controller.selectedImage!.boxes.single;
      expect(after.x, before.x);
      expect(after.y, before.y);
      expect(after.width, greaterThan(before.width));
      expect(after.height, greaterThan(before.height));
    });
```

- [ ] **Step 3: Run tests and verify current behavior**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart -r expanded
```

Expected: If tests already PASS, keep them as regression tests and continue to cursor/feedback implementation. If they FAIL, proceed with the minimal implementation in the next steps.

- [ ] **Step 4: Add cursor feedback to `_OverlayBox`**

In `_OverlayBox.build`, wrap the selected box body `Container` with `MouseRegion`:

```dart
            MouseRegion(
              cursor: selected
                  ? SystemMouseCursors.move
                  : SystemMouseCursors.click,
              child: Container(
                key: ValueKey(
                  selected ? 'selected-box-${box.id}' : 'box-${box.id}',
                ),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: selected ? Colors.amberAccent : color,
                    width: selected ? 3 : 2,
                  ),
                  color: color.withAlpha(32),
                ),
                alignment: Alignment.topLeft,
                child: Text(
                  label?.name ?? WorkbenchCopy.unlabeledBox,
                  style: TextStyle(
                    color: selected ? Colors.black : color,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    backgroundColor: Colors.white70,
                  ),
                ),
              ),
            ),
```

- [ ] **Step 5: Add resize cursor and stable handle size**

In `_OverlayBox.build`, replace the resize handle child `Container` with:

```dart
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeDownRight,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: Colors.amberAccent,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: Colors.black87),
                      ),
                    ),
                  ),
```

Keep the existing `key: ValueKey('resize-handle-${box.id}')` on the surrounding `GestureDetector`.

- [ ] **Step 6: Prevent background tap from clearing selection during handle/body drags**

If Task 3 added this background tap:

```dart
onTap: widget.controller.selectedBoxId == null
    ? null
    : () => widget.controller.selectBox(null),
```

leave it unchanged. It only runs on a tap gesture and should not fire after drag gestures. If widget tests show it clears selection after drag, remove `onTap` from the canvas and replace it with:

```dart
onTapUp: widget.tool == CanvasTool.drawBox
    ? null
    : (_) => widget.controller.selectBox(null),
```

- [ ] **Step 7: Run workbench widget tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart -r expanded
```

Expected: PASS for all workbench widget tests.

- [ ] **Step 8: Commit or record skipped commit**

Run:

```powershell
Test-Path .git
Get-Command git -ErrorAction SilentlyContinue
```

If both git checks pass:

```powershell
git add lib\ui\workbench_screen.dart test\ui\workbench_widget_test.dart
git commit -m "feat: clarify box edit interactions"
```

If either git check fails, record: `Commit skipped because this workspace has no .git directory or git executable.`

---

### Task 5: Space Temporary Pan And Final Verification

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `test/ui/workbench_widget_test.dart`
- Verify: all modified files

**Interfaces:**
- Consumes:
  - `_ViewerPanelState._spacePressed`
  - `_ViewerPanelState._effectiveTool`
  - `CanvasTool.pan`
- Produces:
  - Holding `Space` visually selects the pan tool.
  - Dragging the background while `Space` is held does not create a box.
  - Final formatted, analyzed, tested, and built Windows app.

- [ ] **Step 1: Add failing widget test for Space temporary pan**

Add this test in `test/ui/workbench_widget_test.dart`:

```dart
    testWidgets('space temporarily prioritizes panning while in draw mode', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());
      final initialCount = controller.selectedImage!.boxCount;

      await tester.pumpWidget(_app(controller));
      await tester.tap(find.byKey(const ValueKey('canvas-tool-draw-box')));
      await tester.pump();
      expect(find.text(WorkbenchCopy.drawBoxTool), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(find.text(WorkbenchCopy.panTool), findsOneWidget);

      await tester.drag(
        find.byKey(const ValueKey('image-canvas')),
        const Offset(80, 60),
      );
      await tester.pump();

      expect(controller.selectedImage!.boxCount, initialCount);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(find.text(WorkbenchCopy.drawBoxTool), findsOneWidget);
    });
```

If `LogicalKeyboardKey` is not imported, add:

```dart
import 'package:flutter/services.dart';
```

- [ ] **Step 2: Run the focused test and verify it fails if Space is incomplete**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart -r expanded
```

Expected: PASS if Task 2 already implemented Space correctly. If it FAILS, continue with Step 3.

- [ ] **Step 3: Make Space visual state explicit**

In `_ViewerPanelState`, keep `_tool` unchanged when Space is pressed. Use `_effectiveTool` for behavior and for the selected state of the pan tool:

```dart
  CanvasTool get _effectiveTool =>
      _spacePressed ? CanvasTool.pan : _tool;
```

Ensure the pan button selected expression is:

```dart
selected: _effectiveTool == CanvasTool.pan,
```

Ensure draw and select selected expressions include `!_spacePressed`:

```dart
selected: _tool == CanvasTool.drawBox && !_spacePressed,
selected: _tool == CanvasTool.select && !_spacePressed,
```

- [ ] **Step 4: Run focused widget tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart test\widget_test.dart -r expanded
```

Expected: all tests in both files pass.

- [ ] **Step 5: Check corrupted visible workbench copy**

Run:

```powershell
rg -n "占|沃|揶|獄|疫|筌|誘|夷|�|\\?대|\\?꾨|\\?쇰|쨌" lib\ui test\ui test\widget_test.dart
```

Expected: no matches and exit code `1`. If matches remain in visible UI copy, replace them with clean constants in `WorkbenchCopy`.

- [ ] **Step 6: Format check**

Run:

```powershell
& 'C:\tools\flutter\bin\cache\dart-sdk\bin\dart.exe' format --set-exit-if-changed .
```

Expected: exit code `0`. If files are formatted and command exits `1`, run:

```powershell
& 'C:\tools\flutter\bin\cache\dart-sdk\bin\dart.exe' format .
& 'C:\tools\flutter\bin\cache\dart-sdk\bin\dart.exe' format --set-exit-if-changed .
```

The second command must exit `0`.

- [ ] **Step 7: Analyze**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' analyze
```

Expected: `No issues found!`

- [ ] **Step 8: Run full test suite**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test
```

Expected: all tests pass.

- [ ] **Step 9: Build Windows app**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' build windows
```

Expected: `Built build\windows\x64\runner\Release\bbox_labeler.exe`

- [ ] **Step 10: Check removed file-open workflow stays removed**

Run:

```powershell
rg -n "openProjectFile|saveProjectFile" lib test
```

Expected: no matches and exit code `1`.

- [ ] **Step 11: Record final git status or skipped status**

Run:

```powershell
Test-Path .git
Get-Command git -ErrorAction SilentlyContinue
```

If both git checks pass:

```powershell
git status --short
```

If either git check fails, record: `Git status unavailable because this workspace has no .git directory or git executable.`

---

## Self-Review Checklist

- Spec coverage:
  - Default select/move mode: Task 2 and Task 3.
  - Background drag pans instead of drawing: Task 3.
  - Draw mode with `B`: Task 2 and Task 3.
  - `Esc` returns to select/move: Task 2.
  - `Space` temporary pan: Task 2 and Task 5.
  - Gesture priority helper: Task 1.
  - Cursor and visual feedback: Task 2, Task 3, Task 4.
  - Coordinate conversion helper: Task 1 and Task 3.
  - Existing save/load/export behavior preserved: Task 5 full tests and build.

- Type consistency:
  - `CanvasTool` is defined in `lib/ui/canvas_interaction.dart` and imported by `workbench_screen.dart`.
  - `_ImageCanvas.tool` uses `CanvasTool`.
  - `_ViewerPanelState._effectiveTool` returns `CanvasTool`.
  - `normalizedImageRectFromCanvasDrag` returns `Rect`.
  - Widget keys match test expectations exactly.

- Scope control:
  - No multi-select.
  - No rotated boxes.
  - No polygon or segmentation tools.
  - No custom shortcut settings screen.
  - No new dependencies.
