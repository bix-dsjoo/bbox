# Roboflow + CVAT Hybrid Workbench Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the selected hybrid workbench direction: Roboflow-like fast label assignment in the canvas/inspector flow, CVAT-like reliable box review in the right panel, and clean Korean desktop UI copy.

**Architecture:** Keep the existing `WorkbenchScreen`, `AppController`, `CanvasTool`, and annotation domain models. Add one small reusable label selector widget, then wire it into the existing inspector and canvas flow without changing COCO export or coordinate storage. Improve presentation widgets in place before extracting larger files.

**Tech Stack:** Flutter desktop, Dart 3.12, Material 3 widgets, existing `ChangeNotifier` `AppController`, existing annotation models/rules, `C:\tools\flutter\bin\flutter.bat`, and `C:\tools\flutter\bin\cache\dart-sdk\bin\dart.exe`.

## Global Constraints

- Use the approved C hybrid direction: Roboflow-like speed in the center, CVAT-like box review in the right inspector.
- Do not add cloud, account, collaboration, review assignment, or multi-user workflows.
- Do not add CVAT track, propagate, layer ordering, pin, lock, hide, or occlusion controls in the MVP UI.
- Do not imply that dummy or algorithmic proposals are real AI model results.
- Do not change annotation domain models unless required by the UI workflow.
- Do not change COCO export rules.
- All box coordinates remain original image pixel coordinates.
- Proposal boxes are suggestions and are not exported as COCO annotations.
- A new box whose label selector is cancelled remains selected as an unlabeled box and keeps the image unconfirmable.
- Use clean Korean text for visible app copy.
- Avoid nested cards and keep the UI compact for Windows desktop labeling.
- `.superpowers/` is local visual brainstorming output and must remain ignored.
- This workspace currently may not have `.git`; if `Test-Path .git` is `False`, skip commit steps and report that commit was skipped.

---

## File Structure

- Modify `lib/ui/workbench_copy.dart`
  - Owns clean Korean workbench copy and status labels.

- Modify `lib/ui/workbench_screen.dart`
  - Keeps the workbench shell, image queue, canvas, inspector, and small private presentation widgets.
  - Wires the label selector into selected-box workflows.
  - Upgrades box rows and selected-box details.

- Create `lib/ui/workbench_label_selector.dart`
  - A focused, testable Roboflow-style label selector panel.
  - Provides filtering, existing label selection, create-label action, color dots, and keyboard-friendly submit.

- Modify `test/ui/workbench_widget_test.dart`
  - Updates expectations to clean Korean copy.
  - Adds selected-box label selector and CVAT-style box row tests.

- Create `test/ui/workbench_label_selector_test.dart`
  - Tests label filtering, assignment, create-label row, duplicate error display contract, and `Enter` behavior.

- Verify existing tests in:
  - `test/annotation/annotation_rules_test.dart`
  - `test/export/coco_exporter_test.dart`
  - `test/ui/canvas_interaction_test.dart`
  - `test/ui/workbench_widget_test.dart`

---

### Task 1: Clean Korean Copy And Stabilize Existing Workbench Tests

**Files:**
- Modify: `lib/ui/workbench_copy.dart`
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes:
  - `ImageStatus`
  - existing `WorkbenchCopy` call sites
- Produces:
  - Clean `WorkbenchCopy` constants
  - `WorkbenchCopy.imageStatusLabel(ImageStatus status) -> String`
  - Workbench tests that no longer assert mojibake/corrupted Korean strings

- [ ] **Step 1: Replace `WorkbenchCopy` with clean Korean copy**

Replace the full contents of `lib/ui/workbench_copy.dart` with:

```dart
import '../annotation/models.dart';

class WorkbenchCopy {
  const WorkbenchCopy._();

  static const projectHome = '프로젝트 홈';
  static const projectHomeTooltip = '저장하고 프로젝트 홈으로 돌아가기';
  static const saveProjectTooltip = '프로젝트 저장';
  static const imageFolder = '이미지 폴더';
  static const chooseImageFolder = '이미지 폴더 선택';
  static const imageAdd = '이미지 추가';
  static const addImageFiles = '이미지 파일 추가';
  static const addImageFolder = '폴더 추가';
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
  static const noImagesYet = '아직 이미지가 없습니다';
  static const chooseFolderToStart = '이미지를 추가하면 라벨링을 시작할 수 있습니다.';
  static const originalImagesUnchanged = '원본 이미지는 수정하지 않습니다.';
  static const selectImageFromQueue = '왼쪽 목록에서 이미지를 선택하세요.';
  static const noImageSelected = '선택한 이미지가 없습니다';
  static const selectImageForInspector = '이미지를 선택하면 박스와 라벨을 확인할 수 있습니다.';
  static const selectedImage = '선택 이미지';
  static const labels = '라벨';
  static const boxes = '박스';
  static const selectedBox = '선택 박스';
  static const newLabel = '새 라벨';
  static const createLabel = '라벨 만들기';
  static const createLabelTooltip = '라벨 생성';
  static const duplicateLabel = '이미 있는 라벨명입니다.';
  static const enterLabelName = '라벨명을 입력하세요.';
  static const noBoxes = '박스 없음';
  static const unlabeledBox = '미라벨';
  static const proposalBox = '후보';
  static const labeledBox = '라벨됨';
  static const invalidBox = '오류';
  static const confirm = '확정';
  static const confirmNoObject = '객체 없음으로 확정';
  static const confirmNoObjectAvailable = '객체 없음으로 확정할 수 있습니다.';
  static const deleteSelectedBox = '선택 박스 삭제';
  static const removeImageFromProject = '이미지 삭제';
  static const removeImageTitle = '선택 이미지 삭제';
  static const removeImageMessage = '선택한 이미지가 프로젝트 목록에서 삭제됩니다.';
  static const loadingImage = '이미지 로딩 중';
  static const replaceImagesTitle = '이미지 목록 다시 불러오기';
  static const replaceImagesMessage = '기존 이미지 목록을 선택한 이미지로 바꿀까요?';
  static const cancel = '취소';
  static const importImages = '불러오기';
  static const close = '닫기';
  static const continueAction = '계속';
  static const selectMoveTool = '선택/이동';
  static const selectMoveTooltip = '박스 선택, 이동, 크기 변경';
  static const drawBoxTool = '박스 그리기';
  static const drawBoxTooltip = '새 박스 그리기(B)';
  static const panTool = '이미지 이동';
  static const panTooltip = '이미지 이동(Space)';
  static const labelSelectorHint = '라벨 검색 또는 새 라벨 입력';
  static const assignLabel = '라벨 지정';
  static const createTypedLabel = '새 라벨 만들기';
  static const noMatchingLabels = '일치하는 라벨이 없습니다.';

  static String imageStatusLabel(ImageStatus status) {
    return switch (status) {
      ImageStatus.queued => '대기',
      ImageStatus.detecting => '탐지 중',
      ImageStatus.needsReview => '미확정',
      ImageStatus.confirmed => '확정',
      ImageStatus.error => '오류',
    };
  }
}
```

- [ ] **Step 2: Replace remaining corrupted summary and error strings in `WorkbenchScreen`**

In `lib/ui/workbench_screen.dart`, update the image queue summary inside `_ImageListPanel.build` to:

```dart
summary:
    '${project.images.length}개 · 미확정 $needsReviewCount · '
    '확정 $confirmedCount · 오류 $errorCount',
```

Update `_addImageFolder` catch message to:

```dart
_showError(context, '이미지 폴더를 불러오지 못했습니다. $error');
```

Update the `project == null` fallback text to:

```dart
body: Center(child: Text('프로젝트를 만들거나 기존 프로젝트를 여세요.')),
```

- [ ] **Step 3: Update workbench tests to clean copy**

In `test/ui/workbench_widget_test.dart`, replace corrupted text expectations:

```dart
expect(find.text(WorkbenchCopy.chooseFolderToStart), findsWidgets);
expect(find.textContaining('3개'), findsOneWidget);
expect(find.textContaining('미확정 1'), findsOneWidget);
expect(find.textContaining('확정 1'), findsOneWidget);
expect(find.textContaining('오류 1'), findsOneWidget);
```

Keep existing imports for `WorkbenchCopy`.

- [ ] **Step 4: Verify no corrupted visible copy remains in workbench UI/tests**

Run:

```powershell
rg -n "�|揶|獄|沃|筌|醫|誘|뺤|대\\?|꾨|쇰|諛" lib\ui test\ui
```

Expected: no matches and exit code `1`. If matches remain in visible copy or test expectations, replace them with `WorkbenchCopy` constants or clean Korean text.

- [ ] **Step 5: Run focused tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart -r expanded
```

Expected: all tests in `test\ui\workbench_widget_test.dart` pass.

- [ ] **Step 6: Commit or record skipped commit**

Run:

```powershell
Test-Path .git
```

If it returns `True`:

```powershell
git add lib\ui\workbench_copy.dart lib\ui\workbench_screen.dart test\ui\workbench_widget_test.dart
git commit -m "fix: clean workbench Korean copy"
```

If it returns `False`, record: `Commit skipped because C:\workspace\bbox is not a git repository.`

---

### Task 2: Add Roboflow-Style Label Selector Widget

**Files:**
- Create: `lib/ui/workbench_label_selector.dart`
- Create: `test/ui/workbench_label_selector_test.dart`

**Interfaces:**
- Consumes:
  - `List<LabelClass> labels`
  - `String? errorText`
  - `void Function(int labelId) onAssignLabel`
  - `void Function(String name) onCreateLabel`
- Produces:
  - `WorkbenchLabelSelector`
  - Widget keys:
    - `label-selector-panel`
    - `label-selector-input`
    - `label-option-<id>`
    - `create-label-option`
    - `label-selector-error`

- [ ] **Step 1: Write failing label selector widget tests**

Create `test/ui/workbench_label_selector_test.dart`:

```dart
import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/ui/workbench_copy.dart';
import 'package:bbox_labeler/ui/workbench_label_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('filters labels and assigns the selected label', (tester) async {
    int? assignedLabelId;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkbenchLabelSelector(
            labels: const [
              LabelClass(id: 1, name: 'Person', color: 0xffe64a19),
              LabelClass(id: 2, name: 'Vehicle', color: 0xff1976d2),
            ],
            onAssignLabel: (labelId) => assignedLabelId = labelId,
            onCreateLabel: (_) {},
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('label-selector-input')),
      'veh',
    );
    await tester.pump();

    expect(find.text('Vehicle'), findsOneWidget);
    expect(find.text('Person'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('label-option-2')));
    await tester.pump();

    expect(assignedLabelId, 2);
  });

  testWidgets('shows create option for typed new label', (tester) async {
    String? createdLabelName;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkbenchLabelSelector(
            labels: const [
              LabelClass(id: 1, name: 'Person', color: 0xffe64a19),
            ],
            onAssignLabel: (_) {},
            onCreateLabel: (name) => createdLabelName = name,
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('label-selector-input')),
      'Helmet',
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('create-label-option')), findsOneWidget);
    expect(find.textContaining('Helmet'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('create-label-option')));
    await tester.pump();

    expect(createdLabelName, 'Helmet');
  });

  testWidgets('enter creates typed label when there is no exact match', (
    tester,
  ) async {
    String? createdLabelName;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkbenchLabelSelector(
            labels: const [
              LabelClass(id: 1, name: 'Person', color: 0xffe64a19),
            ],
            onAssignLabel: (_) {},
            onCreateLabel: (name) => createdLabelName = name,
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('label-selector-input')),
      'Box',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(createdLabelName, 'Box');
  });

  testWidgets('shows inline error text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkbenchLabelSelector(
            labels: const [],
            errorText: WorkbenchCopy.duplicateLabel,
            onAssignLabel: (_) {},
            onCreateLabel: (_) {},
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('label-selector-error')), findsOneWidget);
    expect(find.text(WorkbenchCopy.duplicateLabel), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run new tests and verify they fail**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_label_selector_test.dart -r expanded
```

Expected: FAIL because `lib/ui/workbench_label_selector.dart` does not exist.

- [ ] **Step 3: Create `WorkbenchLabelSelector`**

Create `lib/ui/workbench_label_selector.dart`:

```dart
import 'package:flutter/material.dart';

import '../annotation/models.dart';
import 'workbench_copy.dart';

class WorkbenchLabelSelector extends StatefulWidget {
  const WorkbenchLabelSelector({
    super.key,
    required this.labels,
    required this.onAssignLabel,
    required this.onCreateLabel,
    this.errorText,
    this.autofocus = false,
  });

  final List<LabelClass> labels;
  final void Function(int labelId) onAssignLabel;
  final void Function(String name) onCreateLabel;
  final String? errorText;
  final bool autofocus;

  @override
  State<WorkbenchLabelSelector> createState() => _WorkbenchLabelSelectorState();
}

class _WorkbenchLabelSelectorState extends State<WorkbenchLabelSelector> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _controller.text.trim();
    final queryKey = query.toLowerCase();
    final filtered = widget.labels
        .where((label) => label.name.toLowerCase().contains(queryKey))
        .toList(growable: false);
    final exactMatch = widget.labels.any(
      (label) => label.name.toLowerCase() == queryKey,
    );
    final canCreate = query.isNotEmpty && !exactMatch;

    return Material(
      key: const ValueKey('label-selector-panel'),
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Theme.of(context).dividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('label-selector-input'),
              controller: _controller,
              autofocus: widget.autofocus,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                isDense: true,
                labelText: WorkbenchCopy.labelSelectorHint,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(filtered, canCreate, query),
            ),
            if (widget.errorText != null) ...[
              const SizedBox(height: 8),
              Text(
                widget.errorText!,
                key: const ValueKey('label-selector-error'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 8),
            if (filtered.isEmpty && !canCreate)
              Text(
                WorkbenchCopy.noMatchingLabels,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            for (var index = 0; index < filtered.length; index++)
              _LabelOption(
                key: ValueKey('label-option-${filtered[index].id}'),
                label: filtered[index],
                shortcut: index < 9 ? '${index + 1}' : null,
                onTap: () => widget.onAssignLabel(filtered[index].id),
              ),
            if (canCreate)
              _CreateLabelOption(
                key: const ValueKey('create-label-option'),
                name: query,
                onTap: () => widget.onCreateLabel(query),
              ),
          ],
        ),
      ),
    );
  }

  void _submit(List<LabelClass> filtered, bool canCreate, String query) {
    if (canCreate) {
      widget.onCreateLabel(query);
      return;
    }
    if (filtered.isNotEmpty) {
      widget.onAssignLabel(filtered.first.id);
    }
  }
}

class _LabelOption extends StatelessWidget {
  const _LabelOption({
    super.key,
    required this.label,
    required this.shortcut,
    required this.onTap,
  });

  final LabelClass label;
  final String? shortcut;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        child: Row(
          children: [
            if (shortcut != null) ...[
              SizedBox(
                width: 20,
                child: Text(
                  shortcut!,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ],
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: Color(label.color),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreateLabelOption extends StatelessWidget {
  const _CreateLabelOption({
    super.key,
    required this.name,
    required this.onTap,
  });

  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        child: Row(
          children: [
            const Icon(Icons.add, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${WorkbenchCopy.createTypedLabel}: $name',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run label selector tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_label_selector_test.dart -r expanded
```

Expected: all tests pass.

- [ ] **Step 5: Commit or record skipped commit**

Run:

```powershell
Test-Path .git
```

If it returns `True`:

```powershell
git add lib\ui\workbench_label_selector.dart test\ui\workbench_label_selector_test.dart
git commit -m "feat: add workbench label selector"
```

If it returns `False`, record: `Commit skipped because C:\workspace\bbox is not a git repository.`

---

### Task 3: Wire Label Selector Into Selected Box Workflow

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes:
  - `WorkbenchLabelSelector`
  - `AppController.selectedBoxId`
  - `AppController.addLabel(String name, int color) -> LabelClass`
  - `AppController.assignSelectedBoxLabel(int labelId) -> void`
- Produces:
  - Selected-box label selector visible when a box is selected
  - New labels created from selector are immediately assigned to the selected box
  - Widget key `selected-box-label-selector`

- [ ] **Step 1: Add failing workbench tests for selected-box label selector**

Add these tests inside `group('WorkbenchScreen', () { ... })` in `test/ui/workbench_widget_test.dart`:

```dart
    testWidgets('selecting a box shows the compact label selector', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());

      await tester.pumpWidget(_app(controller));
      await tester.tap(find.byKey(const ValueKey('box-row-box-1')));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('selected-box-label-selector')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('label-selector-input')),
        findsOneWidget,
      );
    });

    testWidgets('label selector assigns an existing label to selected box', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());

      await tester.pumpWidget(_app(controller));
      await tester.tap(find.byKey(const ValueKey('box-row-box-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('label-option-1')));
      await tester.pump();

      final box = controller.selectedImage!.boxes.single;
      expect(box.labelId, 1);
      expect(box.status, BoxStatus.labeled);
      expect(controller.canConfirmSelectedImage, isTrue);
    });

    testWidgets('label selector creates and assigns a new label', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project().copyWith(labels: const []));

      await tester.pumpWidget(_app(controller));
      await tester.tap(find.byKey(const ValueKey('box-row-box-1')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('label-selector-input')),
        'Helmet',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('create-label-option')));
      await tester.pump();

      final label = controller.project!.labels.single;
      final box = controller.selectedImage!.boxes.single;
      expect(label.name, 'Helmet');
      expect(box.labelId, label.id);
      expect(box.status, BoxStatus.labeled);
    });

    testWidgets('drawn unlabeled box stays selected and shows label selector', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());

      await tester.pumpWidget(_app(controller));
      await tester.tap(find.byKey(const ValueKey('canvas-tool-draw-box')));
      await tester.pump();
      await tester.drag(
        find.byKey(const ValueKey('image-canvas')),
        const Offset(80, 60),
      );
      await tester.pump();

      expect(controller.selectedBoxId, startsWith('manual-'));
      expect(controller.canConfirmSelectedImage, isFalse);
      expect(
        find.byKey(const ValueKey('selected-box-label-selector')),
        findsOneWidget,
      );
    });
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart -r expanded
```

Expected: FAIL because `selected-box-label-selector` is not wired into the inspector.

- [ ] **Step 3: Import the new selector**

In `lib/ui/workbench_screen.dart`, add:

```dart
import 'workbench_label_selector.dart';
```

- [ ] **Step 4: Add selected-box label selector state helpers**

Inside `_InspectorPanelState`, keep `_labelNameController` for the existing fallback label input, and add:

```dart
String? _selectorError;

int _nextLabelColor() {
  const colors = <int>[
    0xff7c3aed,
    0xff2563eb,
    0xff16a34a,
    0xffea580c,
    0xffdb2777,
    0xff0891b2,
  ];
  return colors[widget.project.labels.length % colors.length];
}

void _createAndAssignLabel(String name) {
  try {
    final label = widget.controller.addLabel(name, _nextLabelColor());
    widget.controller.assignSelectedBoxLabel(label.id);
    setState(() => _selectorError = null);
  } catch (_) {
    setState(() => _selectorError = WorkbenchCopy.duplicateLabel);
  }
}

void _assignLabelFromSelector(int labelId) {
  widget.controller.assignSelectedBoxLabel(labelId);
  setState(() => _selectorError = null);
}
```

- [ ] **Step 5: Insert selector above existing label buttons**

In `_InspectorPanelState.build`, immediately after:

```dart
const _SectionTitle(WorkbenchCopy.labels),
const SizedBox(height: 8),
```

insert:

```dart
if (widget.controller.selectedBoxId != null) ...[
  KeyedSubtree(
    key: const ValueKey('selected-box-label-selector'),
    child: WorkbenchLabelSelector(
      labels: widget.project.labels,
      errorText: _selectorError,
      onAssignLabel: _assignLabelFromSelector,
      onCreateLabel: _createAndAssignLabel,
    ),
  ),
  const SizedBox(height: 12),
],
```

Keep the existing label creation row and label buttons below it for now. They remain a secondary inspector workflow.

- [ ] **Step 6: Update `_createLabel` color source**

In `_createLabel`, replace the local `colors` list and color selection with:

```dart
widget.controller.addLabel(name, _nextLabelColor());
```

The method should still clear `_labelNameController` and set `_labelError` as it does today.

- [ ] **Step 7: Run workbench tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart -r expanded
```

Expected: all tests pass.

- [ ] **Step 8: Commit or record skipped commit**

Run:

```powershell
Test-Path .git
```

If it returns `True`:

```powershell
git add lib\ui\workbench_screen.dart test\ui\workbench_widget_test.dart
git commit -m "feat: wire label selector into workbench"
```

If it returns `False`, record: `Commit skipped because C:\workspace\bbox is not a git repository.`

---

### Task 4: Upgrade Inspector Box Rows With CVAT-Style Review Details

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes:
  - `BoundingBox`
  - `LabelClass? _labelFor(AnnotationProject project, int? labelId)`
  - `AppController.selectBox(String? boxId)`
  - `AppController.deleteSelectedBox()`
- Produces:
  - Denser `_BoxRow`
  - Status and color marker keys:
    - `box-status-<box.id>`
    - `box-color-<box.id>`
  - Selected-box details key:
    - `selected-box-details`

- [ ] **Step 1: Add failing tests for improved box row and selected-box details**

Add these tests to `test/ui/workbench_widget_test.dart`:

```dart
    testWidgets('box rows expose label status coordinates and area', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());

      await tester.pumpWidget(_app(controller));

      expect(find.byKey(const ValueKey('box-status-box-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('box-color-box-1')), findsOneWidget);
      expect(find.textContaining('x 10'), findsOneWidget);
      expect(find.textContaining('area 400'), findsOneWidget);
      expect(find.text(WorkbenchCopy.proposalBox), findsOneWidget);
    });

    testWidgets('selected box details show selected box coordinates', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());

      await tester.pumpWidget(_app(controller));
      await tester.tap(find.byKey(const ValueKey('box-row-box-1')));
      await tester.pump();

      expect(find.byKey(const ValueKey('selected-box-details')), findsOneWidget);
      expect(find.text(WorkbenchCopy.selectedBox), findsOneWidget);
      expect(find.textContaining('w 20'), findsWidgets);
      expect(find.textContaining('h 20'), findsWidgets);
    });
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart -r expanded
```

Expected: FAIL because the row/status/detail keys do not exist.

- [ ] **Step 3: Add box status label helper**

Near `_labelFor` in `lib/ui/workbench_screen.dart`, add:

```dart
String _boxStatusLabel(BoundingBox box) {
  if (box.status == BoxStatus.labeled && box.labelId != null) {
    return WorkbenchCopy.labeledBox;
  }
  if (box.width <= 0 || box.height <= 0) {
    return WorkbenchCopy.invalidBox;
  }
  return WorkbenchCopy.proposalBox;
}
```

- [ ] **Step 4: Replace `_BoxRow.build` with dense row UI**

Replace the `build` method inside `_BoxRow` with:

```dart
@override
Widget build(BuildContext context) {
  final label = _labelFor(project, box.labelId);
  final selected = controller.selectedBoxId == box.id;
  final color = box.status == BoxStatus.proposal
      ? Colors.grey
      : Color(label?.color ?? 0xffd32f2f);
  final statusLabel = _boxStatusLabel(box);

  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Material(
      color: selected
          ? Theme.of(context).colorScheme.primary.withAlpha(18)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        key: ValueKey('box-row-${box.id}'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => controller.selectBox(box.id),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                key: ValueKey('box-color-${box.id}'),
                width: 4,
                height: 44,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            label?.name ?? WorkbenchCopy.unlabeledBox,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        _StatusBadge(
                          key: ValueKey('box-status-${box.id}'),
                          label: statusLabel,
                          color: color,
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'x ${box.x.toStringAsFixed(0)}, '
                      'y ${box.y.toStringAsFixed(0)}, '
                      'w ${box.width.toStringAsFixed(0)}, '
                      'h ${box.height.toStringAsFixed(0)} · '
                      'area ${box.area.toStringAsFixed(0)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
```

Update `_StatusBadge` so box status badges can receive widget keys:

```dart
const _StatusBadge({super.key, required this.label, required this.color});
```

- [ ] **Step 5: Add selected-box details section**

Inside `_InspectorPanelState.build`, after the box list and before the delete selected box button, insert:

```dart
if (widget.controller.selectedBox != null) ...[
  const Divider(height: 28),
  const _SectionTitle(WorkbenchCopy.selectedBox),
  const SizedBox(height: 8),
  _SelectedBoxDetails(box: widget.controller.selectedBox!),
],
```

Then add this widget near `_BoxRow`:

```dart
class _SelectedBoxDetails extends StatelessWidget {
  const _SelectedBoxDetails({required this.box});

  final BoundingBox box;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: const ValueKey('selected-box-details'),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest
            .withAlpha(90),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Wrap(
          spacing: 10,
          runSpacing: 6,
          children: [
            Text('x ${box.x.toStringAsFixed(0)}'),
            Text('y ${box.y.toStringAsFixed(0)}'),
            Text('w ${box.width.toStringAsFixed(0)}'),
            Text('h ${box.height.toStringAsFixed(0)}'),
            Text('area ${box.area.toStringAsFixed(0)}'),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 6: Run workbench tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart -r expanded
```

Expected: all tests pass.

- [ ] **Step 7: Commit or record skipped commit**

Run:

```powershell
Test-Path .git
```

If it returns `True`:

```powershell
git add lib\ui\workbench_screen.dart test\ui\workbench_widget_test.dart
git commit -m "feat: improve workbench box review rows"
```

If it returns `False`, record: `Commit skipped because C:\workspace\bbox is not a git repository.`

---

### Task 5: Final Verification And Build

**Files:**
- Verify all modified files.

**Interfaces:**
- Consumes:
  - Clean copy from Task 1
  - `WorkbenchLabelSelector` from Task 2
  - Inspector wiring from Task 3
  - CVAT-style box rows from Task 4
- Produces:
  - Formatted, analyzed, tested, and Windows-buildable project.

- [ ] **Step 1: Format Dart code**

Run:

```powershell
& 'C:\tools\flutter\bin\cache\dart-sdk\bin\dart.exe' format .
```

Expected: formatter completes without errors.

- [ ] **Step 2: Verify no corrupted UI copy remains**

Run:

```powershell
rg -n "�|揶|獄|沃|筌|醫|誘|뺤|대\\?|꾨|쇰|諛" lib\ui test\ui
```

Expected: no matches and exit code `1`.

- [ ] **Step 3: Analyze**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' analyze
```

Expected: `No issues found!`

- [ ] **Step 4: Run focused UI tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_label_selector_test.dart test\ui\workbench_widget_test.dart -r expanded
```

Expected: all tests pass.

- [ ] **Step 5: Run domain and export tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\annotation\annotation_rules_test.dart test\export\coco_exporter_test.dart test\ui\canvas_interaction_test.dart -r expanded
```

Expected: all tests pass.

- [ ] **Step 6: Run full test suite**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test
```

Expected: all tests pass.

- [ ] **Step 7: Build Windows app**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' build windows
```

Expected: `Built build\windows\x64\runner\Release\bbox_labeler.exe`

- [ ] **Step 8: Record git status or skipped status**

Run:

```powershell
Test-Path .git
```

If it returns `True`:

```powershell
git status --short
```

Expected: only intentional files are modified, or clean if commits were made.

If it returns `False`, record: `Git status unavailable because C:\workspace\bbox is not a git repository.`

---

## Self-Review Checklist

- Spec coverage:
  - Roboflow-like fast label assignment: Tasks 2 and 3.
  - CVAT-like right inspector review: Task 4.
  - Clean Korean visible copy: Task 1.
  - Proposal/unlabeled boxes keep confirm disabled: existing tests plus Task 3 drawn-box test.
  - COCO export unchanged: Task 5 domain/export tests.
  - No cloud/account/collaboration or advanced CVAT controls: no task adds them.

- Type consistency:
  - `WorkbenchLabelSelector.labels` uses `List<LabelClass>`.
  - `onAssignLabel` receives `int labelId`.
  - `onCreateLabel` receives trimmed `String name`.
  - `AppController.addLabel` returns `LabelClass`.
  - `AppController.selectedBox` is already available as `BoundingBox?`.

- Verification:
  - Every implementation task starts with failing tests.
  - Every task ends with focused passing tests.
  - Final verification includes format, copy scan, analyze, focused UI tests,
    domain/export tests, full tests, and Windows build.
