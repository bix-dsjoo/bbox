# Labeling Workflow Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Simplify the workbench for repeated labeling by removing image filters, using action-centered Korean copy, improving automatic box visibility, and adding a fast `complete and next` workflow.

**Architecture:** Keep the existing Flutter structure. Domain data remains in `lib/annotation`, orchestration remains in `lib/ui/app_controller.dart`, and presentation stays in `lib/ui/workbench_screen.dart` plus `lib/ui/workbench_copy.dart`. Add small controller helpers for next image/box selection instead of introducing a new state-management pattern.

**Tech Stack:** Flutter desktop, Dart, `flutter_test`, existing `ChangeNotifier` controller, existing annotation model and rules.

## Global Constraints

- Do not change project JSON schema.
- Do not change COCO export structure or semantics.
- Do not change detector behavior or run automatic detection for every image.
- Original image coordinates remain the only persisted box coordinates.
- The left image list must not render status filter controls.
- User-facing terms must use action-centered Korean copy: `검토 필요`, `완료`, `문제 있음`, `라벨 필요`, `자동 박스`, `라벨 완료`, `찾는 중`.
- `COCO 내보내기` remains visible as the export action label.
- The workspace currently has no `.git` directory, so commit/checkpoint steps verify this instead of running `git commit`.

---

## File Structure

- Modify `lib/ui/workbench_copy.dart`
  - Owns all visible workbench strings affected by terminology and workflow actions.
- Modify `lib/ui/app_controller.dart`
  - Removes list filtering state.
  - Adds next-image and next-box workflow helpers.
  - Adds completion blocker messages for UI.
- Modify `lib/ui/workbench_screen.dart`
  - Removes filter chips.
  - Uses all project images in the left list.
  - Shows action-centered summaries and completion UI.
  - Updates automatic box overlay style.
- Modify `test/ui/app_controller_test.dart`
  - Covers controller workflow behavior independent of widgets.
- Modify `test/ui/workbench_widget_test.dart`
  - Covers UI removal of filters, copy changes, completion action, shortcuts, and overlay style.

---

### Task 1: Remove Image Filters And Rename User-Facing Workflow Terms

**Files:**
- Modify: `lib/ui/workbench_copy.dart`
- Modify: `lib/ui/app_controller.dart`
- Modify: `lib/ui/workbench_screen.dart`
- Test: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: existing `AnnotationProject.images`, `AnnotatedImage.boxCount`, `AnnotatedImage.unlabeledBoxCount`, `WorkbenchCopy.imageStatusLabel`.
- Produces: no image-list filter API. `WorkbenchCopy` exposes new strings used by later tasks:
  - `needsReview = '검토 필요'`
  - `confirmed = '완료'`
  - `error = '문제 있음'`
  - `unlabeled = '라벨 필요'`
  - `proposalBox = '자동 박스'`
  - `labeledBox = '라벨 완료'`
  - `detecting` status label returns `'찾는 중'`

- [ ] **Step 1: Replace the filter widget test with a no-filter/all-images test**

In `test/ui/workbench_widget_test.dart`, replace the test named `filters the image list by confirmed status` with:

```dart
    testWidgets('image list shows all images without status filters', (
      tester,
    ) async {
      final controller = AppController();
      final project = _project().copyWith(
        images: [
          _project().images.first.copyWith(status: ImageStatus.confirmed),
          _project().images.last,
        ],
      );
      controller.loadProject(project);

      await tester.pumpWidget(_app(controller));

      expect(find.byKey(const ValueKey('filter-all')), findsNothing);
      expect(find.byKey(const ValueKey('filter-needs-review')), findsNothing);
      expect(find.byKey(const ValueKey('filter-confirmed')), findsNothing);
      expect(find.byKey(const ValueKey('filter-error')), findsNothing);
      expect(find.byKey(const ValueKey('filter-unlabeled')), findsNothing);
      expect(find.byKey(const ValueKey('image-row-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('image-row-2')), findsOneWidget);
    });
```

- [ ] **Step 2: Update the image queue summary test expectations**

In `test/ui/workbench_widget_test.dart`, update `image queue summarizes review progress` assertions:

```dart
      expect(find.textContaining('이미지 3장'), findsOneWidget);
      expect(find.textContaining('작업 필요 1장'), findsOneWidget);
      expect(find.textContaining('완료 1장'), findsOneWidget);
      expect(find.textContaining('문제 1장'), findsOneWidget);
```

- [ ] **Step 3: Update box and export copy expectations**

In `test/ui/workbench_widget_test.dart`, update copy assertions:

```dart
      expect(find.text(WorkbenchCopy.proposalBox), findsOneWidget);
```

continues to be used, but `WorkbenchCopy.proposalBox` will now resolve to `자동 박스`.

In `export button shows warnings for unfinished work`, update dialog assertions:

```dart
      expect(find.text('COCO 내보내기 경고'), findsOneWidget);
      expect(find.textContaining('검토 필요 이미지: 2'), findsOneWidget);
      expect(find.textContaining('라벨 필요한 자동 박스: 1'), findsOneWidget);
      expect(find.textContaining('문제 있는 이미지: 1'), findsOneWidget);
```

- [ ] **Step 4: Run widget tests to verify they fail**

Run:

```powershell
flutter test test/ui/workbench_widget_test.dart
```

Expected: FAIL because filter widgets still exist and old Korean copy is still rendered.

- [ ] **Step 5: Update `WorkbenchCopy` strings**

In `lib/ui/workbench_copy.dart`, change these constants and status labels:

```dart
  static const needsReview = '검토 필요';
  static const confirmed = '완료';
  static const error = '문제 있음';
  static const unlabeled = '라벨 필요';
  static const unlabeledBox = '라벨 필요';
  static const proposalBox = '자동 박스';
  static const labeledBox = '라벨 완료';
  static const invalidBox = '문제 있음';
  static const confirm = '완료';
  static const confirmNoObject = '객체 없음으로 완료';
  static const confirmNoObjectAvailable = '박스가 없으면 객체 없음으로 완료할 수 있습니다.';
  static const autoBoxesTooltip = '현재 이미지에서 자동 박스 찾기';
  static const autoBoxesRunning = '자동 박스 찾는 중';
  static const autoBoxesEmpty = '자동 박스를 찾지 못했습니다';
  static const autoBoxesFailed = '자동 박스 찾기 실패. 기존 박스는 유지됩니다';
```

Change `autoBoxesCreated`:

```dart
  static String autoBoxesCreated(int count) => '자동 박스 $count개 생성됨';
```

Change `imageStatusLabel`:

```dart
  static String imageStatusLabel(ImageStatus status) {
    return switch (status) {
      ImageStatus.queued => '대기',
      ImageStatus.detecting => '찾는 중',
      ImageStatus.needsReview => '검토 필요',
      ImageStatus.confirmed => '완료',
      ImageStatus.error => '문제 있음',
    };
  }
```

- [ ] **Step 6: Remove filter state from `AppController`**

In `lib/ui/app_controller.dart`, delete:

```dart
enum ImageListFilter { all, needsReview, confirmed, error, unlabeled }
```

Delete the field:

```dart
  ImageListFilter _imageListFilter = ImageListFilter.all;
```

Delete the getter:

```dart
  ImageListFilter get imageListFilter => _imageListFilter;
```

Delete `filteredImages` and `setImageListFilter`.

Delete this assignment in `returnToProjectHome` or any reset path if present:

```dart
    _imageListFilter = ImageListFilter.all;
```

- [ ] **Step 7: Remove filter chips from the workbench**

In `lib/ui/workbench_screen.dart`, remove the `Padding` containing `_FilterChipButton` widgets from `_ImageListPanel`.

Change the header summary inside `_ImageListPanel.build` to:

```dart
            summary:
                '이미지 ${project.images.length}장 · 작업 필요 ${needsReviewCount}장 · '
                '완료 ${confirmedCount}장 · 문제 ${errorCount}장',
```

Change the `ListView.builder` to use all images:

```dart
                    itemCount: project.images.length,
                    itemBuilder: (context, index) {
                      final image = project.images[index];
                      final selected = image.id == controller.selectedImageId;
                      return _ImageQueueRow(
                        key: ValueKey('image-row-${image.id}'),
                        controller: controller,
                        project: project,
                        image: image,
                        selected: selected,
                      );
                    },
```

Delete the entire `_FilterChipButton` class.

- [ ] **Step 8: Update image row and export warning copy**

In `_ImageQueueRow`, change the box summary text to:

```dart
                            '박스 ${image.boxCount}개 · '
                            '라벨 필요 ${image.unlabeledBoxCount}개',
```

In `_showExportWarnings`, change dialog strings to:

```dart
          title: Text(hasErrors ? 'COCO 내보내기 차단' : 'COCO 내보내기 경고'),
```

and:

```dart
              Text('검토 필요 이미지: ${summary.unconfirmedImageCount}'),
              Text('라벨 필요한 자동 박스: ${summary.unlabeledProposalBoxCount}'),
              Text('문제 있는 이미지: ${summary.errorImageCount}'),
```

- [ ] **Step 9: Run focused tests**

Run:

```powershell
flutter test test/ui/workbench_widget_test.dart
```

Expected: PASS for the updated image-list, copy, and export-warning tests. Other failures in this file indicate remaining old copy expectations to update to the new `WorkbenchCopy` constants.

- [ ] **Step 10: Checkpoint**

Run:

```powershell
Test-Path .git
```

Expected: `False`. Do not run `git commit` in this workspace.

---

### Task 2: Add Controller Workflow Helpers For Complete-And-Next And Next Box Selection

**Files:**
- Modify: `lib/ui/app_controller.dart`
- Test: `test/ui/app_controller_test.dart`

**Interfaces:**
- Consumes: `AnnotationRules.canConfirm`, `AnnotationRules.confirmImage`, `AnnotationRules.assignLabel`, `AnnotatedImage.visibleBoxes`.
- Produces:
  - `String? get selectedImageCompletionBlockerReason`
  - `void completeSelectedImageAndSelectNext()`
  - `int? nextImageNeedingWorkId({int? afterImageId})`
  - `String? nextBoxNeedingLabelId(AnnotatedImage image, {String? afterBoxId})`
  - `assignSelectedBoxLabel(int labelId)` selects the next box needing a label after assignment.

- [ ] **Step 1: Add controller tests for next image selection**

Append to the `AppController` group in `test/ui/app_controller_test.dart`:

```dart
    test('completeSelectedImageAndSelectNext advances to next review image', () {
      final controller = AppController()
        ..loadProject(
          AnnotationProject.empty(name: 'demo').copyWith(
            status: ProjectStatus.ready,
            labels: const [
              LabelClass(id: 1, name: 'Person', color: 0xffe64a19),
            ],
            images: const [
              AnnotatedImage(
                id: 1,
                sourcePath: 'a.jpg',
                displayName: 'a.jpg',
                width: 100,
                height: 80,
                status: ImageStatus.needsReview,
                boxes: [
                  BoundingBox(
                    id: 'box-1',
                    x: 10,
                    y: 10,
                    width: 20,
                    height: 20,
                    status: BoxStatus.labeled,
                    labelId: 1,
                  ),
                ],
              ),
              AnnotatedImage(
                id: 2,
                sourcePath: 'b.jpg',
                displayName: 'b.jpg',
                width: 100,
                height: 80,
                status: ImageStatus.needsReview,
              ),
            ],
          ),
        );

      controller.completeSelectedImageAndSelectNext();

      expect(controller.project!.images.first.status, ImageStatus.confirmed);
      expect(controller.selectedImageId, 2);
    });

    test('completeSelectedImageAndSelectNext skips error images and wraps', () {
      final controller = AppController()
        ..loadProject(
          AnnotationProject.empty(name: 'demo').copyWith(
            status: ProjectStatus.ready,
            labels: const [
              LabelClass(id: 1, name: 'Person', color: 0xffe64a19),
            ],
            images: const [
              AnnotatedImage(
                id: 1,
                sourcePath: 'a.jpg',
                displayName: 'a.jpg',
                width: 100,
                height: 80,
                status: ImageStatus.needsReview,
              ),
              AnnotatedImage(
                id: 2,
                sourcePath: 'broken.jpg',
                displayName: 'broken.jpg',
                width: 0,
                height: 0,
                status: ImageStatus.error,
              ),
              AnnotatedImage(
                id: 3,
                sourcePath: 'c.jpg',
                displayName: 'c.jpg',
                width: 100,
                height: 80,
                status: ImageStatus.needsReview,
                boxes: [
                  BoundingBox(
                    id: 'box-3',
                    x: 10,
                    y: 10,
                    width: 20,
                    height: 20,
                    status: BoxStatus.labeled,
                    labelId: 1,
                  ),
                ],
              ),
            ],
          ),
        );

      controller.selectImage(3);
      controller.completeSelectedImageAndSelectNext();

      expect(controller.project!.images.last.status, ImageStatus.confirmed);
      expect(controller.selectedImageId, 1);
    });
```

- [ ] **Step 2: Add controller tests for next box selection after label assignment**

Append:

```dart
    test('assignSelectedBoxLabel selects the next box needing a label', () {
      final controller = AppController()
        ..loadProject(
          AnnotationProject.empty(name: 'demo').copyWith(
            status: ProjectStatus.ready,
            labels: const [
              LabelClass(id: 1, name: 'Person', color: 0xffe64a19),
            ],
            images: const [
              AnnotatedImage(
                id: 1,
                sourcePath: 'a.jpg',
                displayName: 'a.jpg',
                width: 100,
                height: 80,
                status: ImageStatus.needsReview,
                boxes: [
                  BoundingBox(
                    id: 'box-1',
                    x: 10,
                    y: 10,
                    width: 20,
                    height: 20,
                    status: BoxStatus.proposal,
                  ),
                  BoundingBox(
                    id: 'box-2',
                    x: 40,
                    y: 10,
                    width: 20,
                    height: 20,
                    status: BoxStatus.proposal,
                  ),
                ],
              ),
            ],
          ),
        );

      controller.selectBox('box-1');
      controller.assignSelectedBoxLabel(1);

      expect(controller.selectedImage!.boxes.first.status, BoxStatus.labeled);
      expect(controller.selectedBoxId, 'box-2');
    });

    test('assignSelectedBoxLabel keeps selection when all boxes are labeled', () {
      final controller = AppController()
        ..loadProject(
          AnnotationProject.empty(name: 'demo').copyWith(
            status: ProjectStatus.ready,
            labels: const [
              LabelClass(id: 1, name: 'Person', color: 0xffe64a19),
            ],
            images: const [
              AnnotatedImage(
                id: 1,
                sourcePath: 'a.jpg',
                displayName: 'a.jpg',
                width: 100,
                height: 80,
                status: ImageStatus.needsReview,
                boxes: [
                  BoundingBox(
                    id: 'box-1',
                    x: 10,
                    y: 10,
                    width: 20,
                    height: 20,
                    status: BoxStatus.proposal,
                  ),
                ],
              ),
            ],
          ),
        );

      controller.selectBox('box-1');
      controller.assignSelectedBoxLabel(1);

      expect(controller.selectedBoxId, 'box-1');
      expect(controller.canConfirmSelectedImage, isTrue);
    });
```

- [ ] **Step 3: Add controller tests for blocker reasons**

Append:

```dart
    test('selectedImageCompletionBlockerReason reports unlabeled boxes', () {
      final controller = AppController()..loadProject(_project());

      expect(
        controller.selectedImageCompletionBlockerReason,
        '라벨 필요한 박스 1개',
      );
    });

    test('selectedImageCompletionBlockerReason reports error images', () {
      final controller = AppController()..loadProject(_projectWithError());
      controller.selectImage(3);

      expect(
        controller.selectedImageCompletionBlockerReason,
        '문제 있는 이미지는 완료할 수 없습니다',
      );
    });
```

- [ ] **Step 4: Add the `_projectWithError` test helper**

Append this helper near the existing `_project()` helper in `test/ui/app_controller_test.dart`:

```dart
AnnotationProject _projectWithError() {
  return _project().copyWith(
    images: [
      ..._project().images,
      const AnnotatedImage(
        id: 3,
        sourcePath: 'broken.jpg',
        displayName: 'broken.jpg',
        width: 0,
        height: 0,
        status: ImageStatus.error,
        errorMessage: 'decode failed',
      ),
    ],
  );
}
```

- [ ] **Step 5: Run controller tests to verify they fail**

Run:

```powershell
flutter test test/ui/app_controller_test.dart
```

Expected: FAIL with missing `completeSelectedImageAndSelectNext` and `selectedImageCompletionBlockerReason`.

- [ ] **Step 6: Add completion blocker and next target helpers**

In `lib/ui/app_controller.dart`, add these public members inside `AppController`:

```dart
  String? get selectedImageCompletionBlockerReason {
    final image = selectedImage;
    if (image == null) {
      return null;
    }
    if (image.status == ImageStatus.error ||
        image.width <= 0 ||
        image.height <= 0) {
      return '문제 있는 이미지는 완료할 수 없습니다';
    }
    var invalidCount = 0;
    var unlabeledCount = 0;
    for (final box in image.visibleBoxes) {
      if (!AnnotationRules.isBoxValid(
        box,
        imageWidth: image.width,
        imageHeight: image.height,
      )) {
        invalidCount++;
      }
      if (box.status != BoxStatus.labeled || box.labelId == null) {
        unlabeledCount++;
      }
    }
    if (invalidCount > 0) {
      return '이미지 밖 박스 $invalidCount개';
    }
    if (unlabeledCount > 0) {
      return '라벨 필요한 박스 $unlabeledCount개';
    }
    return null;
  }

  int? nextImageNeedingWorkId({int? afterImageId}) {
    final project = _project;
    if (project == null || project.images.isEmpty) {
      return null;
    }
    final startIndex = afterImageId == null
        ? -1
        : project.images.indexWhere((image) => image.id == afterImageId);
    for (var index = startIndex + 1; index < project.images.length; index++) {
      final image = project.images[index];
      if (_imageNeedsWork(image)) {
        return image.id;
      }
    }
    final endIndex = startIndex < 0 ? project.images.length : startIndex;
    for (var index = 0; index < endIndex; index++) {
      final image = project.images[index];
      if (_imageNeedsWork(image)) {
        return image.id;
      }
    }
    return null;
  }

  String? nextBoxNeedingLabelId(
    AnnotatedImage image, {
    String? afterBoxId,
  }) {
    final boxes = image.visibleBoxes.toList(growable: false);
    if (boxes.isEmpty) {
      return null;
    }
    final startIndex = afterBoxId == null
        ? -1
        : boxes.indexWhere((box) => box.id == afterBoxId);
    for (var index = startIndex + 1; index < boxes.length; index++) {
      final box = boxes[index];
      if (_boxNeedsLabel(box)) {
        return box.id;
      }
    }
    final endIndex = startIndex < 0 ? boxes.length : startIndex;
    for (var index = 0; index < endIndex; index++) {
      final box = boxes[index];
      if (_boxNeedsLabel(box)) {
        return box.id;
      }
    }
    return null;
  }
```

Add private helpers near `_replaceSelectedImage`:

```dart
  bool _imageNeedsWork(AnnotatedImage image) {
    if (image.status == ImageStatus.error ||
        image.status == ImageStatus.confirmed) {
      return false;
    }
    return image.status == ImageStatus.needsReview ||
        image.visibleBoxes.any(_boxNeedsLabel);
  }

  bool _boxNeedsLabel(BoundingBox box) {
    return !box.isDeleted &&
        (box.status != BoxStatus.labeled || box.labelId == null);
  }
```

- [ ] **Step 7: Update label assignment to select the next unlabeled box**

Replace `assignSelectedBoxLabel` in `lib/ui/app_controller.dart` with:

```dart
  void assignSelectedBoxLabel(int labelId) {
    final image = selectedImage;
    final boxId = _selectedBoxId;
    if (image == null || boxId == null) {
      return;
    }
    _recordUndo();
    final updatedImage = AnnotationRules.assignLabel(
      image,
      boxId: boxId,
      labelId: labelId,
    );
    _replaceSelectedImage(updatedImage);
    _selectedBoxId = nextBoxNeedingLabelId(
          updatedImage,
          afterBoxId: boxId,
        ) ??
        boxId;
    _scheduleAutoSave();
    notifyListeners();
  }
```

- [ ] **Step 8: Add complete-and-next controller method**

Add to `AppController` near `confirmSelectedImage`:

```dart
  void completeSelectedImageAndSelectNext() {
    final image = selectedImage;
    if (image == null) {
      return;
    }
    _recordUndo();
    final confirmedImage = AnnotationRules.confirmImage(image);
    _replaceSelectedImage(confirmedImage);
    final nextImageId = nextImageNeedingWorkId(afterImageId: image.id);
    if (nextImageId != null) {
      _selectedImageId = nextImageId;
      _selectedBoxId = null;
      _imageViewLoadState = ImageViewLoadState(
        imageId: nextImageId,
        isLoading: false,
      );
    } else {
      _selectedImageId = image.id;
      _selectedBoxId = null;
      lastUserMessage = '모든 작업 가능한 이미지를 완료했습니다';
    }
    _scheduleAutoSave();
    notifyListeners();
  }
```

- [ ] **Step 9: Run controller tests**

Run:

```powershell
flutter test test/ui/app_controller_test.dart
```

Expected: PASS.

- [ ] **Step 10: Checkpoint**

Run:

```powershell
Test-Path .git
```

Expected: `False`. Do not run `git commit` in this workspace.

---

### Task 3: Add Complete-And-Next UI And Keyboard Shortcut

**Files:**
- Modify: `lib/ui/workbench_copy.dart`
- Modify: `lib/ui/workbench_screen.dart`
- Test: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: `AppController.completeSelectedImageAndSelectNext`, `AppController.selectedImageCompletionBlockerReason`, `AppController.canConfirmSelectedImage`.
- Produces: `Ctrl+Enter` triggers complete-and-next when no text input owns focus.

- [ ] **Step 1: Add widget tests for completion UI**

Append to `test/ui/workbench_widget_test.dart`:

```dart
    testWidgets('complete and next advances to the next work image', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(
        _project().copyWith(
          images: [
            _project().images.first.copyWith(
              boxes: const [
                BoundingBox(
                  id: 'box-1',
                  x: 10,
                  y: 10,
                  width: 20,
                  height: 20,
                  status: BoxStatus.labeled,
                  labelId: 1,
                ),
              ],
            ),
            _project().images.last,
          ],
        ),
      );

      await tester.pumpWidget(_app(controller));
      await _tapVisible(tester, find.byKey(const ValueKey('confirm-image')));

      expect(controller.project!.images.first.status, ImageStatus.confirmed);
      expect(controller.selectedImageId, 2);
      expect(find.text(WorkbenchCopy.confirmNoObject), findsOneWidget);
    });

    testWidgets('disabled completion action shows blocker reason', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());

      await tester.pumpWidget(_app(controller));

      expect(find.text('라벨 필요한 박스 1개'), findsOneWidget);
      final confirmButton = tester.widget<ElevatedButton>(
        find.byKey(const ValueKey('confirm-image')),
      );
      expect(confirmButton.onPressed, isNull);
    });

    testWidgets('ctrl enter completes and advances', (tester) async {
      final controller = AppController();
      controller.loadProject(
        _project().copyWith(
          images: [
            _project().images.first.copyWith(
              boxes: const [
                BoundingBox(
                  id: 'box-1',
                  x: 10,
                  y: 10,
                  width: 20,
                  height: 20,
                  status: BoxStatus.labeled,
                  labelId: 1,
                ),
              ],
            ),
            _project().images.last,
          ],
        ),
      );

      await tester.pumpWidget(_app(controller));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(controller.project!.images.first.status, ImageStatus.confirmed);
      expect(controller.selectedImageId, 2);
    });
```

- [ ] **Step 2: Run widget tests to verify they fail**

Run:

```powershell
flutter test test/ui/workbench_widget_test.dart
```

Expected: FAIL because the button still calls `confirmSelectedImage` and no blocker reason or `Ctrl+Enter` behavior is present.

- [ ] **Step 3: Add workflow copy constants**

In `lib/ui/workbench_copy.dart`, add:

```dart
  static const completeAndNext = '완료하고 다음';
  static const completeNoObjectAndNext = '객체 없음, 다음';
```

- [ ] **Step 4: Wire `Ctrl+Enter` in workbench keyboard handling**

In `WorkbenchScreen.build`, add to `CallbackShortcuts.bindings`:

```dart
                const SingleActivator(LogicalKeyboardKey.enter, control: true):
                    controller.canConfirmSelectedImage
                        ? controller.completeSelectedImageAndSelectNext
                        : _noop,
```

Add a top-level no-op helper near the bottom of `workbench_screen.dart`:

```dart
void _noop() {}
```

This keeps the callback non-null while avoiding completion when blocked.

- [ ] **Step 5: Update inspector completion button**

In `_InspectorPanelState.build`, replace the confirm button block with:

```dart
              ElevatedButton.icon(
                key: const ValueKey('confirm-image'),
                onPressed: widget.controller.canConfirmSelectedImage
                    ? widget.controller.completeSelectedImageAndSelectNext
                    : null,
                icon: const Icon(Icons.check_circle_outline),
                label: Text(
                  image.boxCount == 0
                      ? WorkbenchCopy.completeNoObjectAndNext
                      : WorkbenchCopy.completeAndNext,
                ),
              ),
              if (!widget.controller.canConfirmSelectedImage &&
                  widget.controller.selectedImageCompletionBlockerReason !=
                      null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    widget.controller.selectedImageCompletionBlockerReason!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
```

Keep the existing no-object helper text below the remove-image button and update it to the new `WorkbenchCopy.confirmNoObjectAvailable` wording from Task 1.

- [ ] **Step 6: Run widget tests**

Run:

```powershell
flutter test test/ui/workbench_widget_test.dart
```

Expected: PASS for completion UI and shortcut tests. If existing tests still expect `confirmSelectedImage` to keep the same image selected, update those tests to assert advancement or call `controller.confirmSelectedImage()` directly in controller tests.

- [ ] **Step 7: Checkpoint**

Run:

```powershell
Test-Path .git
```

Expected: `False`. Do not run `git commit` in this workspace.

---

### Task 4: Improve Automatic Box Overlay Contrast

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Test: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: `BoxStatus.proposal`, existing `_BoxOverlay` rendering.
- Produces: automatic boxes use a darker gray main stroke, a white outer contrast layer, and low-opacity fill. Labeled boxes keep label colors.

- [ ] **Step 1: Update overlay style tests**

In `test/ui/workbench_widget_test.dart`, replace `selected proposal box keeps gray semantic color` with:

```dart
    testWidgets('selected automatic box keeps high contrast gray styling', (
      tester,
    ) async {
      final controller = AppController()..loadProject(_project());
      controller.selectBox('box-1');

      await tester.pumpWidget(_app(controller));

      final box = tester.widget<Container>(
        find.byKey(const ValueKey('selected-box-box-1')),
      );
      final decoration = box.decoration! as BoxDecoration;
      expect(decoration.border!.top.color, const Color(0xff5f6772));
      expect(decoration.color, const Color(0xff5f6772).withAlpha(46));
      expect(
        find.byKey(const ValueKey('box-contrast-box-1')),
        findsOneWidget,
      );
    });
```

Add another test:

```dart
    testWidgets('labeled box still uses label color instead of automatic gray', (
      tester,
    ) async {
      final controller = AppController()
        ..loadProject(
          _project().copyWith(
            images: [
              _project().images.first.copyWith(
                boxes: const [
                  BoundingBox(
                    id: 'box-1',
                    x: 10,
                    y: 10,
                    width: 20,
                    height: 20,
                    status: BoxStatus.labeled,
                    labelId: 1,
                  ),
                ],
              ),
              _project().images.last,
            ],
          ),
        );

      await tester.pumpWidget(_app(controller));

      final box = tester.widget<Container>(
        find.byKey(const ValueKey('box-box-1')),
      );
      final decoration = box.decoration! as BoxDecoration;
      expect(decoration.border!.top.color, const Color(0xffe64a19));
    });
```

- [ ] **Step 2: Run widget tests to verify overlay tests fail**

Run:

```powershell
flutter test test/ui/workbench_widget_test.dart
```

Expected: FAIL because proposal boxes still use `Colors.grey` and no contrast layer exists.

- [ ] **Step 3: Add overlay style constants**

Near the top of `lib/ui/workbench_screen.dart`, add:

```dart
const _automaticBoxColor = Color(0xff5f6772);
const _automaticBoxFillAlpha = 46;
const _automaticBoxSelectedFillAlpha = 58;
const _boxContrastColor = Colors.white;
```

- [ ] **Step 4: Update `_BoxOverlay` color calculation and visual stack**

In `_BoxOverlay.build`, replace:

```dart
    final color = box.status == BoxStatus.proposal
        ? Colors.grey
        : Color(label?.color ?? 0xffd32f2f);
```

with:

```dart
    final color = box.status == BoxStatus.proposal
        ? _automaticBoxColor
        : Color(label?.color ?? 0xffd32f2f);
    final fillAlpha = box.status == BoxStatus.proposal
        ? (selected ? _automaticBoxSelectedFillAlpha : _automaticBoxFillAlpha)
        : (selected ? 52 : 32);
```

Inside the positioned `Stack`, immediately before the `GestureDetector` that contains the keyed visual container, insert:

```dart
            child: IgnorePointer(
              child: Container(
                key: ValueKey('box-contrast-${box.id}'),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _boxContrastColor.withAlpha(210),
                    width: boxStrokeWidth + (1.5 / safeZoom),
                  ),
                ),
              ),
            ),
```

This must be wrapped in its own `Positioned` matching the same `left`, `top`, `width`, and `height` as the box body:

```dart
          Positioned(
            left: overlayMargin,
            top: overlayMargin,
            width: boxScreenWidth,
            height: boxScreenHeight,
            child: IgnorePointer(
              child: Container(
                key: ValueKey('box-contrast-${box.id}'),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _boxContrastColor.withAlpha(210),
                    width: boxStrokeWidth + (1.5 / safeZoom),
                  ),
                ),
              ),
            ),
          ),
```

Then change the visual container fill:

```dart
                      color: color.withAlpha(fillAlpha),
```

- [ ] **Step 5: Update `_BoxRow` proposal color**

In `_BoxRow.build`, replace proposal `Colors.grey` with `_automaticBoxColor`:

```dart
    final color = box.status == BoxStatus.proposal
        ? _automaticBoxColor
        : Color(label?.color ?? 0xffd32f2f);
```

- [ ] **Step 6: Run widget tests**

Run:

```powershell
flutter test test/ui/workbench_widget_test.dart
```

Expected: PASS for overlay style tests.

- [ ] **Step 7: Checkpoint**

Run:

```powershell
Test-Path .git
```

Expected: `False`. Do not run `git commit` in this workspace.

---

### Task 5: Full Verification

**Files:**
- Verify: all modified Dart files and tests.

**Interfaces:**
- Consumes: all previous task outputs.
- Produces: verified implementation ready for user review.

- [ ] **Step 1: Run analyzer**

Run:

```powershell
flutter analyze
```

Expected: exits with code 0 and reports no issues.

- [ ] **Step 2: Run all tests**

Run:

```powershell
flutter test
```

Expected: exits with code 0 and all tests pass.

- [ ] **Step 3: Build Windows app**

Run:

```powershell
flutter build windows
```

Expected: exits with code 0 and writes the release build under `build\windows\x64\runner\Release`.

- [ ] **Step 4: Manual smoke checklist**

Run the app:

```powershell
flutter run -d windows
```

Verify:

```text
1. Left image list has no filter chips.
2. Image list header says "이미지 N장 · 작업 필요 N장 · 완료 N장 · 문제 N장".
3. Selecting a box and pressing a label shortcut labels it and advances to the next label-needed box.
4. A disabled completion button shows one short blocker reason.
5. Completing a valid image advances to the next work image.
6. Automatic boxes are easier to see when overlapping.
7. COCO export warning uses the new action-centered terms.
```

- [ ] **Step 5: Final checkpoint**

Run:

```powershell
Test-Path .git
```

Expected: `False`. Do not run `git commit` in this workspace.

---

## Self-Review Notes

- Spec coverage: Task 1 covers filter removal and vocabulary; Task 2 covers next-box and next-image workflow; Task 3 covers UI and shortcut; Task 4 covers automatic box contrast; Task 5 covers verification.
- No project schema, COCO export structure, detector behavior, or persisted coordinate model changes are planned.
- `ImageListFilter` is removed rather than hidden so there is no unused filtering concept left behind.
- The current workspace has no `.git`, so checkpoint steps explicitly avoid commit commands.
