# Overlay Handle And Z-Order Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make selected box handles, labels, and layering behave like a professional annotation/design tool.

**Architecture:** Keep bbox data in original image pixels and change only screen-space overlay layout in `WorkbenchScreen`. Expand the selected overlay's widget rect by the handle hit radius, position the actual box rect inside that overlay, render labels as separate absolute layers, and render selected boxes after all unselected boxes.

**Tech Stack:** Flutter desktop, Dart, existing `flutter_test` widget tests, existing `AppController`, existing `CanvasResizeHandle` helpers.

## Global Constraints

- This change must not alter stored bbox coordinates.
- All bbox data remains in original image pixels.
- Move and resize deltas continue to account for both fit scale and current zoom: `originalDelta = screenDelta / (fitScale * zoom)`.
- Each selected box renders eight handles: `topLeft`, `top`, `topRight`, `left`, `right`, `bottomLeft`, `bottom`, `bottomRight`.
- The handle center must sit exactly on the displayed box corner or edge midpoint.
- The visual shape must always be a square or near-square chip, never a circle.
- The hit target should be larger than the visible handle.
- The selected box renders after non-selected boxes.
- Within a selected box overlay, draw layers in this order: box fill, box stroke, label chip, resize handles.
- This workspace is not a git repository, so commit steps are replaced by verification steps.

---

## File Structure

- Modify `lib/ui/workbench_screen.dart`: split selected and non-selected overlay render order, expand selected overlay bounds, render label as a separate absolute layer, and separate resize handle hit target from visible square.
- Modify `test/ui/workbench_widget_test.dart`: add widget geometry tests for handle centers, square handle visuals, fixed label position, and selected z-order.
- No project model, detector, export, or persistence files should change.

---

### Task 1: Overlay Geometry Regression Tests

**Files:**
- Test: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: existing widget keys `selected-box-box-1` and `resize-handle-box-1-<handleName>`.
- Produces: required new widget key `resize-handle-visual-box-1-<handleName>`.
- Produces: required new widget key `overlay-label-box-1`.

- [ ] **Step 1: Write failing tests for handle center and square visual**

Add these tests near the existing resize handle widget tests in `test/ui/workbench_widget_test.dart`:

```dart
testWidgets('selected resize handles are centered on box boundaries', (
  tester,
) async {
  final controller = AppController()..loadProject(_project());
  controller.selectBox('box-1');

  await tester.pumpWidget(_app(controller));

  final boxRect = tester.getRect(
    find.byKey(const ValueKey('selected-box-box-1')),
  );

  final topLeft = tester.getRect(
    find.byKey(const ValueKey('resize-handle-box-1-topLeft')),
  );
  final top = tester.getRect(
    find.byKey(const ValueKey('resize-handle-box-1-top')),
  );
  final right = tester.getRect(
    find.byKey(const ValueKey('resize-handle-box-1-right')),
  );
  final bottomRight = tester.getRect(
    find.byKey(const ValueKey('resize-handle-box-1-bottomRight')),
  );

  expect(topLeft.center.dx, closeTo(boxRect.left, 0.1));
  expect(topLeft.center.dy, closeTo(boxRect.top, 0.1));
  expect(top.center.dx, closeTo(boxRect.center.dx, 0.1));
  expect(top.center.dy, closeTo(boxRect.top, 0.1));
  expect(right.center.dx, closeTo(boxRect.right, 0.1));
  expect(right.center.dy, closeTo(boxRect.center.dy, 0.1));
  expect(bottomRight.center.dx, closeTo(boxRect.right, 0.1));
  expect(bottomRight.center.dy, closeTo(boxRect.bottom, 0.1));
});

testWidgets('resize handle visual stays square after zooming', (tester) async {
  final controller = AppController()..loadProject(_project());
  controller.selectBox('box-1');

  await tester.pumpWidget(_app(controller));

  Rect visualRect() {
    return tester.getRect(
      find.byKey(const ValueKey('resize-handle-visual-box-1-topLeft')),
    );
  }

  final unzoomed = visualRect();
  expect(unzoomed.width, closeTo(unzoomed.height, 0.1));

  await _tapVisible(tester, find.byKey(const ValueKey('zoom-in')));
  final zoomed = visualRect();

  expect(zoomed.width, closeTo(zoomed.height, 0.1));
  expect(zoomed.width, greaterThan(0));
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart
```

Expected: fails because the current handle hit target is inside the box boundary and `resize-handle-visual-box-1-topLeft` does not exist.

---

### Task 2: Fixed Label Position And Selected Z-Order Tests

**Files:**
- Test: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: new key `overlay-label-box-1`.
- Consumes: existing key `selected-box-box-1`.
- Produces: helper project `_overlappingProject()` inside the test file.

- [ ] **Step 1: Write failing tests for label position and selected render order**

Add these tests near the overlay interaction tests:

```dart
testWidgets('overlay label position does not move when box is selected', (
  tester,
) async {
  final controller = AppController()..loadProject(_project());

  await tester.pumpWidget(_app(controller));
  final unselectedLabelTopLeft = tester.getTopLeft(
    find.byKey(const ValueKey('overlay-label-box-1')),
  );

  controller.selectBox('box-1');
  await tester.pump();

  final selectedLabelTopLeft = tester.getTopLeft(
    find.byKey(const ValueKey('overlay-label-box-1')),
  );

  expect(selectedLabelTopLeft.dx, closeTo(unselectedLabelTopLeft.dx, 0.1));
  expect(selectedLabelTopLeft.dy, closeTo(unselectedLabelTopLeft.dy, 0.1));
});

testWidgets('selected box is rendered after overlapping unselected boxes', (
  tester,
) async {
  final controller = AppController()..loadProject(_overlappingProject());
  controller.selectBox('box-1');

  await tester.pumpWidget(_app(controller));

  final widgets = tester.allWidgets.toList();
  final selectedIndex = widgets.indexWhere(
    (widget) => widget.key == const ValueKey('selected-box-box-1'),
  );
  final unselectedIndex = widgets.indexWhere(
    (widget) => widget.key == const ValueKey('box-box-2'),
  );

  expect(unselectedIndex, isNonNegative);
  expect(selectedIndex, isNonNegative);
  expect(selectedIndex, greaterThan(unselectedIndex));
});
```

Add this helper near `_project()`:

```dart
AnnotationProject _overlappingProject() {
  return _project().copyWith(
    images: [
      _project().images.first.copyWith(
        boxes: const [
          BoundingBox(
            id: 'box-1',
            x: 10,
            y: 10,
            width: 30,
            height: 30,
            status: BoxStatus.proposal,
          ),
          BoundingBox(
            id: 'box-2',
            x: 12,
            y: 12,
            width: 30,
            height: 30,
            status: BoxStatus.proposal,
          ),
        ],
      ),
      _project().images.last,
    ],
  );
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart
```

Expected: fails because `overlay-label-box-1` does not exist and selected boxes are rendered in source order rather than after non-selected boxes.

---

### Task 3: Render Selected Box Last

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Test: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: `widget.image.visibleBoxes`.
- Consumes: `widget.controller.selectedBoxId`.
- Produces: selected `_OverlayBox` rendered after non-selected overlays.

- [ ] **Step 1: Split selected and unselected overlay rendering**

Inside `_ImageCanvasState.build`, before returning `MouseRegion`, add:

```dart
final visibleBoxes = widget.image.visibleBoxes;
final selectedBoxId = widget.controller.selectedBoxId;
BoundingBox? selectedVisibleBox;
final unselectedVisibleBoxes = <BoundingBox>[];
for (final box in visibleBoxes) {
  if (box.id == selectedBoxId) {
    selectedVisibleBox = box;
  } else {
    unselectedVisibleBoxes.add(box);
  }
}
```

Replace:

```dart
for (final box in widget.image.visibleBoxes)
  _OverlayBox(
    controller: widget.controller,
    image: widget.image,
    box: box,
    scale: scale,
    zoom: widget.zoom,
    selected: widget.controller.selectedBoxId == box.id,
    label: _labelFor(widget.project, box.labelId),
  ),
```

with:

```dart
for (final box in unselectedVisibleBoxes)
  _OverlayBox(
    controller: widget.controller,
    image: widget.image,
    box: box,
    scale: scale,
    zoom: widget.zoom,
    selected: false,
    label: _labelFor(widget.project, box.labelId),
  ),
if (selectedVisibleBox != null)
  _OverlayBox(
    controller: widget.controller,
    image: widget.image,
    box: selectedVisibleBox!,
    scale: scale,
    zoom: widget.zoom,
    selected: true,
    label: _labelFor(widget.project, selectedVisibleBox!.labelId),
  ),
```

- [ ] **Step 2: Run widget tests**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart
```

Expected: selected render order test passes after Task 4 adds the `overlay-label-<boxId>` key. If this test still fails after Task 4, inspect `tester.allWidgets.toList()` ordering for the two keys.

---

### Task 4: Separate Label Layer From Box Border

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Test: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Produces: `overlay-label-<boxId>` key for every overlay label.
- Preserves: `selected-box-<boxId>` and `box-<boxId>` keys on the box body container.

- [ ] **Step 1: Move label out of the box body container**

In `_OverlayBox.build`, replace the box body `Container` child label with an empty container:

```dart
child: Container(
  key: ValueKey(selected ? 'selected-box-${box.id}' : 'box-${box.id}'),
  decoration: BoxDecoration(
    border: Border.all(color: color, width: selected ? 3 : 2),
    color: color.withAlpha(selected ? 52 : 32),
  ),
),
```

Then add a label layer after the box body and before selected handles:

```dart
Positioned(
  left: 0,
  top: 0,
  child: IgnorePointer(
    child: Container(
      key: ValueKey('overlay-label-${box.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(190),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        label?.name ?? WorkbenchCopy.unlabeledBox,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    ),
  ),
),
```

- [ ] **Step 2: Run widget tests**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart
```

Expected: label key exists and the label position test passes.

---

### Task 5: Center Handles On Box Boundary With Separate Hit And Visual Sizes

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Test: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: `CanvasResizeHandle.values`.
- Produces: `_resizeHandleHitSize`, `_resizeHandleVisualSize`, `_resizeHandleRadius`.
- Produces: `_ResizeHandle` with hit target key `resize-handle-<boxId>-<handleName>` and visual key `resize-handle-visual-<boxId>-<handleName>`.

- [ ] **Step 1: Add overlay constants**

Near the other top-level UI constants in `lib/ui/workbench_screen.dart`, add:

```dart
const _resizeHandleHitSize = 20.0;
const _resizeHandleVisualSize = 11.0;
const _resizeHandleRadius = 2.0;
```

- [ ] **Step 2: Expand only selected overlay bounds**

In `_OverlayBox.build`, compute these values:

```dart
final handleHitSize = _resizeHandleHitSize / safeZoom;
final handleVisualSize = _resizeHandleVisualSize / safeZoom;
final overlayMargin = selected ? handleHitSize / 2 : 0.0;
final boxScreenWidth = box.width * scale;
final boxScreenHeight = box.height * scale;
```

Change the top-level `Positioned` to:

```dart
return Positioned(
  left: box.x * scale - overlayMargin,
  top: box.y * scale - overlayMargin,
  width: boxScreenWidth + overlayMargin * 2,
  height: boxScreenHeight + overlayMargin * 2,
  child: Stack(
    clipBehavior: Clip.none,
    children: [
      Positioned(
        left: overlayMargin,
        top: overlayMargin,
        width: boxScreenWidth,
        height: boxScreenHeight,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => controller.selectBox(box.id),
          onPanStart: selected ? (_) {} : null,
          onPanUpdate: selected ? (_) {} : null,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerMove: selected
                ? (event) => controller.moveSelectedBox(
                    originalDeltaFromScreenDelta(
                      screenDelta: event.delta.dx,
                      displayScale: scale,
                      zoom: safeZoom,
                    ),
                    originalDeltaFromScreenDelta(
                      screenDelta: event.delta.dy,
                      displayScale: scale,
                      zoom: safeZoom,
                    ),
                  )
                : null,
            child: MouseRegion(
              cursor: selected
                  ? SystemMouseCursors.move
                  : SystemMouseCursors.click,
              child: Container(
                key: ValueKey(
                  selected ? 'selected-box-${box.id}' : 'box-${box.id}',
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: color, width: selected ? 3 : 2),
                  color: color.withAlpha(selected ? 52 : 32),
                ),
              ),
            ),
          ),
        ),
      ),
      Positioned(
        left: overlayMargin,
        top: overlayMargin,
        child: IgnorePointer(
          child: Container(
            key: ValueKey('overlay-label-${box.id}'),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(190),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Text(
              label?.name ?? WorkbenchCopy.unlabeledBox,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
          ),
        ),
      ),
      if (selected)
        for (final handle in CanvasResizeHandle.values)
          _ResizeHandle(
            boxId: box.id,
            handle: handle,
            boxLeft: overlayMargin,
            boxTop: overlayMargin,
            boxWidth: boxScreenWidth,
            boxHeight: boxScreenHeight,
            hitSize: handleHitSize,
            visualSize: handleVisualSize,
            color: color,
            onMove: (event) {
              final latest = currentBox();
              final rect = resizeOriginalRect(
                startRect: Rect.fromLTWH(
                  latest.x,
                  latest.y,
                  latest.width,
                  latest.height,
                ),
                originalDelta: Offset(
                  originalDeltaFromScreenDelta(
                    screenDelta: event.delta.dx,
                    displayScale: scale,
                    zoom: safeZoom,
                  ),
                  originalDeltaFromScreenDelta(
                    screenDelta: event.delta.dy,
                    displayScale: scale,
                    zoom: safeZoom,
                  ),
                ),
                handle: handle,
                imageSize: Size(
                  image.width.toDouble(),
                  image.height.toDouble(),
                ),
              );
              controller.setSelectedBoxGeometry(
                x: rect.left,
                y: rect.top,
                width: rect.width,
                height: rect.height,
              );
            },
          ),
    ],
  ),
);
```

- [ ] **Step 3: Replace `_ResizeHandle` constructor fields**

Change `_ResizeHandle` fields from:

```dart
final double boxWidth;
final double boxHeight;
final double handleSize;
```

to:

```dart
final double boxLeft;
final double boxTop;
final double boxWidth;
final double boxHeight;
final double hitSize;
final double visualSize;
```

- [ ] **Step 4: Position hit target center on box boundary**

In `_ResizeHandle.build`, replace the current `half` positioning with:

```dart
final center = _centerForHandle(handle);
return Positioned(
  left: center.dx - hitSize / 2,
  top: center.dy - hitSize / 2,
  width: hitSize,
  height: hitSize,
  child: GestureDetector(
    key: ValueKey('resize-handle-$boxId-${handle.name}'),
    behavior: HitTestBehavior.opaque,
    onPanStart: (_) {},
    onPanUpdate: (_) {},
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerMove: onMove,
      child: MouseRegion(
        cursor: _cursorForHandle(handle),
        child: Center(
          child: Container(
            key: ValueKey('resize-handle-visual-$boxId-${handle.name}'),
            width: visualSize,
            height: visualSize,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(
                (_resizeHandleRadius / visualSize).clamp(0, 0.18) *
                    visualSize,
              ),
              border: Border.all(color: Colors.white, width: 1.5),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 2,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);
```

Then add this helper method to `_ResizeHandle`:

```dart
Offset _centerForHandle(CanvasResizeHandle handle) {
  return switch (handle) {
    CanvasResizeHandle.topLeft => Offset(boxLeft, boxTop),
    CanvasResizeHandle.top => Offset(boxLeft + boxWidth / 2, boxTop),
    CanvasResizeHandle.topRight => Offset(boxLeft + boxWidth, boxTop),
    CanvasResizeHandle.left => Offset(boxLeft, boxTop + boxHeight / 2),
    CanvasResizeHandle.right => Offset(boxLeft + boxWidth, boxTop + boxHeight / 2),
    CanvasResizeHandle.bottomLeft => Offset(boxLeft, boxTop + boxHeight),
    CanvasResizeHandle.bottom => Offset(boxLeft + boxWidth / 2, boxTop + boxHeight),
    CanvasResizeHandle.bottomRight => Offset(boxLeft + boxWidth, boxTop + boxHeight),
  };
}
```

- [ ] **Step 5: Remove old inside-only positioning helpers**

Remove `_leftForHandle` and `_topForHandle` from `_ResizeHandle`.

- [ ] **Step 6: Run widget tests**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart
```

Expected: handle center and square visual tests pass.

---

### Task 6: Full Verification

**Files:**
- Verify all modified files.

- [ ] **Step 1: Format**

Run:

```powershell
C:\tools\flutter\bin\dart.bat format lib test
```

Expected: formatter exits `0`.

- [ ] **Step 2: Analyze**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat analyze
```

Expected: `No issues found!`

- [ ] **Step 3: Test**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test
```

Expected: all tests pass.

- [ ] **Step 4: Build**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat build windows
```

Expected: build succeeds and updates `build\windows\x64\runner\Release\bbox_labeler.exe`.

## Self-Review Notes

- Spec coverage: handle center, square visual shape, larger hit target, fixed label position, z-order, coordinate preservation, and verification are covered by Tasks 1-6.
- Placeholder scan: this plan contains no `TBD`, `TODO`, or intentionally incomplete steps.
- Type consistency: widget keys and helper names are consistent across tests and implementation tasks.
