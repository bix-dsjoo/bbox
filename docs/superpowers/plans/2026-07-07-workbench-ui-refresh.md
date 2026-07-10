# Workbench UI Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh the Flutter workbench so the empty project, top bar, image queue, canvas, and inspector feel like a polished desktop labeling tool instead of a prototype.

**Architecture:** Keep the existing `WorkbenchScreen` and `AppController` behavior, but extract stable UI copy and small workbench-only presentation helpers. Reuse the existing folder selection, save-before-home, image selection, label, confirmation, reconnect, and COCO export flows without changing domain models.

**Tech Stack:** Flutter desktop, Dart, Material 3, existing `ChangeNotifier` controller, existing widget tests, `C:\tools\flutter\bin\flutter.bat`, and `C:\tools\flutter\bin\cache\dart-sdk\bin\dart.exe` for formatting.

## Global Constraints

- Do not redesign the project home in this pass.
- Do not change annotation data models.
- Do not change COCO export behavior.
- Do not add account, cloud, or collaboration features.
- Do not add a permanent project switcher sidebar.
- Do not introduce a new design dependency unless already available in the project.
- The image folder action must be available from both top bar and empty center state when the project has no images.
- The same image folder selection logic must be reused for all image folder entry points.
- Returning to project home must keep the save-before-navigation behavior.
- Save status must remain visible.
- Export must remain available even when images are unconfirmed.
- Existing keyboard shortcuts must keep working.
- The UI must not add modals for normal repetitive work.
- Visible UI copy must use clean Korean text where the current app has corrupted Korean strings.
- Use non-ASCII Korean text only for user-facing copy in this UI cleanup.
- Git commit steps are included. In this workspace, `Test-Path .git` is currently `False` and `git` is not on `PATH`; if that is still true during execution, skip the commit step and report it.

---

## File Structure

- Create `lib/ui/workbench_copy.dart`
  - Owns visible workbench Korean copy and a small status label formatter.
  - Prevents new corrupted string literals from spreading through widgets.

- Modify `lib/ui/workbench_screen.dart`
  - Apply the refreshed workbench shell, top bar, image queue, center canvas empty states, and right inspector.
  - Keep all existing interaction methods and controller calls.
  - Add private presentation helpers in this same file only when they are local to the workbench.

- Modify `test/ui/workbench_widget_test.dart`
  - Add new UI behavior tests.
  - Update existing tests that assert corrupted Korean copy.

- Modify `test/widget_test.dart`
  - Update top bar expectations where labels change from English to Korean.

---

### Task 1: Stable Korean Copy And Empty-Project CTAs

**Files:**
- Create: `lib/ui/workbench_copy.dart`
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `test/ui/workbench_widget_test.dart`
- Modify: `test/widget_test.dart`

**Interfaces:**
- Produces:
  - `class WorkbenchCopy`
  - `static String imageStatusLabel(ImageStatus status)`
  - Center CTA key `empty-workbench-choose-folder`
  - Left CTA key `image-list-empty-choose-folder`
- Consumes:
  - Existing `ImageStatus`
  - Existing `WorkbenchScreen.chooseImageFolderPath`
  - Existing `WorkbenchScreen._chooseImageFolder(BuildContext context)`

- [ ] **Step 1: Write failing tests for the new empty workbench CTAs**

Add this test inside `group('WorkbenchScreen', () { ... })` in `test/ui/workbench_widget_test.dart`:

```dart
    testWidgets('empty project shows image folder as the primary next action', (
      tester,
    ) async {
      final tempDir = Directory.systemTemp.createTempSync(
        'bbox_empty_project_import',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final controller = AppController();
      controller.createProject('demo');

      await tester.pumpWidget(
        _app(
          controller,
          chooseImageFolderPath: (context, currentPath) async => tempDir.path,
        ),
      );

      expect(find.text('이미지 폴더를 선택하면 라벨링을 시작할 수 있어요.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('empty-workbench-choose-folder')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('image-list-empty-choose-folder')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('empty-workbench-choose-folder')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(controller.project!.imageFolderPath, tempDir.path);
    });
```

Update the existing `imports images from the image folder path prompt` test in `test/ui/workbench_widget_test.dart` by replacing:

```dart
      expect(find.text('?대?吏 0'), findsOneWidget);
```

with:

```dart
      expect(find.text('이미지'), findsOneWidget);
      expect(find.text('0개'), findsOneWidget);
```

Update `test/widget_test.dart` in the first widget test by replacing:

```dart
    expect(find.byKey(const ValueKey('choose-image-folder')), findsOneWidget);
```

with:

```dart
    expect(find.byKey(const ValueKey('choose-image-folder')), findsOneWidget);
    expect(find.text('이미지 폴더'), findsOneWidget);
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart test\widget_test.dart -r expanded
```

Expected: FAIL because `empty-workbench-choose-folder`, `image-list-empty-choose-folder`, and clean Korean copy are not implemented.

- [ ] **Step 3: Create `WorkbenchCopy`**

Create `lib/ui/workbench_copy.dart`:

```dart
import '../annotation/models.dart';

class WorkbenchCopy {
  const WorkbenchCopy._();

  static const projectHome = '프로젝트 홈';
  static const projectHomeTooltip = '저장하고 프로젝트 홈으로 돌아가기';
  static const saveProjectTooltip = '프로젝트 저장';
  static const imageFolder = '이미지 폴더';
  static const chooseImageFolder = '이미지 폴더 선택';
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
  static const noImagesYet = '아직 이미지가 없어요';
  static const chooseFolderToStart = '이미지 폴더를 선택하면 라벨링을 시작할 수 있어요.';
  static const originalImagesUnchanged = '원본 이미지는 수정되지 않아요.';
  static const selectImageFromQueue = '왼쪽 목록에서 이미지를 선택하세요.';
  static const noImageSelected = '선택한 이미지가 없어요';
  static const selectImageForInspector = '이미지를 선택하면 박스와 라벨을 확인할 수 있어요.';
  static const selectedImage = '선택 이미지';
  static const labels = '라벨';
  static const boxes = '박스';
  static const newLabel = '새 라벨';
  static const createLabelTooltip = '라벨 생성';
  static const duplicateLabel = '이미 있는 라벨명입니다.';
  static const enterLabelName = '라벨명을 입력하세요.';
  static const noBoxes = '박스 없음';
  static const unlabeledBox = '미라벨';
  static const confirm = '확정';
  static const confirmNoObject = '객체 없음으로 확정';
  static const confirmNoObjectAvailable = '객체 없음으로 확정할 수 있어요';
  static const deleteSelectedBox = '선택 박스 삭제';
  static const reconnect = '다시 연결';
  static const imageFolderNotFound = '이미지 폴더를 찾을 수 없어요.';
  static const replaceImagesTitle = '이미지 목록 다시 불러오기';
  static const replaceImagesMessage = '기존 이미지 목록을 새 폴더의 이미지로 바꿀까요?';
  static const cancel = '취소';
  static const importImages = '불러오기';
  static const close = '닫기';
  static const continueAction = '계속';

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

- [ ] **Step 4: Import and use copy constants in top-level workbench actions**

In `lib/ui/workbench_screen.dart`, add:

```dart
import 'workbench_copy.dart';
```

Replace the current project-home button copy:

```dart
                message: 'Save and return to project home',
...
                  label: const Text('Project home'),
```

with:

```dart
                message: WorkbenchCopy.projectHomeTooltip,
...
                  label: const Text(WorkbenchCopy.projectHome),
```

Replace the top image folder label:

```dart
                label: const Text('?대?吏 ?대뜑 ?좏깮'),
```

with:

```dart
                label: const Text(WorkbenchCopy.imageFolder),
```

Replace the save tooltip:

```dart
                tooltip: 'Save project',
```

with:

```dart
                tooltip: WorkbenchCopy.saveProjectTooltip,
```

Replace the export label:

```dart
                label: const Text('COCO Export'),
```

with:

```dart
                label: const Text(WorkbenchCopy.cocoExport),
```

- [ ] **Step 5: Update save status copy**

In `_SaveStatusIndicator`, replace:

```dart
        'Saved',
...
        'Saving...',
...
        'Save failed',
```

with:

```dart
        WorkbenchCopy.saved,
...
        WorkbenchCopy.saving,
...
        WorkbenchCopy.saveFailed,
```

- [ ] **Step 6: Add reusable empty-action widget**

In `lib/ui/workbench_screen.dart`, below `_MissingImageFolderBanner`, add:

```dart
class _EmptyActionState extends StatelessWidget {
  const _EmptyActionState({
    required this.icon,
    required this.title,
    required this.message,
    this.secondaryMessage,
    this.actionKey,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? secondaryMessage;
  final Key? actionKey;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (secondaryMessage != null) ...[
              const SizedBox(height: 4),
              Text(
                secondaryMessage!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (onAction != null && actionLabel != null) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                key: actionKey,
                onPressed: onAction,
                icon: const Icon(Icons.folder_open_outlined),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 7: Wire empty CTAs into image list and center viewer**

First change `_ImageListPanel` to accept the existing folder-selection callback:

```dart
class _ImageListPanel extends StatelessWidget {
  const _ImageListPanel({
    required this.controller,
    required this.project,
    required this.onChooseImageFolder,
  });

  final AppController controller;
  final AnnotationProject project;
  final VoidCallback onChooseImageFolder;
```

Update the caller in the main row:

```dart
                          child: _ImageListPanel(
                            controller: controller,
                            project: project,
                            onChooseImageFolder: () => _chooseImageFolder(context),
                          ),
```

In `_ImageListPanel.build`, replace only the `Expanded(child: ListView.builder(...))` block with:

```dart
        Expanded(
          child: project.images.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: _EmptyActionState(
                    icon: Icons.photo_library_outlined,
                    title: WorkbenchCopy.noImagesYet,
                    message: WorkbenchCopy.chooseFolderToStart,
                    actionKey: const ValueKey('image-list-empty-choose-folder'),
                    actionLabel: WorkbenchCopy.chooseImageFolder,
                    onAction: onChooseImageFolder,
                  ),
                )
              : ListView.builder(
                  itemCount: controller.filteredImages.length,
                  itemBuilder: (context, index) {
                    final image = controller.filteredImages[index];
                    final selected = image.id == controller.selectedImageId;
                    return ListTile(
                      key: ValueKey('image-row-${image.id}'),
                      selected: selected,
                      leading: _Thumbnail(project: project, image: image),
                      title: Text(
                        image.relativePath,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${WorkbenchCopy.imageStatusLabel(image.status)} · '
                        '${image.boxCount} boxes · '
                        '${image.unlabeledBoxCount} unlabeled',
                      ),
                      onTap: () => controller.selectImage(image.id),
                    );
                  },
                ),
        ),
```

In `_ViewerPanel`, add a required callback:

```dart
  const _ViewerPanel({
    required this.controller,
    required this.project,
    required this.onChooseImageFolder,
  });

  final AppController controller;
  final AnnotationProject project;
  final VoidCallback onChooseImageFolder;
```

Update the caller:

```dart
                          child: _ViewerPanel(
                            controller: controller,
                            project: project,
                            onChooseImageFolder: () => _chooseImageFolder(context),
                          ),
```

In `_ViewerPanelState.build`, replace:

```dart
    if (image == null) {
      return const Center(child: Text('?대?吏瑜??좏깮?섏꽭??'));
    }
```

with:

```dart
    if (image == null) {
      if (widget.project.images.isEmpty) {
        return _EmptyActionState(
          icon: Icons.folder_open_outlined,
          title: '이미지 폴더를 선택하세요',
          message: WorkbenchCopy.chooseFolderToStart,
          secondaryMessage: WorkbenchCopy.originalImagesUnchanged,
          actionKey: const ValueKey('empty-workbench-choose-folder'),
          actionLabel: WorkbenchCopy.chooseImageFolder,
          onAction: widget.onChooseImageFolder,
        );
      }
      return const _EmptyActionState(
        icon: Icons.image_search_outlined,
        title: WorkbenchCopy.noImageSelected,
        message: WorkbenchCopy.selectImageFromQueue,
      );
    }
```

- [ ] **Step 8: Run tests and fix compile errors from callback wiring**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart test\widget_test.dart -r expanded
```

Expected: PASS for tests touched in this task after fixing any missing constructor arguments in test helpers.

- [ ] **Step 9: Commit or record skipped commit**

Run:

```powershell
Test-Path .git
Get-Command git -ErrorAction SilentlyContinue
```

If both git checks pass:

```powershell
git add lib\ui\workbench_copy.dart lib\ui\workbench_screen.dart test\ui\workbench_widget_test.dart test\widget_test.dart
git commit -m "feat: add polished workbench empty states"
```

If either git check fails, record: `Commit skipped because this workspace has no .git directory or git executable.`

---

### Task 2: Top Bar And App Shell Polish

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `test/widget_test.dart`
- Modify: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes:
  - `WorkbenchCopy`
  - Existing `project-home-action`
  - Existing `choose-image-folder`
  - Existing `save-status-*`
  - Existing `export-coco`
- Produces:
  - App shell key `workbench-shell`
  - Top bar key `workbench-top-bar`

- [ ] **Step 1: Add failing tests for top bar hierarchy**

Add this test in `test/ui/workbench_widget_test.dart`:

```dart
    testWidgets('top bar presents project context and global actions', (
      tester,
    ) async {
      final controller = AppController();
      controller.createProject('Very Long Project Name For Layout Testing');

      await tester.pumpWidget(_app(controller));

      expect(find.byKey(const ValueKey('workbench-shell')), findsOneWidget);
      expect(find.byKey(const ValueKey('workbench-top-bar')), findsOneWidget);
      expect(find.text('프로젝트 홈'), findsOneWidget);
      expect(find.text('이미지 폴더'), findsOneWidget);
      expect(find.text('COCO 내보내기'), findsOneWidget);
      expect(find.byKey(const ValueKey('save-status-saved')), findsOneWidget);
    });
```

Update `test/widget_test.dart` by replacing:

```dart
    expect(find.textContaining('Project home was not opened'), findsOneWidget);
```

with:

```dart
    expect(find.textContaining('프로젝트 홈으로 이동하지 않았어요'), findsOneWidget);
```

- [ ] **Step 2: Run focused tests and verify they fail**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart test\widget_test.dart -r expanded
```

Expected: FAIL because `workbench-shell`, `workbench-top-bar`, and the new failure copy are not implemented.

- [ ] **Step 3: Add workbench colors and shell background**

In `lib/ui/workbench_screen.dart`, add these constants below the typedef:

```dart
const _workbenchBackground = Color(0xfff4f6f8);
const _workbenchPanel = Colors.white;
const _workbenchBorder = Color(0xffd9e1e7);
```

Wrap the `Scaffold` body content by changing:

```dart
          body: CallbackShortcuts(
```

to:

```dart
          backgroundColor: _workbenchBackground,
          body: DecoratedBox(
            key: const ValueKey('workbench-shell'),
            decoration: const BoxDecoration(color: _workbenchBackground),
            child: CallbackShortcuts(
```

Close the extra `DecoratedBox` after the existing `CallbackShortcuts` closing parenthesis.

- [ ] **Step 4: Polish AppBar visual hierarchy**

In `AppBar`, add:

```dart
            key: const ValueKey('workbench-top-bar'),
            backgroundColor: _workbenchPanel,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            shape: const Border(
              bottom: BorderSide(color: _workbenchBorder),
            ),
            toolbarHeight: 60,
```

Replace `_returnToProjectHome` error copy with:

```dart
        '현재 변경 사항을 저장하지 못해 프로젝트 홈으로 이동하지 않았어요. $error',
```

Replace `_saveProject` error copy with:

```dart
      _showError(context, '현재 변경 사항을 저장하지 못했어요. $error');
```

- [ ] **Step 5: Keep top bar labels compact and action-oriented**

In the top bar actions, keep:

```dart
label: const Text(WorkbenchCopy.imageFolder)
label: const Text(WorkbenchCopy.cocoExport)
```

Set undo/redo tooltip labels:

```dart
                tooltip: '실행 취소',
...
                tooltip: '다시 실행',
```

- [ ] **Step 6: Run focused tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart test\widget_test.dart -r expanded
```

Expected: PASS for the top bar and existing workbench tests.

- [ ] **Step 7: Commit or record skipped commit**

Run:

```powershell
Test-Path .git
Get-Command git -ErrorAction SilentlyContinue
```

If both git checks pass:

```powershell
git add lib\ui\workbench_screen.dart test\ui\workbench_widget_test.dart test\widget_test.dart
git commit -m "feat: polish workbench top bar"
```

If either git check fails, record: `Commit skipped because this workspace has no .git directory or git executable.`

---

### Task 3: Image Queue Panel Polish

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes:
  - `WorkbenchCopy`
  - Existing `ImageListFilter`
  - Existing `_Thumbnail`
  - Existing `controller.filteredImages`
- Produces:
  - Image panel key `image-queue-panel`
  - Summary text `0개`
  - Status badge helper `_StatusBadge`

- [ ] **Step 1: Add failing image queue tests**

Add this test in `test/ui/workbench_widget_test.dart`:

```dart
    testWidgets('image queue uses polished summary filters and row metadata', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());

      await tester.pumpWidget(_app(controller));

      expect(find.byKey(const ValueKey('image-queue-panel')), findsOneWidget);
      expect(find.text('이미지'), findsWidgets);
      expect(find.textContaining('2개'), findsOneWidget);
      expect(find.text('전체'), findsOneWidget);
      expect(find.text('미확정'), findsWidgets);
      expect(find.text('확정'), findsOneWidget);
      expect(find.text('오류'), findsOneWidget);
      expect(find.text('미라벨'), findsOneWidget);
      expect(find.textContaining('1 boxes'), findsOneWidget);
      expect(find.textContaining('1 unlabeled'), findsOneWidget);
    });
```

Update the existing `filters the image list by confirmed status` test only if it depends on old chip text. Keep tapping `filter-confirmed` by key.

- [ ] **Step 2: Run image queue tests and verify they fail**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart -r expanded
```

Expected: FAIL because `image-queue-panel`, clean filter labels, and row metadata are not implemented.

- [ ] **Step 3: Add panel surface helper**

In `lib/ui/workbench_screen.dart`, add below `_EmptyActionState`:

```dart
class _PanelSurface extends StatelessWidget {
  const _PanelSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: _workbenchPanel,
        border: Border(
          right: BorderSide(color: _workbenchBorder),
        ),
      ),
      child: child,
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.title, required this.summary});

  final String title;
  final String summary;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            summary,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Add status badge helper**

Add below `_PanelHeader`:

```dart
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(22),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withAlpha(70)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
```

Add helper functions near `_labelFor`:

```dart
Color _imageStatusColor(BuildContext context, ImageStatus status) {
  return switch (status) {
    ImageStatus.queued => Theme.of(context).colorScheme.onSurfaceVariant,
    ImageStatus.detecting => Theme.of(context).colorScheme.primary,
    ImageStatus.needsReview => const Color(0xffb26a00),
    ImageStatus.confirmed => const Color(0xff1b7f3a),
    ImageStatus.error => Theme.of(context).colorScheme.error,
  };
}
```

- [ ] **Step 5: Replace `_ImageListPanel` layout**

Replace `_ImageListPanel.build` with:

```dart
  @override
  Widget build(BuildContext context) {
    final confirmedCount = project.images
        .where((image) => image.status == ImageStatus.confirmed)
        .length;
    final errorCount = project.images
        .where((image) => image.status == ImageStatus.error)
        .length;
    final needsReviewCount = project.images
        .where((image) => image.status == ImageStatus.needsReview)
        .length;
    return _PanelSurface(
      child: Column(
        key: const ValueKey('image-queue-panel'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PanelHeader(
            title: WorkbenchCopy.images,
            summary:
                '${project.images.length}개 · 미확정 $needsReviewCount · 확정 $confirmedCount · 오류 $errorCount',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _FilterChipButton(
                  key: const ValueKey('filter-all'),
                  controller: controller,
                  filter: ImageListFilter.all,
                  label: WorkbenchCopy.all,
                ),
                _FilterChipButton(
                  key: const ValueKey('filter-needs-review'),
                  controller: controller,
                  filter: ImageListFilter.needsReview,
                  label: WorkbenchCopy.needsReview,
                ),
                _FilterChipButton(
                  key: const ValueKey('filter-confirmed'),
                  controller: controller,
                  filter: ImageListFilter.confirmed,
                  label: WorkbenchCopy.confirmed,
                ),
                _FilterChipButton(
                  key: const ValueKey('filter-error'),
                  controller: controller,
                  filter: ImageListFilter.error,
                  label: WorkbenchCopy.error,
                ),
                _FilterChipButton(
                  key: const ValueKey('filter-unlabeled'),
                  controller: controller,
                  filter: ImageListFilter.unlabeled,
                  label: WorkbenchCopy.unlabeled,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: project.images.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: _EmptyActionState(
                      icon: Icons.photo_library_outlined,
                      title: WorkbenchCopy.noImagesYet,
                      message: WorkbenchCopy.chooseFolderToStart,
                      actionKey:
                          const ValueKey('image-list-empty-choose-folder'),
                      actionLabel: WorkbenchCopy.chooseImageFolder,
                      onAction: onChooseImageFolder,
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                    itemCount: controller.filteredImages.length,
                    itemBuilder: (context, index) {
                      final image = controller.filteredImages[index];
                      final selected = image.id == controller.selectedImageId;
                      return _ImageQueueRow(
                        key: ValueKey('image-row-${image.id}'),
                        controller: controller,
                        project: project,
                        image: image,
                        selected: selected,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
```

- [ ] **Step 6: Add `_ImageQueueRow`**

Add below `_Thumbnail`:

```dart
class _ImageQueueRow extends StatelessWidget {
  const _ImageQueueRow({
    super.key,
    required this.controller,
    required this.project,
    required this.image,
    required this.selected,
  });

  final AppController controller;
  final AnnotationProject project;
  final AnnotatedImage image;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? Theme.of(context).colorScheme.primary.withAlpha(18)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => controller.selectImage(image.id),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                _Thumbnail(project: project, image: image),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        image.relativePath,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _StatusBadge(
                            label: WorkbenchCopy.imageStatusLabel(image.status),
                            color: _imageStatusColor(context, image.status),
                          ),
                          Text(
                            '${image.boxCount} boxes · ${image.unlabeledBoxCount} unlabeled',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
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
}
```

- [ ] **Step 7: Run image queue tests**

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
git commit -m "feat: polish image queue panel"
```

If either git check fails, record: `Commit skipped because this workspace has no .git directory or git executable.`

---

### Task 4: Canvas And Inspector Polish

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes:
  - `WorkbenchCopy`
  - `_PanelHeader`
  - `_StatusBadge`
  - Existing inspector keys `confirm-image`, `new-label-name`, `create-label`, `assign-label-*`, `box-row-*`, `delete-selected-box`
- Produces:
  - Inspector panel key `inspector-panel`
  - Canvas panel key `annotation-canvas-panel`
  - Clean Korean copy for confirmation, labels, boxes, replacement dialog, and empty inspector state

- [ ] **Step 1: Update tests for clean inspector and canvas copy**

In `test/ui/workbench_widget_test.dart`, replace in `selecting an image updates the box list`:

```dart
      expect(find.text('媛앹껜 ?놁쓬?쇰줈 ?뺤젙 媛??), findsOneWidget);
```

with:

```dart
      expect(find.text(WorkbenchCopy.confirmNoObjectAvailable), findsOneWidget);
```

Add this import:

```dart
import 'package:bbox_labeler/ui/workbench_copy.dart';
```

In `asks before replacing an existing image list`, replace:

```dart
      expect(find.text('湲곗〈 ?대?吏 紐⑸줉???덈줈 遺덈윭?듬땲??'), findsOneWidget);
```

with:

```dart
      expect(find.text(WorkbenchCopy.replaceImagesMessage), findsOneWidget);
```

Add this test:

```dart
    testWidgets('inspector and canvas use polished empty states', (
      tester,
    ) async {
      final controller = AppController();
      controller.createProject('demo');

      await tester.pumpWidget(_app(controller));

      expect(
        find.byKey(const ValueKey('annotation-canvas-panel')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('inspector-panel')), findsOneWidget);
      expect(find.text(WorkbenchCopy.noImageSelected), findsOneWidget);
      expect(find.text(WorkbenchCopy.selectImageForInspector), findsOneWidget);
    });
```

- [ ] **Step 2: Run workbench tests and verify they fail**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart -r expanded
```

Expected: FAIL because the inspector/canvas panel keys and clean copy are not implemented.

- [ ] **Step 3: Polish replacement dialog and folder error copy**

In `_chooseImageFolder` catch block, replace the corrupted error:

```dart
      _showError(context, '?대?吏 ?대뜑瑜?遺덈윭?ㅼ? 紐삵뻽?듬땲?? $error');
```

with:

```dart
      _showError(context, '이미지 폴더를 불러오지 못했어요. $error');
```

In `_confirmReplaceImages`, replace title/content/action copy with:

```dart
          title: const Text(WorkbenchCopy.replaceImagesTitle),
          content: const Text(WorkbenchCopy.replaceImagesMessage),
...
              child: const Text(WorkbenchCopy.cancel),
...
              child: const Text(WorkbenchCopy.importImages),
```

In `_showImageFolderPathDialog`, replace picker title with:

```dart
browseFolder: () => WindowsDialogService.pickFolder(
  title: WorkbenchCopy.chooseImageFolder,
),
```

In `_showExportWarnings`, replace the close/continue action text:

```dart
              child: const Text(WorkbenchCopy.close),
...
              child: const Text(WorkbenchCopy.continueAction),
```

- [ ] **Step 4: Add canvas panel surface**

In `_ViewerPanelState.build`, wrap the existing returned content with a keyed container.

Replace the no-image return from Task 1:

```dart
        return _EmptyActionState(
```

with:

```dart
        return DecoratedBox(
          key: const ValueKey('annotation-canvas-panel'),
          decoration: const BoxDecoration(color: _workbenchBackground),
          child: _EmptyActionState(
```

Close the `DecoratedBox` after `_EmptyActionState`.

For the selected-image layout, replace:

```dart
        return Column(
```

with:

```dart
        return DecoratedBox(
          key: const ValueKey('annotation-canvas-panel'),
          decoration: const BoxDecoration(color: _workbenchBackground),
          child: Column(
```

Close the `DecoratedBox` after the `Column`.

Change the canvas container color from:

```dart
                color: const Color(0xfff5f7fa),
```

to:

```dart
                color: _workbenchBackground,
```

- [ ] **Step 5: Polish inspector panel empty state and sections**

Replace the start of `_InspectorPanelState.build` return:

```dart
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('?좏깮 ?대?吏', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (image == null)
          const Text('?대?吏瑜??좏깮?섏꽭??')
        else ...[
```

with:

```dart
    return DecoratedBox(
      key: const ValueKey('inspector-panel'),
      decoration: const BoxDecoration(
        color: _workbenchPanel,
        border: Border(left: BorderSide(color: _workbenchBorder)),
      ),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionTitle(WorkbenchCopy.selectedImage),
          const SizedBox(height: 10),
          if (image == null)
            const _EmptyActionState(
              icon: Icons.fact_check_outlined,
              title: WorkbenchCopy.noImageSelected,
              message: WorkbenchCopy.selectImageForInspector,
            )
          else ...[
```

Close the extra `ListView` and `DecoratedBox` at the end of the method.

Add `_SectionTitle` below `_PanelHeader`:

```dart
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w800,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }
}
```

- [ ] **Step 6: Replace corrupted inspector copy**

In the inspector selected-image section, replace:

```dart
            label: Text(image.boxCount == 0 ? '媛앹껜 ?놁쓬?쇰줈 ?뺤젙' : '?뺤젙'),
...
              child: Text('媛앹껜 ?놁쓬?쇰줈 ?뺤젙 媛??),
...
          Text('?쇰꺼', style: Theme.of(context).textTheme.titleMedium),
...
                    labelText: '???쇰꺼',
...
                tooltip: '?쇰꺼 ?앹꽦',
...
          Text('諛뺤뒪', style: Theme.of(context).textTheme.titleMedium),
...
          if (image.visibleBoxes.isEmpty) const Text('諛뺤뒪 ?놁쓬'),
...
                label: const Text('?좏깮 諛뺤뒪 ??젣'),
```

with:

```dart
            label: Text(
              image.boxCount == 0
                  ? WorkbenchCopy.confirmNoObject
                  : WorkbenchCopy.confirm,
            ),
...
              child: Text(WorkbenchCopy.confirmNoObjectAvailable),
...
          const Divider(height: 28),
          const _SectionTitle(WorkbenchCopy.labels),
...
                    labelText: WorkbenchCopy.newLabel,
...
                tooltip: WorkbenchCopy.createLabelTooltip,
...
          const Divider(height: 28),
          const _SectionTitle(WorkbenchCopy.boxes),
...
          if (image.visibleBoxes.isEmpty) const Text(WorkbenchCopy.noBoxes),
...
                label: const Text(WorkbenchCopy.deleteSelectedBox),
```

In `_createLabel`, replace:

```dart
      setState(() => _labelError = '?쇰꺼紐낆쓣 ?낅젰?섏꽭??');
...
      setState(() => _labelError = '以묐났???쇰꺼紐낆엯?덈떎.');
```

with:

```dart
      setState(() => _labelError = WorkbenchCopy.enterLabelName);
...
      setState(() => _labelError = WorkbenchCopy.duplicateLabel);
```

In `_OverlayBox`, replace:

```dart
                label?.name ?? '誘몃씪踰?,
```

with:

```dart
                label?.name ?? WorkbenchCopy.unlabeledBox,
```

In `_BoxRow`, replace:

```dart
          '${label?.name ?? '誘몃씪踰?} 쨌 ${box.status.name} 쨌 '
```

with:

```dart
          '${label?.name ?? WorkbenchCopy.unlabeledBox} · ${box.status.name} · '
```

- [ ] **Step 7: Run workbench tests**

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
git commit -m "feat: polish canvas and inspector panels"
```

If either git check fails, record: `Commit skipped because this workspace has no .git directory or git executable.`

---

### Task 5: Final Verification

**Files:**
- Verify: all modified files

**Interfaces:**
- Consumes:
  - All behavior from Tasks 1-4
- Produces:
  - Formatted, analyzed, tested, and Windows-built project

- [ ] **Step 1: Check for corrupted visible workbench copy**

Run:

```powershell
rg -n "�|\\?대|誘|媛|諛|怨|痍|쨌" lib\ui\workbench_screen.dart test\ui\workbench_widget_test.dart
```

Expected: no matches and exit code `1`. If matches remain, replace them with clean copy from `WorkbenchCopy`.

- [ ] **Step 2: Format check**

Run:

```powershell
& 'C:\tools\flutter\bin\cache\dart-sdk\bin\dart.exe' format --set-exit-if-changed .
```

Expected: exit code `0`. If files are formatted, run the command again and expect `0 changed`.

- [ ] **Step 3: Analyze**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' analyze
```

Expected: `No issues found!`

- [ ] **Step 4: Run workbench-focused tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart test\widget_test.dart -r expanded
```

Expected: all tests in both files pass.

- [ ] **Step 5: Run full test suite**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test
```

Expected: `All tests passed!`

- [ ] **Step 6: Build Windows app**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' build windows
```

Expected: `Built build\windows\x64\runner\Release\bbox_labeler.exe`

- [ ] **Step 7: Check removed file-open workflow stays removed**

Run:

```powershell
rg -n "openProjectFile|saveProjectFile" lib test
```

Expected: no matches and exit code `1`.

- [ ] **Step 8: Record final git status or skipped status**

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
  - Empty project primary folder CTA: Task 1.
  - Same folder selection logic reused: Task 1.
  - Top bar hierarchy and save status: Task 2.
  - Neutral shell and panel surfaces: Tasks 2-4.
  - Left image queue summary and filters: Task 3.
  - Center canvas empty state and visual surface: Task 4.
  - Right inspector empty state and sections: Task 4.
  - Clean Korean copy: Tasks 1, 2, 4, and Task 5 verification.
  - Existing behavior preserved: Task 5 full tests.

- Type consistency:
  - `WorkbenchCopy` lives in `lib/ui/workbench_copy.dart`.
  - `WorkbenchCopy.imageStatusLabel(ImageStatus status)` consumes `ImageStatus`.
  - `_ImageListPanel` receives `VoidCallback onChooseImageFolder`.
  - `_ViewerPanel` receives `VoidCallback onChooseImageFolder`.
  - Widget keys match test expectations exactly.

- Verification:
  - Each implementation task starts with failing tests.
  - Each task has a focused pass command.
  - Final verification includes corrupted-copy search, format, analyze, focused tests, full tests, Windows build, and removed file-open workflow search.
