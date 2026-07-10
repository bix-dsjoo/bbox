# Right Panel Box Table Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only `표 보기` tab to the right workbench panel that displays the selected image's visible boxes as `Number / Class / X / Y / Width / Height`.

**Architecture:** Keep this as a UI-only workbench change. `_InspectorPanel` owns local tab state, the existing work view remains the default, and `_BoxTableView` renders the same `AnnotatedImage.visibleBoxes` data already used by the sidebar list.

**Tech Stack:** Flutter, Dart widget tests with `flutter_test`, existing `AppController`, `AnnotationProject`, `AnnotatedImage`, and `BoundingBox` models.

## Global Constraints

- The table is read-only: no cell editing, coordinate editing, sorting, search, copy/export, or model changes.
- The selected tab is local UI state only and is not saved to the project file.
- The table displays original-image pixel coordinates from `BoundingBox`, rounded with `toStringAsFixed(0)`.
- Deleted boxes are excluded by using `AnnotatedImage.visibleBoxes`.
- The existing `작업` view remains the default and keeps the current completion footer behavior.
- Table rows and canvas boxes stay selection-synchronized through `controller.selectBox(box.id)`.
- `C:\workspace\bbox` is currently not a Git repository. Run git commands only if `git rev-parse --show-toplevel` succeeds.

---

## File Structure

- Modify `lib/ui/workbench/inspector_panel.dart`: convert `_InspectorPanel` to local state, add tab bar widgets, add `_BoxTableView`, and preserve existing work-tab widgets.
- Modify `lib/ui/workbench_copy.dart`: add copy constants for the two tab labels, table empty state, and unlabeled table cell text.
- Modify `test/ui/workbench/inspector_panel_test.dart`: add widget tests for the new tabs, table content, row selection, selected row highlighting, deleted-box exclusion, and empty table state.

No data model, export, detector, project serialization, or coordinate transform files should change.

---

### Task 1: Add Failing Tests For The Table Tab Happy Path

**Files:**
- Modify: `C:\workspace\bbox\test\ui\workbench\inspector_panel_test.dart`

**Interfaces:**
- Consumes: existing `app(controller)`, `project()`, `mixedBoxProject()`, `tapVisible(...)`, and `AppController`.
- Produces: failing tests that require `작업` / `표 보기` tabs, table headers, table rows, row-click selection, and selected-row highlighting.

- [ ] **Step 1: Add tests near the other `right sidebar` tests**

Add this block inside the existing `group('WorkbenchScreen', () { ... })` in `C:\workspace\bbox\test\ui\workbench\inspector_panel_test.dart`:

```dart
    testWidgets('right sidebar defaults to work tab and can show table tab', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(mixedBoxProject());

      await tester.pumpWidget(app(controller));

      final inspector = find.byKey(const ValueKey('inspector-panel'));
      expect(
        find.descendant(of: inspector, matching: find.text('작업')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inspector, matching: find.text('표 보기')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: inspector,
          matching: find.byKey(const ValueKey('sidebar-box-scroll')),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('box-table-view')), findsNothing);

      await tester.tap(find.text('표 보기'));
      await tester.pump();

      expect(find.byKey(const ValueKey('box-table-view')), findsOneWidget);
      for (final header in ['Number', 'Class', 'X', 'Y', 'Width', 'Height']) {
        expect(find.text(header), findsOneWidget);
      }
    });

    testWidgets('box table shows labels, unlabeled cells, and rounded coords', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(mixedBoxProject());

      await tester.pumpWidget(app(controller));
      await tester.tap(find.text('표 보기'));
      await tester.pump();

      final table = tester.widget<DataTable>(find.byType(DataTable));
      expect(
        table.rows.map((row) => row.key),
        containsAll(const [
          ValueKey('box-table-row-box-labeled'),
          ValueKey('box-table-row-box-unlabeled'),
        ]),
      );
      expect(find.text('1'), findsWidgets);
      expect(find.text('2'), findsWidgets);
      expect(find.text('Person'), findsOneWidget);
      expect(find.text('미라벨'), findsOneWidget);
      expect(find.text('40'), findsWidgets);
      expect(find.text('10'), findsWidgets);
      expect(find.text('20'), findsWidgets);
    });

    testWidgets('clicking a box table row selects the canvas box', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(mixedBoxProject());

      await tester.pumpWidget(app(controller));
      await tester.tap(find.text('표 보기'));
      await tester.pump();
      await tester.tap(find.text('미라벨'));
      await tester.pump();

      expect(controller.selectedBoxId, 'box-unlabeled');
      expect(
        find.byKey(const ValueKey('selected-box-box-unlabeled')),
        findsOneWidget,
      );
    });

    testWidgets('box table highlights the selected box row', (tester) async {
      final controller = AppController();
      controller.loadProject(mixedBoxProject());
      controller.selectBox('box-unlabeled');

      await tester.pumpWidget(app(controller));
      await tester.tap(find.text('표 보기'));
      await tester.pump();

      final table = tester.widget<DataTable>(find.byType(DataTable));
      final selectedRow = table.rows.singleWhere(
        (row) => row.key == const ValueKey('box-table-row-box-unlabeled'),
      );
      final otherRow = table.rows.singleWhere(
        (row) => row.key == const ValueKey('box-table-row-box-labeled'),
      );

      expect(selectedRow.selected, isTrue);
      expect(otherRow.selected, isFalse);
    });
```

- [ ] **Step 2: Run the new tests and verify they fail**

Run:

```powershell
flutter test test/ui/workbench/inspector_panel_test.dart --plain-name "right sidebar defaults to work tab and can show table tab"
flutter test test/ui/workbench/inspector_panel_test.dart --plain-name "box table shows labels, unlabeled cells, and rounded coords"
flutter test test/ui/workbench/inspector_panel_test.dart --plain-name "clicking a box table row selects the canvas box"
flutter test test/ui/workbench/inspector_panel_test.dart --plain-name "box table highlights the selected box row"
```

Expected: each test fails because the `표 보기` tab and table widgets do not exist yet.

- [ ] **Step 3: Record git status if available**

Run:

```powershell
git rev-parse --show-toplevel
```

Expected in the current workspace: `fatal: not a git repository`. If it succeeds in a later workspace, run:

```powershell
git status --short
```

---

### Task 2: Implement The Inspector Tabs And Read-Only Table

**Files:**
- Modify: `C:\workspace\bbox\lib\ui\workbench_copy.dart`
- Modify: `C:\workspace\bbox\lib\ui\workbench\inspector_panel.dart`
- Test: `C:\workspace\bbox\test\ui\workbench\inspector_panel_test.dart`

**Interfaces:**
- Consumes: `_boxDisplayNumbers(AnnotatedImage image)`, `_boxDisplayNumber(...)`, `_labelFor(...)`, `_boxIsInvalid(...)`, `controller.selectedBoxId`, `controller.selectBox(String boxId)`.
- Produces: `_InspectorPanelTab`, `_InspectorTabBar`, `_InspectorTabButton`, `_BoxTableView`, and `_BoxTableRow`.

- [ ] **Step 1: Add copy constants**

In `C:\workspace\bbox\lib\ui\workbench_copy.dart`, add these constants near the existing inspector/sidebar copy constants:

```dart
  static const inspectorWorkTab = '작업';
  static const inspectorTableTab = '표 보기';
  static const boxTableUnlabeled = '미라벨';
```

- [ ] **Step 2: Convert `_InspectorPanel` to stateful and add tab switching**

In `C:\workspace\bbox\lib\ui\workbench\inspector_panel.dart`, replace:

```dart
class _InspectorPanel extends StatelessWidget {
  const _InspectorPanel({required this.controller, required this.project});

  final AppController controller;
  final AnnotationProject project;

  @override
  Widget build(BuildContext context) {
```

with:

```dart
enum _InspectorPanelTab { work, table }

class _InspectorPanel extends StatefulWidget {
  const _InspectorPanel({required this.controller, required this.project});

  final AppController controller;
  final AnnotationProject project;

  @override
  State<_InspectorPanel> createState() => _InspectorPanelState();
}

class _InspectorPanelState extends State<_InspectorPanel> {
  _InspectorPanelTab _selectedTab = _InspectorPanelTab.work;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final project = widget.project;
```

At the end of the original `_InspectorPanel.build` method, close `_InspectorPanelState` with the same two braces that closed the old method and class.

- [ ] **Step 3: Replace the old body middle section with tab-aware content**

Inside `_InspectorPanelState.build`, replace the block that starts with:

```dart
                  if (selectedBox != null) ...[
                    const SizedBox(height: 12),
                    const _SectionTitle(WorkbenchCopy.details),
                    const SizedBox(height: 8),
                    _SelectedBoxDetails(
                      project: project,
                      box: selectedBox,
                      displayNumber: _boxDisplayNumber(
                        boxDisplayNumbers,
                        selectedBox,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Expanded(
                    child: SingleChildScrollView(
                      key: const ValueKey('sidebar-box-scroll'),
                      child: _SidebarBoxList(
                        controller: controller,
                        project: project,
                        image: image,
                      ),
                    ),
                  ),
```

with:

```dart
                  const SizedBox(height: 12),
                  _InspectorTabBar(
                    selectedTab: _selectedTab,
                    onSelected: (tab) => setState(() => _selectedTab = tab),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: switch (_selectedTab) {
                      _InspectorPanelTab.work => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (selectedBox != null) ...[
                              const _SectionTitle(WorkbenchCopy.details),
                              const SizedBox(height: 8),
                              _SelectedBoxDetails(
                                project: project,
                                box: selectedBox,
                                displayNumber: _boxDisplayNumber(
                                  boxDisplayNumbers,
                                  selectedBox,
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],
                            Expanded(
                              child: SingleChildScrollView(
                                key: const ValueKey('sidebar-box-scroll'),
                                child: _SidebarBoxList(
                                  controller: controller,
                                  project: project,
                                  image: image,
                                ),
                              ),
                            ),
                          ],
                        ),
                      _InspectorPanelTab.table => _BoxTableView(
                          controller: controller,
                          project: project,
                          image: image,
                        ),
                    },
                  ),
```

- [ ] **Step 4: Add the tab bar widgets**

Add this code below `_InspectorCompletionFooter` in `C:\workspace\bbox\lib\ui\workbench\inspector_panel.dart`:

```dart
class _InspectorTabBar extends StatelessWidget {
  const _InspectorTabBar({
    required this.selectedTab,
    required this.onSelected,
  });

  final _InspectorPanelTab selectedTab;
  final ValueChanged<_InspectorPanelTab> onSelected;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: WorkbenchPalette.panelMuted,
        borderRadius: BorderRadius.circular(AppRadii.row),
        border: Border.all(color: WorkbenchPalette.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(
          children: [
            Expanded(
              child: _InspectorTabButton(
                label: WorkbenchCopy.inspectorWorkTab,
                selected: selectedTab == _InspectorPanelTab.work,
                onPressed: () => onSelected(_InspectorPanelTab.work),
              ),
            ),
            Expanded(
              child: _InspectorTabButton(
                label: WorkbenchCopy.inspectorTableTab,
                selected: selectedTab == _InspectorPanelTab.table,
                onPressed: () => onSelected(_InspectorPanelTab.table),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InspectorTabButton extends StatelessWidget {
  const _InspectorTabButton({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: selected ? null : onPressed,
      style: TextButton.styleFrom(
        foregroundColor: selected
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.onSurfaceVariant,
        backgroundColor: selected
            ? Theme.of(context).colorScheme.primary.withAlpha(18)
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.row - 2),
        ),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
```

- [ ] **Step 5: Add the read-only table widgets**

Add this code below `_SidebarBoxList` and above `_SectionTitle`:

```dart
class _BoxTableView extends StatelessWidget {
  const _BoxTableView({
    required this.controller,
    required this.project,
    required this.image,
  });

  final AppController controller;
  final AnnotationProject project;
  final AnnotatedImage image;

  @override
  Widget build(BuildContext context) {
    final boxes = image.visibleBoxes.toList(growable: false);
    if (boxes.isEmpty) {
      return const Center(child: Text(WorkbenchCopy.boxesNone));
    }

    final boxDisplayNumbers = _boxDisplayNumbers(image);
    return Scrollbar(
      thumbVisibility: true,
      child: SingleChildScrollView(
        key: const ValueKey('box-table-view'),
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 360),
          child: SingleChildScrollView(
            child: DataTable(
              headingRowHeight: 36,
              dataRowMinHeight: 36,
              dataRowMaxHeight: 42,
              columnSpacing: 16,
              horizontalMargin: 10,
              columns: const [
                DataColumn(label: Text('Number')),
                DataColumn(label: Text('Class')),
                DataColumn(label: Text('X'), numeric: true),
                DataColumn(label: Text('Y'), numeric: true),
                DataColumn(label: Text('Width'), numeric: true),
                DataColumn(label: Text('Height'), numeric: true),
              ],
              rows: [
                for (final box in boxes)
                  _BoxTableRow(
                    controller: controller,
                    project: project,
                    image: image,
                    box: box,
                    displayNumber: _boxDisplayNumber(
                      boxDisplayNumbers,
                      box,
                    ),
                  ).buildRow(context),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BoxTableRow {
  const _BoxTableRow({
    required this.controller,
    required this.project,
    required this.image,
    required this.box,
    required this.displayNumber,
  });

  final AppController controller;
  final AnnotationProject project;
  final AnnotatedImage image;
  final BoundingBox box;
  final int displayNumber;

  DataRow buildRow(BuildContext context) {
    final label =
        _labelFor(project, box.labelId)?.name ?? WorkbenchCopy.boxTableUnlabeled;
    final selected = controller.selectedBoxId == box.id;
    final invalid = _boxIsInvalid(image, box);
    final color = WidgetStateProperty.resolveWith<Color?>((states) {
      if (selected) {
        return Theme.of(context).colorScheme.primary.withAlpha(18);
      }
      if (invalid) {
        return Theme.of(context).colorScheme.error.withAlpha(10);
      }
      return null;
    });

    return DataRow(
      key: ValueKey('box-table-row-${box.id}'),
      color: color,
      selected: selected,
      onSelectChanged: controller.isAutomationRunning
          ? null
          : (_) => controller.selectBox(box.id),
      cells: [
        DataCell(Text(displayNumber.toString())),
        DataCell(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (invalid) ...[
                Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        DataCell(Text(box.x.toStringAsFixed(0))),
        DataCell(Text(box.y.toStringAsFixed(0))),
        DataCell(Text(box.width.toStringAsFixed(0))),
        DataCell(Text(box.height.toStringAsFixed(0))),
      ],
    );
  }
}
```

- [ ] **Step 6: Run the Task 1 tests**

Run:

```powershell
flutter test test/ui/workbench/inspector_panel_test.dart --plain-name "right sidebar defaults to work tab and can show table tab"
flutter test test/ui/workbench/inspector_panel_test.dart --plain-name "box table shows labels, unlabeled cells, and rounded coords"
flutter test test/ui/workbench/inspector_panel_test.dart --plain-name "clicking a box table row selects the canvas box"
flutter test test/ui/workbench/inspector_panel_test.dart --plain-name "box table highlights the selected box row"
```

Expected: all four tests pass.

- [ ] **Step 7: Run analyzer and targeted inspector tests**

Run:

```powershell
flutter analyze
flutter test test/ui/workbench/inspector_panel_test.dart
```

Expected: analyzer passes and all inspector panel tests pass.

- [ ] **Step 8: Commit if git is available**

Run:

```powershell
git rev-parse --show-toplevel
```

If it succeeds, run:

```powershell
git add lib/ui/workbench_copy.dart lib/ui/workbench/inspector_panel.dart test/ui/workbench/inspector_panel_test.dart
git commit -m "feat: add read-only box table tab"
```

If it fails with `fatal: not a git repository`, leave the changes uncommitted and mention that in the task handoff.

---

### Task 3: Cover Empty And Deleted Box Edge States

**Files:**
- Modify: `C:\workspace\bbox\test\ui\workbench\inspector_panel_test.dart`
- Modify if tests fail: `C:\workspace\bbox\lib\ui\workbench\inspector_panel.dart`

**Interfaces:**
- Consumes: `_BoxTableView` from Task 2 and existing model constructors.
- Produces: tests confirming no-box and deleted-box behavior.

- [ ] **Step 1: Add edge-state tests**

Add this block inside the same `group('WorkbenchScreen', () { ... })`:

```dart
    testWidgets('box table shows an empty state for images with no boxes', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());
      controller.selectImage(2);

      await tester.pumpWidget(app(controller));
      await tester.tap(find.text('표 보기'));
      await tester.pump();

      expect(find.byKey(const ValueKey('box-table-view')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('inspector-panel')),
          matching: find.text(WorkbenchCopy.boxesNone),
        ),
        findsOneWidget,
      );
    });

    testWidgets('box table excludes deleted boxes', (tester) async {
      final deletedBoxProject = project().copyWith(
        images: [
          project().images.first.copyWith(
            boxes: const [
              BoundingBox(
                id: 'box-visible',
                x: 11,
                y: 12,
                width: 13,
                height: 14,
                status: BoxStatus.labeled,
                labelId: 1,
              ),
              BoundingBox(
                id: 'box-deleted',
                x: 21,
                y: 22,
                width: 23,
                height: 24,
                status: BoxStatus.deleted,
              ),
            ],
          ),
          project().images.last,
        ],
      );
      final controller = AppController();
      controller.loadProject(deletedBoxProject);

      await tester.pumpWidget(app(controller));
      await tester.tap(find.text('표 보기'));
      await tester.pump();

      final table = tester.widget<DataTable>(find.byType(DataTable));
      expect(
        table.rows.map((row) => row.key),
        contains(const ValueKey('box-table-row-box-visible')),
      );
      expect(
        table.rows.map((row) => row.key),
        isNot(contains(const ValueKey('box-table-row-box-deleted'))),
      );
      expect(find.text('21'), findsNothing);
      expect(find.text('22'), findsNothing);
      expect(find.text('23'), findsNothing);
      expect(find.text('24'), findsNothing);
    });
```

- [ ] **Step 2: Run the edge-state tests**

Run:

```powershell
flutter test test/ui/workbench/inspector_panel_test.dart --plain-name "box table shows an empty state for images with no boxes"
flutter test test/ui/workbench/inspector_panel_test.dart --plain-name "box table excludes deleted boxes"
```

Expected: both pass after Task 2. If the empty-state test finds multiple `박스 없음` texts, keep the descendant finder scoped to `inspector-panel` exactly as shown.

- [ ] **Step 3: Add invalid-row warning test**

Add this test to verify that invalid coordinates remain visible and get warning
treatment:

```dart
    testWidgets('box table marks invalid boxes with a warning icon', (
      tester,
    ) async {
      final invalidProject = project().copyWith(
        images: [
          project().images.first.copyWith(
            boxes: const [
              BoundingBox(
                id: 'box-invalid',
                x: 90,
                y: 70,
                width: 20,
                height: 20,
                status: BoxStatus.labeled,
                labelId: 1,
              ),
            ],
          ),
          project().images.last,
        ],
      );
      final controller = AppController();
      controller.loadProject(invalidProject);

      await tester.pumpWidget(app(controller));
      await tester.tap(find.text('표 보기'));
      await tester.pump();

      expect(
        find.byIcon(Icons.warning_amber_rounded),
        findsOneWidget,
      );
    });
```

Run:

```powershell
flutter test test/ui/workbench/inspector_panel_test.dart --plain-name "box table marks invalid boxes with a warning icon"
```

Expected: pass if Task 2 used the planned warning icon.

- [ ] **Step 4: Run the full related test set**

Run:

```powershell
flutter test test/ui/workbench/inspector_panel_test.dart
flutter test test/ui/workbench/canvas_overlay_test.dart
flutter test test/ui/workbench/canvas_interaction_test.dart
```

Expected: all pass. These related canvas tests confirm row selection did not break canvas selection/overlay behavior.

- [ ] **Step 5: Commit if git is available**

Run:

```powershell
git rev-parse --show-toplevel
```

If it succeeds, run:

```powershell
git add lib/ui/workbench/inspector_panel.dart test/ui/workbench/inspector_panel_test.dart
git commit -m "test: cover box table edge states"
```

If it fails with `fatal: not a git repository`, leave the changes uncommitted and mention that in the task handoff.

---

### Task 4: Final Verification

**Files:**
- Verify: `C:\workspace\bbox\lib\ui\workbench\inspector_panel.dart`
- Verify: `C:\workspace\bbox\lib\ui\workbench_copy.dart`
- Verify: `C:\workspace\bbox\test\ui\workbench\inspector_panel_test.dart`

**Interfaces:**
- Consumes: all completed implementation and tests.
- Produces: verification evidence that the feature is complete.

- [ ] **Step 1: Run static analysis**

Run:

```powershell
flutter analyze
```

Expected: `No issues found!`

- [ ] **Step 2: Run the workbench widget tests**

Run:

```powershell
flutter test test/ui/workbench
```

Expected: all workbench widget tests pass.

- [ ] **Step 3: Run the full Flutter test suite**

Run:

```powershell
flutter test
```

Expected: all tests pass.

- [ ] **Step 4: Manual desktop smoke check**

Run:

```powershell
flutter run -d windows
```

Manual expected results:

- Open or create a project with at least one image containing boxes.
- The right panel defaults to `작업`.
- Click `표 보기`; the table shows `Number`, `Class`, `X`, `Y`, `Width`, `Height`.
- Click a table row; the matching canvas box becomes selected.
- Select a box on the canvas; return to `표 보기`; the matching table row is selected.
- Select an image with no boxes; `표 보기` shows `박스 없음`.

- [ ] **Step 5: Commit final verification note if git is available**

Run:

```powershell
git rev-parse --show-toplevel
```

If it succeeds and there are uncommitted verification-only changes, commit them. If it fails with `fatal: not a git repository`, report that verification was performed without Git commits.
