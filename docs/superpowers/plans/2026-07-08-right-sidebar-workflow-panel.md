# Right Sidebar Workflow Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the workbench right sidebar so it behaves as a current-image work-progress panel instead of a technical inspector.

**Architecture:** Keep the implementation in `lib/ui/workbench_screen.dart` for this pass, matching the existing workbench pattern. Add small private view helpers for grouping and summary text instead of changing annotation models. Keep all data semantics, selection behavior, completion behavior, and export behavior unchanged.

**Tech Stack:** Flutter desktop, Dart, `flutter_test`, existing `AppController`, existing `AnnotationProject`, `AnnotatedImage`, and `BoundingBox` models.

## Global Constraints

- Do not change annotation data models.
- Do not change COCO export behavior.
- Do not change detector behavior.
- Do not remove automatic box functionality from the canvas toolbar.
- Do not change canvas overlay semantics in this pass.
- Do not add advanced sorting, search, or filters.
- Do not add a collapsible panel system in this pass.
- Keep the right sidebar implementation in `lib/ui/workbench_screen.dart` for this pass.
- The internal `BoxStatus.proposal` remains unchanged.
- The right sidebar must not show `자동 박스` in normal box rows.
- A proposal box with no label displays as `라벨 필요`.
- A manual box with no label also displays as `라벨 필요`.
- A labeled box displays the label name.
- Do not show automatic/manual origin anywhere in the right sidebar in this pass.
- Box rows do not show x/y/w/h/area by default.
- Technical metadata appears only in the low-emphasis `상세` area.
- `이미지 제거` is available from an overflow action, not as a large button directly under completion.
- Preserve row-to-canvas selection behavior.
- Preserve completion and `Ctrl+Enter` behavior.
- Preserve label shortcut text-input guards.
- The workspace currently has no `.git` directory, so checkpoint steps verify `Test-Path .git` instead of running `git commit`.

---

## File Structure

- Modify `lib/ui/workbench_copy.dart`
  - Add right-sidebar copy needed for work summary, detail heading, and overflow tooltip if missing.
- Modify `lib/ui/workbench_screen.dart`
  - Redesign `_InspectorPanel`.
  - Replace `_BoxRow` content hierarchy for sidebar rows.
  - Add private helpers for work summary and grouped box lists.
  - Move image removal into an overflow menu.
- Modify `test/ui/workbench_widget_test.dart`
  - Update existing inspector tests.
  - Add coverage for hidden automatic origin, grouped rows, compact rows, detail coordinates, overflow remove, and preserved selection.

---

### Task 1: Header Summary And Overflow Remove Action

**Files:**
- Modify: `lib/ui/workbench_copy.dart`
- Modify: `lib/ui/workbench_screen.dart`
- Test: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: `AnnotatedImage.boxCount`, `AnnotatedImage.unlabeledBoxCount`, `AnnotatedImage.labeledBoxCount`, `AppController.canConfirmSelectedImage`, `AppController.selectedImageCompletionBlockerReason`, `AppController.completeSelectedImageAndSelectNext`.
- Produces:
  - Private helper in `workbench_screen.dart`: `String _imageWorkSummary(AnnotatedImage image)`
  - Overflow action key: `ValueKey('image-actions-menu')`
  - Overflow remove item key: `ValueKey('remove-image-from-project-menu-item')`

- [ ] **Step 1: Update the empty/inspector widget test expectations**

In `test/ui/workbench_widget_test.dart`, replace the existing `inspector and canvas use polished empty states` expectation for `WorkbenchCopy.noImageSelected` and `WorkbenchCopy.selectImageForInspector` with:

```dart
      expect(find.text('이미지를 선택하세요'), findsOneWidget);
      expect(find.text(WorkbenchCopy.noImageSelected), findsNothing);
      expect(find.text(WorkbenchCopy.selectImageForInspector), findsNothing);
```

- [ ] **Step 2: Add a widget test for the new right-sidebar header summary**

Add this test inside the `WorkbenchScreen` group:

```dart
    testWidgets('right sidebar shows file name and compact work summary', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());

      await tester.pumpWidget(_app(controller));

      final inspector = find.byKey(const ValueKey('inspector-panel'));
      expect(
        find.descendant(
          of: inspector,
          matching: find.text(WorkbenchCopy.selectedImage),
        ),
        findsNothing,
      );
      expect(
        find.descendant(of: inspector, matching: find.text('a.jpg')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: inspector,
          matching: find.text('박스 1개 · 라벨 필요 1개'),
        ),
        findsOneWidget,
      );
    });
```

- [ ] **Step 3: Add a widget test for no-box summary and overflow remove**

Add:

```dart
    testWidgets('right sidebar uses no-box summary and overflow remove action', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());
      controller.selectImage(2);

      await tester.pumpWidget(_app(controller));

      final inspector = find.byKey(const ValueKey('inspector-panel'));
      expect(
        find.descendant(of: inspector, matching: find.text('박스 없음')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: inspector,
          matching: find.byKey(const ValueKey('remove-image-from-project')),
        ),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('image-actions-menu')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('remove-image-from-project-menu-item')),
        findsOneWidget,
      );
      expect(find.text(WorkbenchCopy.removeImageFromProject), findsOneWidget);
    });
```

- [ ] **Step 4: Run widget tests to verify they fail**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test/ui/workbench_widget_test.dart
```

Expected: FAIL because the sidebar still shows `선택 이미지`, the old no-image empty state, and the large remove button.

- [ ] **Step 5: Add or update copy constants**

In `lib/ui/workbench_copy.dart`, add:

```dart
  static const selectImageShort = '이미지를 선택하세요';
  static const details = '상세';
  static const imageActions = '이미지 작업';
  static const boxesNone = '박스 없음';
  static const boxesLabeledComplete = '라벨 완료';
```

- [ ] **Step 6: Add the work summary helper**

In `lib/ui/workbench_screen.dart`, add this private helper near `_boxStatusLabel`:

```dart
String _imageWorkSummary(AnnotatedImage image) {
  if (image.boxCount == 0) {
    return WorkbenchCopy.boxesNone;
  }
  if (image.unlabeledBoxCount > 0) {
    return '박스 ${image.boxCount}개 · 라벨 필요 ${image.unlabeledBoxCount}개';
  }
  return '박스 ${image.boxCount}개 · ${WorkbenchCopy.boxesLabeledComplete}';
}
```

- [ ] **Step 7: Redesign the top of `_InspectorPanel`**

In `_InspectorPanelState.build`, remove:

```dart
            const _SectionTitle(WorkbenchCopy.selectedImage),
            const SizedBox(height: 10),
```

Replace the `image == null` empty state with:

```dart
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text(WorkbenchCopy.selectImageShort),
                ),
              )
```

Replace the file-name / size / status block with:

```dart
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          image.displayName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _imageWorkSummary(image),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    key: const ValueKey('image-actions-menu'),
                    tooltip: WorkbenchCopy.imageActions,
                    icon: const Icon(Icons.more_horiz),
                    onSelected: (value) {
                      if (value == 'remove') {
                        _removeImageFromProject(context, image.id);
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        key: ValueKey('remove-image-from-project-menu-item'),
                        value: 'remove',
                        child: Text(WorkbenchCopy.removeImageFromProject),
                      ),
                    ],
                  ),
                ],
              ),
```

- [ ] **Step 8: Remove the large remove button and no-object helper sentence**

In `_InspectorPanelState.build`, delete:

```dart
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey('remove-image-from-project'),
                ...
              ),
              if (image.boxCount == 0)
                const Padding(
                  ...
                  child: Text(WorkbenchCopy.confirmNoObjectAvailable),
                ),
```

Keep the completion button and blocker reason directly after the header block.

- [ ] **Step 9: Run widget tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test/ui/workbench_widget_test.dart
```

Expected: PASS for updated header and overflow tests. Existing tests that still look for the old large remove button should be updated only if they specifically exercise image removal; Task 3 updates that flow.

- [ ] **Step 10: Checkpoint**

Run:

```powershell
Test-Path .git
```

Expected: `False`. Do not run `git commit`.

---

### Task 2: Group Box Rows By Work State And Hide Automatic Origin

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Test: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: `_labelFor(AnnotationProject project, int? labelId)`, `AnnotationRules.isBoxValid`, `AnnotatedImage.visibleBoxes`.
- Produces:
  - Private helper `bool _boxNeedsLabel(BoundingBox box)`
  - Private helper `bool _boxIsInvalid(AnnotatedImage image, BoundingBox box)`
  - Private helper `_SidebarBoxGroups _sidebarBoxGroups(AnnotatedImage image)`
  - `_BoxRow` displays worker-facing row labels only.

- [ ] **Step 1: Add widget test that automatic origin is hidden**

Add inside `WorkbenchScreen` group:

```dart
    testWidgets('right sidebar hides automatic box origin in box rows', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());

      await tester.pumpWidget(_app(controller));

      final inspector = find.byKey(const ValueKey('inspector-panel'));
      expect(
        find.descendant(
          of: inspector,
          matching: find.text(WorkbenchCopy.proposalBox),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: inspector,
          matching: find.text(WorkbenchCopy.unlabeledBox),
        ),
        findsOneWidget,
      );
    });
```

- [ ] **Step 2: Add widget test for grouped box rows**

Add:

```dart
    testWidgets('right sidebar groups label-needed boxes before completed boxes', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_mixedBoxProject());

      await tester.pumpWidget(_app(controller));

      final widgets = tester.allWidgets.toList();
      final needHeadingIndex = widgets.indexWhere(
        (widget) => widget.key == const ValueKey('box-group-unlabeled'),
      );
      final doneHeadingIndex = widgets.indexWhere(
        (widget) => widget.key == const ValueKey('box-group-labeled'),
      );
      final unlabeledRowIndex = widgets.indexWhere(
        (widget) => widget.key == const ValueKey('box-row-box-unlabeled'),
      );
      final labeledRowIndex = widgets.indexWhere(
        (widget) => widget.key == const ValueKey('box-row-box-labeled'),
      );

      expect(needHeadingIndex, isNonNegative);
      expect(doneHeadingIndex, isNonNegative);
      expect(unlabeledRowIndex, isNonNegative);
      expect(labeledRowIndex, isNonNegative);
      expect(needHeadingIndex, lessThan(doneHeadingIndex));
      expect(unlabeledRowIndex, lessThan(labeledRowIndex));
    });
```

- [ ] **Step 3: Add widget test that row coordinates are hidden by default**

Add:

```dart
    testWidgets('right sidebar box rows omit coordinates by default', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());

      await tester.pumpWidget(_app(controller));

      final row = find.byKey(const ValueKey('box-row-box-1'));
      expect(
        find.descendant(of: row, matching: find.textContaining('x ')),
        findsNothing,
      );
      expect(
        find.descendant(of: row, matching: find.textContaining('area')),
        findsNothing,
      );
    });
```

- [ ] **Step 4: Add `_mixedBoxProject` test fixture**

Add near existing test fixtures:

```dart
AnnotationProject _mixedBoxProject() {
  return _project().copyWith(
    images: [
      _project().images.first.copyWith(
        boxes: const [
          BoundingBox(
            id: 'box-labeled',
            x: 40,
            y: 10,
            width: 20,
            height: 20,
            status: BoxStatus.labeled,
            labelId: 1,
          ),
          BoundingBox(
            id: 'box-unlabeled',
            x: 10,
            y: 10,
            width: 20,
            height: 20,
            status: BoxStatus.proposal,
          ),
        ],
      ),
      _project().images.last,
    ],
  );
}
```

- [ ] **Step 5: Run widget tests to verify they fail**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test/ui/workbench_widget_test.dart
```

Expected: FAIL because rows still show automatic status and coordinates, and grouping does not exist.

- [ ] **Step 6: Add grouping helpers**

In `lib/ui/workbench_screen.dart`, add near `_BoxRow`:

```dart
class _SidebarBoxGroups {
  const _SidebarBoxGroups({
    required this.unlabeled,
    required this.labeled,
    required this.invalid,
  });

  final List<BoundingBox> unlabeled;
  final List<BoundingBox> labeled;
  final List<BoundingBox> invalid;
}

_SidebarBoxGroups _sidebarBoxGroups(AnnotatedImage image) {
  final unlabeled = <BoundingBox>[];
  final labeled = <BoundingBox>[];
  final invalid = <BoundingBox>[];
  for (final box in image.visibleBoxes) {
    if (_boxIsInvalid(image, box)) {
      invalid.add(box);
    } else if (_boxNeedsLabel(box)) {
      unlabeled.add(box);
    } else {
      labeled.add(box);
    }
  }
  return _SidebarBoxGroups(
    unlabeled: unlabeled,
    labeled: labeled,
    invalid: invalid,
  );
}

bool _boxNeedsLabel(BoundingBox box) {
  return box.status != BoxStatus.labeled || box.labelId == null;
}

bool _boxIsInvalid(AnnotatedImage image, BoundingBox box) {
  return box.width <= 0 ||
      box.height <= 0 ||
      box.x < 0 ||
      box.y < 0 ||
      box.x + box.width > image.width ||
      box.y + box.height > image.height;
}
```

- [ ] **Step 7: Render grouped rows in `_InspectorPanel`**

In `_InspectorPanelState.build`, replace:

```dart
              const Divider(height: 28),
              const _SectionTitle(WorkbenchCopy.boxes),
              const SizedBox(height: 8),
              for (final box in image.visibleBoxes)
                _BoxRow(...),
              if (image.visibleBoxes.isEmpty) const Text(WorkbenchCopy.noBoxes),
```

with:

```dart
              const Divider(height: 28),
              _SidebarBoxList(
                controller: widget.controller,
                project: widget.project,
                image: image,
              ),
```

Create `_SidebarBoxList`:

```dart
class _SidebarBoxList extends StatelessWidget {
  const _SidebarBoxList({
    required this.controller,
    required this.project,
    required this.image,
  });

  final AppController controller;
  final AnnotationProject project;
  final AnnotatedImage image;

  @override
  Widget build(BuildContext context) {
    final groups = _sidebarBoxGroups(image);
    if (image.visibleBoxes.isEmpty) {
      return const Text(WorkbenchCopy.noBoxes);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (groups.unlabeled.isNotEmpty) ...[
          const _SectionTitle(
            WorkbenchCopy.unlabeledBox,
            key: ValueKey('box-group-unlabeled'),
          ),
          const SizedBox(height: 8),
          for (final box in groups.unlabeled)
            _BoxRow(
              key: ValueKey('box-row-${box.id}'),
              controller: controller,
              project: project,
              box: box,
              rowState: _SidebarBoxRowState.unlabeled,
            ),
        ],
        if (groups.labeled.isNotEmpty) ...[
          if (groups.unlabeled.isNotEmpty) const SizedBox(height: 14),
          const _SectionTitle(
            WorkbenchCopy.confirmed,
            key: ValueKey('box-group-labeled'),
          ),
          const SizedBox(height: 8),
          for (final box in groups.labeled)
            _BoxRow(
              key: ValueKey('box-row-${box.id}'),
              controller: controller,
              project: project,
              box: box,
              rowState: _SidebarBoxRowState.labeled,
            ),
        ],
        if (groups.invalid.isNotEmpty) ...[
          if (groups.unlabeled.isNotEmpty || groups.labeled.isNotEmpty)
            const SizedBox(height: 14),
          const _SectionTitle(
            WorkbenchCopy.error,
            key: ValueKey('box-group-invalid'),
          ),
          const SizedBox(height: 8),
          for (final box in groups.invalid)
            _BoxRow(
              key: ValueKey('box-row-${box.id}'),
              controller: controller,
              project: project,
              box: box,
              rowState: _SidebarBoxRowState.invalid,
            ),
        ],
      ],
    );
  }
}
```

If `_SectionTitle` does not currently accept a key, update its constructor to include `super.key`.

- [ ] **Step 8: Simplify `_BoxRow` content**

Add enum:

```dart
enum _SidebarBoxRowState { unlabeled, labeled, invalid }
```

Update `_BoxRow` constructor to require:

```dart
    required this.rowState,
```

and field:

```dart
  final _SidebarBoxRowState rowState;
```

Replace the row title/status/coordinate body with:

```dart
    final title = switch (rowState) {
      _SidebarBoxRowState.unlabeled => WorkbenchCopy.unlabeledBox,
      _SidebarBoxRowState.labeled => label?.name ?? WorkbenchCopy.unlabeledBox,
      _SidebarBoxRowState.invalid => WorkbenchCopy.error,
    };
```

Inside the row, keep one color strip/dot and one title:

```dart
                Container(
                  key: ValueKey('box-color-${box.id}'),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: rowState == _SidebarBoxRowState.unlabeled
                        ? Theme.of(context).colorScheme.outline
                        : color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight:
                              selected ? FontWeight.w800 : FontWeight.w600,
                        ),
                  ),
                ),
```

Remove `_StatusBadge` and coordinate text from `_BoxRow`.

- [ ] **Step 9: Run widget tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test/ui/workbench_widget_test.dart
```

Expected: PASS for grouping, hidden origin, and row compactness tests.

- [ ] **Step 10: Checkpoint**

Run:

```powershell
Test-Path .git
```

Expected: `False`. Do not run `git commit`.

---

### Task 3: Move Coordinates Into Low-Priority Details Area And Preserve Removal Flow

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Test: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: `AppController.selectedBox`, `_SelectedBoxDetails`, `_removeImageFromProject`.
- Produces:
  - Details section key: `ValueKey('right-sidebar-details')`
  - Selected coordinates remain available only in details area.
  - Remove flow still works through overflow menu.

- [ ] **Step 1: Update selected box details test**

In `test/ui/workbench_widget_test.dart`, replace expectations that look for `WorkbenchCopy.selectedBox` in the inspector with:

```dart
      expect(find.text(WorkbenchCopy.selectedBox), findsNothing);
      expect(find.text(WorkbenchCopy.details), findsOneWidget);
      expect(find.byKey(const ValueKey('right-sidebar-details')), findsOneWidget);
```

Keep expectations that selected coordinates are visible after selecting a box.

- [ ] **Step 2: Add details area test for image dimensions without selected box**

Add:

```dart
    testWidgets('right sidebar details show image dimensions without selection', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());

      await tester.pumpWidget(_app(controller));

      final details = find.byKey(const ValueKey('right-sidebar-details'));
      expect(details, findsOneWidget);
      expect(
        find.descendant(of: details, matching: find.text('이미지 100 x 80')),
        findsOneWidget,
      );
    });
```

- [ ] **Step 3: Update remove-image widget test to use overflow menu**

In `removes selected image from project after confirmation`, replace:

```dart
      await tester.tap(find.byKey(const ValueKey('remove-image-from-project')));
```

with:

```dart
      await tester.tap(find.byKey(const ValueKey('image-actions-menu')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('remove-image-from-project-menu-item')),
      );
```

- [ ] **Step 4: Run widget tests to verify they fail**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test/ui/workbench_widget_test.dart
```

Expected: FAIL if the details section still uses the old `선택 박스` heading or remove flow still expects the large button.

- [ ] **Step 5: Replace selected box section with details section**

In `_InspectorPanelState.build`, replace:

```dart
              if (widget.controller.selectedBox != null) ...[
                const SizedBox(height: 12),
                const _SectionTitle(WorkbenchCopy.selectedBox),
                const SizedBox(height: 8),
                _SelectedBoxDetails(box: widget.controller.selectedBox!),
              ],
```

with:

```dart
              const SizedBox(height: 16),
              _RightSidebarDetails(
                image: image,
                selectedBox: widget.controller.selectedBox,
              ),
```

Add widget:

```dart
class _RightSidebarDetails extends StatelessWidget {
  const _RightSidebarDetails({
    required this.image,
    required this.selectedBox,
  });

  final AnnotatedImage image;
  final BoundingBox? selectedBox;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('right-sidebar-details'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle(WorkbenchCopy.details),
        const SizedBox(height: 8),
        if (selectedBox != null) ...[
          _SelectedBoxDetails(box: selectedBox!),
          const SizedBox(height: 8),
        ],
        Text(
          '이미지 ${image.width} x ${image.height}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}
```

- [ ] **Step 6: Simplify `_SelectedBoxDetails` visual weight**

In `_SelectedBoxDetails`, remove the card-like decoration if present and replace with low-emphasis text wrapping:

```dart
    return Wrap(
      key: const ValueKey('selected-box-details'),
      spacing: 10,
      runSpacing: 6,
      children: [
        Text('x ${box.x.toStringAsFixed(0)}'),
        Text('y ${box.y.toStringAsFixed(0)}'),
        Text('w ${box.width.toStringAsFixed(0)}'),
        Text('h ${box.height.toStringAsFixed(0)}'),
        Text('면적 ${box.area.toStringAsFixed(0)}'),
      ],
    );
```

- [ ] **Step 7: Run widget tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test/ui/workbench_widget_test.dart
```

Expected: PASS for details and remove-flow tests.

- [ ] **Step 8: Checkpoint**

Run:

```powershell
Test-Path .git
```

Expected: `False`. Do not run `git commit`.

---

### Task 4: Full Verification

**Files:**
- Verify: all modified Dart files and tests.

**Interfaces:**
- Consumes: Task 1-3 outputs.
- Produces: verified right-sidebar workflow panel ready for review.

- [ ] **Step 1: Run analyzer**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' analyze
```

Expected: exits with code 0 and reports `No issues found!`.

- [ ] **Step 2: Run full test suite**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test
```

Expected: exits with code 0 and all tests pass.

- [ ] **Step 3: Build Windows app**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' build windows
```

Expected: exits with code 0 and writes `build\windows\x64\runner\Release\bbox_labeler.exe`.

- [ ] **Step 4: Manual smoke checklist**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' run -d windows
```

Check:

```text
1. Right sidebar has no "선택 이미지" heading.
2. File name and compact work summary are at the top.
3. "이미지 제거" is only in the overflow menu.
4. Normal box rows do not show "자동 박스".
5. Unlabeled boxes show "라벨 필요".
6. Labeled boxes appear under "완료".
7. Coordinates appear only in "상세".
8. Completion blockers still appear below the primary button.
9. Clicking a row still selects the canvas box.
10. Ctrl+Enter and label shortcuts keep their text-input guards.
```

- [ ] **Step 5: Final checkpoint**

Run:

```powershell
Test-Path .git
```

Expected: `False`. Do not run `git commit`.

---

## Self-Review Notes

- Spec coverage: Task 1 covers header, summary, no-image state, and overflow remove; Task 2 covers grouped compact box rows and hidden automatic origin; Task 3 covers details metadata and removal flow; Task 4 covers verification.
- Scope remains right-sidebar only. Canvas automatic box behavior and data semantics are not changed.
- Automatic/proposal origin remains internal and is not shown in normal right-sidebar rows.
- The existing no-Git workspace constraint is reflected in checkpoint steps.
