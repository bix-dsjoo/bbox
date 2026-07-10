# Image Import Entrypoint And Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace duplicated empty-project image import buttons with one clear import entrypoint, switch image import to modern native pickers, and show progress during large imports.

**Architecture:** Add a small picker abstraction for image folder/file selection, backed by `file_selector` in production and fakes in widget tests. Keep import state in `AppController` by extending the existing `ProjectActivity` and `ImageImportProgress` path, then render that state in `WorkbenchScreen`.

**Tech Stack:** Flutter, Dart, `file_selector`, existing `flutter_test` widget/controller tests.

## Global Constraints

- Empty projects show one primary image import action.
- Projects with images keep a top app bar image-add menu.
- Folder import does not show the path-entry modal by default.
- Image import uses native picker APIs from `file_selector`.
- Large imports show visible progress before completion.
- Import completion summarizes added, skipped, and error counts.
- Existing image import, save/load, and export tests continue to pass.
- This workspace is not currently a Git repository, so commit steps are informational only when `git status --short` fails with `fatal: not a git repository`.

---

### Task 1: Native Image Import Picker

**Files:**
- Modify: `pubspec.yaml`
- Create: `lib/ui/image_import_picker.dart`
- Test: `test/ui/image_import_picker_test.dart`
- Modify: `lib/ui/workbench_screen.dart`

**Interfaces:**
- Produces: `abstract class ImageImportPicker`
  - `Future<String?> pickImageFolder()`
  - `Future<List<String>> pickImageFiles()`
- Produces: `class FileSelectorImageImportPicker implements ImageImportPicker`
- Consumes: `file_selector.openFiles`, `file_selector.getDirectoryPath`, `XTypeGroup`

- [ ] **Step 1: Add dependency**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat pub add file_selector
```

Expected: `pubspec.yaml` and `pubspec.lock` update with `file_selector`.

- [ ] **Step 2: Write failing picker tests**

Create `test/ui/image_import_picker_test.dart`:

```dart
import 'package:bbox_labeler/ui/image_import_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ImageImportPicker helpers', () {
    test('image type group allows supported image extensions', () {
      final group = imageImportTypeGroup;

      expect(group.label, 'images');
      expect(group.extensions, ['jpg', 'jpeg', 'png']);
    });

    test('normalizes picked file paths from XFile-like paths', () {
      final paths = normalizePickedImagePaths([
        'C:\\images\\b.png',
        'C:\\images\\a.jpg',
        '',
      ]);

      expect(paths, ['C:\\images\\b.png', 'C:\\images\\a.jpg']);
    });
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\image_import_picker_test.dart
```

Expected: FAIL because `image_import_picker.dart`, `imageImportTypeGroup`, and `normalizePickedImagePaths` do not exist.

- [ ] **Step 4: Implement picker abstraction**

Create `lib/ui/image_import_picker.dart`:

```dart
import 'package:file_selector/file_selector.dart';

abstract class ImageImportPicker {
  const ImageImportPicker();

  Future<String?> pickImageFolder();

  Future<List<String>> pickImageFiles();
}

const imageImportTypeGroup = XTypeGroup(
  label: 'images',
  extensions: ['jpg', 'jpeg', 'png'],
);

List<String> normalizePickedImagePaths(List<String> paths) {
  return [
    for (final path in paths)
      if (path.trim().isNotEmpty) path.trim(),
  ];
}

class FileSelectorImageImportPicker extends ImageImportPicker {
  const FileSelectorImageImportPicker();

  @override
  Future<String?> pickImageFolder() {
    return getDirectoryPath(confirmButtonText: 'Select');
  }

  @override
  Future<List<String>> pickImageFiles() async {
    final files = await openFiles(
      acceptedTypeGroups: const [imageImportTypeGroup],
      confirmButtonText: 'Open',
    );
    return normalizePickedImagePaths([
      for (final file in files) file.path,
    ]);
  }
}
```

- [ ] **Step 5: Run picker test to verify it passes**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\image_import_picker_test.dart
```

Expected: PASS.

- [ ] **Step 6: Wire picker into `WorkbenchScreen` constructor**

Modify `lib/ui/workbench_screen.dart`:

```dart
import 'image_import_picker.dart';
```

Update `WorkbenchScreen` fields:

```dart
class WorkbenchScreen extends StatelessWidget {
  const WorkbenchScreen({
    super.key,
    required this.controller,
    this.chooseImageFolderPath,
    this.imageImportPicker = const FileSelectorImageImportPicker(),
  });

  final AppController controller;
  final ChooseImageFolderPath? chooseImageFolderPath;
  final ImageImportPicker imageImportPicker;
```

Update folder/file methods:

```dart
Future<void> _addImageFolder(BuildContext context) async {
  try {
    final pathPrompt = chooseImageFolderPath;
    final folderPath = pathPrompt == null
        ? await imageImportPicker.pickImageFolder()
        : await pathPrompt(context, null);
    if (!context.mounted || folderPath == null) {
      return;
    }
    await controller.addImagesFromFolder(folderPath);
  } catch (error) {
    if (context.mounted) {
      _showError(context, '이미지 폴더를 가져오지 못했습니다. $error');
    }
  }
}

Future<void> _addImageFiles(BuildContext context) async {
  try {
    final paths = await imageImportPicker.pickImageFiles();
    if (!context.mounted || paths.isEmpty) {
      return;
    }
    await controller.addImageFiles(paths);
  } catch (error) {
    if (context.mounted) {
      _showError(context, '이미지 파일을 가져오지 못했습니다. $error');
    }
  }
}
```

Keep `chooseImageFolderPath` for existing tests during this task.

- [ ] **Step 7: Run focused tests**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\image_import_picker_test.dart test\ui\workbench_widget_test.dart --name "empty project shows image folder as the primary next action"
```

Expected: PASS.

---

### Task 2: Single Empty-Project Import Entrypoint

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `test/ui/workbench_widget_test.dart`
- Modify: `test/widget_test.dart`
- Modify: `test/ui/project_home_widget_test.dart`

**Interfaces:**
- Consumes: `ImageImportPicker` from Task 1.
- Produces: only one empty-project import CTA keyed `empty-workbench-import-images`.
- Produces: top app bar image add is hidden when `project.images.isEmpty`.

- [ ] **Step 1: Write fake picker for widget tests**

Add near test helpers in `test/ui/workbench_widget_test.dart`:

```dart
class _FakeImageImportPicker extends ImageImportPicker {
  const _FakeImageImportPicker({this.folderPath, this.filePaths = const []});

  final String? folderPath;
  final List<String> filePaths;

  @override
  Future<String?> pickImageFolder() async => folderPath;

  @override
  Future<List<String>> pickImageFiles() async => filePaths;
}
```

Update `_app` helper to accept the picker:

```dart
Widget _app(
  AppController controller, {
  ChooseImageFolderPath? chooseImageFolderPath,
  ImageImportPicker imageImportPicker = const _FakeImageImportPicker(),
}) {
  return MaterialApp(
    home: WorkbenchScreen(
      controller: controller,
      chooseImageFolderPath: chooseImageFolderPath,
      imageImportPicker: imageImportPicker,
    ),
  );
}
```

- [ ] **Step 2: Write failing empty-state tests**

In `test/ui/workbench_widget_test.dart`, replace the current empty project test expectations with:

```dart
expect(find.byKey(const ValueKey('empty-workbench-import-images')), findsOneWidget);
expect(find.byKey(const ValueKey('image-list-empty-choose-folder')), findsNothing);
expect(find.byKey(const ValueKey('choose-image-add')), findsNothing);
```

Add a test:

```dart
testWidgets('top bar image add appears after images exist', (tester) async {
  final controller = AppController()..loadProject(_project());

  await tester.pumpWidget(_app(controller));

  expect(find.byKey(const ValueKey('choose-image-add')), findsOneWidget);
});
```

Add a test:

```dart
testWidgets('empty import menu can add an image folder', (tester) async {
  final tempDir = Directory.systemTemp.createTempSync('bbox_empty_import_menu');
  addTearDown(() => tempDir.deleteSync(recursive: true));

  final imagePath = '${tempDir.path}${Platform.pathSeparator}bread.png';
  final fixture = img.Image(width: 32, height: 24);
  img.fill(fixture, color: img.ColorRgb8(8, 10, 12));
  File(imagePath).writeAsBytesSync(img.encodePng(fixture));

  final controller = AppController()..createProject('demo');

  await tester.pumpWidget(
    _app(
      controller,
      imageImportPicker: _FakeImageImportPicker(folderPath: tempDir.path),
    ),
  );

  await tester.tap(find.byKey(const ValueKey('empty-workbench-import-images')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(WorkbenchCopy.addImageFolder).last);
  await tester.pump();
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pump();

  expect(controller.project!.images.single.displayName, 'bread.png');
});
```

- [ ] **Step 3: Run test to verify it fails**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart --name "empty"
```

Expected: FAIL because duplicate buttons still exist and the new key does not exist.

- [ ] **Step 4: Implement the single empty-project CTA**

In `lib/ui/workbench_screen.dart`, wrap the top app bar image add menu:

```dart
if (project.images.isNotEmpty) ...[
  _ImageImportMenuButton(
    buttonKey: const ValueKey('choose-image-add'),
    enabled: !automationRunning,
    label: WorkbenchCopy.imageAdd,
    onAddFiles: () => unawaited(_addImageFiles(context)),
    onAddFolder: () => unawaited(_addImageFolder(context)),
  ),
],
```

Extract menu widget:

```dart
class _ImageImportMenuButton extends StatelessWidget {
  const _ImageImportMenuButton({
    required this.buttonKey,
    required this.enabled,
    required this.label,
    required this.onAddFiles,
    required this.onAddFolder,
  });

  final Key buttonKey;
  final bool enabled;
  final String label;
  final VoidCallback onAddFiles;
  final VoidCallback onAddFolder;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      key: buttonKey,
      menuChildren: [
        MenuItemButton(
          onPressed: enabled ? onAddFolder : null,
          child: const Text(WorkbenchCopy.addImageFolder),
        ),
        MenuItemButton(
          onPressed: enabled ? onAddFiles : null,
          child: const Text(WorkbenchCopy.addImageFiles),
        ),
      ],
      builder: (context, menuController, child) => TextButton.icon(
        onPressed: enabled
            ? () {
                if (menuController.isOpen) {
                  menuController.close();
                } else {
                  menuController.open();
                }
              }
            : null,
        icon: const Icon(Icons.photo_library_outlined),
        label: Text(label),
      ),
    );
  }
}
```

Update `_ImageListPanel` empty state to remove action:

```dart
child: _EmptyActionState(
  icon: Icons.photo_library_outlined,
  title: WorkbenchCopy.noImagesYet,
  message: WorkbenchCopy.chooseFolderToStart,
),
```

Update `_ViewerPanel._buildEmptyState` to use the import menu:

```dart
return Center(
  child: _ImageImportMenuButton(
    buttonKey: const ValueKey('empty-workbench-import-images'),
    enabled: !widget.controller.isAutomationRunning,
    label: WorkbenchCopy.importImages,
    onAddFiles: () => unawaited(widget.onChooseImageFiles()),
    onAddFolder: () => unawaited(widget.onChooseImageFolder()),
  ),
);
```

If `_ViewerPanel` only has `onChooseImageFolder`, add `onChooseImageFiles` to its constructor and call sites.

- [ ] **Step 5: Update broad tests that expect the old empty buttons**

In `test/widget_test.dart` and `test/ui/project_home_widget_test.dart`, replace empty-project expectations:

```dart
expect(find.byKey(const ValueKey('empty-workbench-import-images')), findsOneWidget);
expect(find.byKey(const ValueKey('choose-image-add')), findsNothing);
```

Remove expectations for:

```dart
find.byKey(const ValueKey('image-list-empty-choose-folder'))
find.byKey(const ValueKey('empty-workbench-choose-folder'))
```

- [ ] **Step 6: Run focused tests**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart test\widget_test.dart test\ui\project_home_widget_test.dart
```

Expected: PASS.

---

### Task 3: Import Progress State And Summary

**Files:**
- Modify: `lib/ui/app_controller.dart`
- Modify: `lib/ui/workbench_copy.dart`
- Modify: `test/ui/app_controller_test.dart`

**Interfaces:**
- Modifies: `ImageImportProgress` adds `errors`.
- Produces: `WorkbenchCopy.importScanning`, `WorkbenchCopy.importComplete(...)`.
- Produces: private UI helper `_importProgressText(ImageImportProgress progress)`.
- Produces: `AppController.addImagesFromFolder` sets `ProjectActivity.importing` before scanning.

- [ ] **Step 1: Write failing controller tests**

In `test/ui/app_controller_test.dart`, add under `AppController image import`:

```dart
test('folder import exposes importing activity before scan completes', () async {
  final tempDir = await Directory.systemTemp.createTemp('bbox_import_progress');
  addTearDown(() => tempDir.delete(recursive: true));

  final imagePath = '${tempDir.path}${Platform.pathSeparator}bread.png';
  final fixture = img.Image(width: 20, height: 10);
  img.fill(fixture, color: img.ColorRgb8(18, 28, 38));
  await File(imagePath).writeAsBytes(img.encodePng(fixture));

  final controller = AppController()..createProject('demo');
  final activities = <ProjectActivity>[];
  controller.addListener(() => activities.add(controller.projectActivity));

  await controller.addImagesFromFolder(tempDir.path);

  expect(activities, contains(ProjectActivity.importing));
  expect(controller.projectActivity, ProjectActivity.idle);
});

test('image import progress counts added skipped and errors', () async {
  final tempDir = await Directory.systemTemp.createTemp('bbox_import_counts');
  addTearDown(() => tempDir.delete(recursive: true));

  final goodPath = '${tempDir.path}${Platform.pathSeparator}good.png';
  final brokenPath = '${tempDir.path}${Platform.pathSeparator}broken.png';
  final fixture = img.Image(width: 20, height: 10);
  img.fill(fixture, color: img.ColorRgb8(18, 28, 38));
  await File(goodPath).writeAsBytes(img.encodePng(fixture));
  await File(brokenPath).writeAsString('not an image');

  final controller = AppController()..createProject('demo');

  await controller.addImageFiles([goodPath, brokenPath, goodPath]);

  final progress = controller.lastImportProgress!;
  expect(progress.added, 2);
  expect(progress.skipped, 1);
  expect(progress.errors, 1);
  expect(controller.lastUserMessage, WorkbenchCopy.importComplete(2, 1, 1));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\app_controller_test.dart --name "image import"
```

Expected: FAIL because `errors` and import summary copy do not exist.

- [ ] **Step 3: Extend `ImageImportProgress` and copy**

In `lib/ui/app_controller.dart`:

```dart
class ImageImportProgress {
  const ImageImportProgress({
    required this.total,
    required this.processed,
    required this.added,
    required this.skipped,
    this.errors = 0,
  });

  final int total;
  final int processed;
  final int added;
  final int skipped;
  final int errors;
```

Update all `ImageImportProgress(...)` construction sites to pass `errors: errors` when available, and rely on default otherwise.

In `lib/ui/workbench_copy.dart`, add only copy that does not require importing `app_controller.dart`:

```dart
static const importScanning = '이미지 스캔 중...';

static String importComplete(int added, int skipped, int errors) {
  final parts = ['이미지 ${added}개 추가'];
  if (skipped > 0) {
    parts.add('${skipped}개 건너뜀');
  }
  if (errors > 0) {
    parts.add('${errors}개 오류');
  }
  return parts.join(' · ');
}
```

- [ ] **Step 4: Set scanning activity before folder scan**

In `addImagesFromFolder`:

```dart
Future<void> addImagesFromFolder(
  String folderPath, {
  Detector? detector,
}) async {
  _projectActivity = ProjectActivity.importing;
  _imageImportProgress = null;
  notifyListeners();
  try {
    final scanned = await ImageScanner.scanFolder(folderPath);
    await _addScannedImages(scanned, importedFrom: folderPath);
  } catch (_) {
    _projectActivity = ProjectActivity.idle;
    _imageImportProgress = null;
    notifyListeners();
    rethrow;
  }
}
```

In `_addScannedImages`, add:

```dart
var errors = 0;
```

When creating `importedImage`:

```dart
if (scanned.hasError) {
  errors += 1;
}
```

When setting progress:

```dart
_imageImportProgress = ImageImportProgress(
  total: scannedImages.length,
  processed: processed,
  added: added,
  skipped: skipped,
  errors: errors,
);
```

In `finally`, preserve final counts instead of resetting to all zero:

```dart
_imageImportProgress = ImageImportProgress(
  total: scannedImages.length,
  processed: processed,
  added: added,
  skipped: skipped,
  errors: errors,
);
lastUserMessage = WorkbenchCopy.importComplete(added, skipped, errors);
```

- [ ] **Step 5: Run focused controller tests**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\app_controller_test.dart --name "image import"
```

Expected: PASS.

---

### Task 4: Workbench Import Progress UI

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: `controller.projectActivity`, `controller.imageImportProgress`.
- Produces: widget keyed `image-import-progress`.

- [ ] **Step 1: Write failing progress widget tests**

In `test/ui/workbench_widget_test.dart`, add:

```dart
testWidgets('workbench shows importing progress', (tester) async {
  final controller = AppController()..createProject('demo');
  controller.debugSetImportProgressForTest(
    const ImageImportProgress(total: 10, processed: 3, added: 2, skipped: 1),
  );

  await tester.pumpWidget(_app(controller));

  expect(find.byKey(const ValueKey('image-import-progress')), findsOneWidget);
  expect(find.textContaining('3 / 10'), findsOneWidget);
  expect(find.textContaining('추가 2개'), findsOneWidget);
});

testWidgets('workbench shows scanning state before import total is known', (tester) async {
  final controller = AppController()..createProject('demo');
  controller.debugSetImportProgressForTest(null);
  controller.debugSetProjectActivityForTest(ProjectActivity.importing);

  await tester.pumpWidget(_app(controller));

  expect(find.byKey(const ValueKey('image-import-progress')), findsOneWidget);
  expect(find.text(WorkbenchCopy.importScanning), findsOneWidget);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart --name "importing progress|scanning state"
```

Expected: FAIL because debug setters and progress widget do not exist.

- [ ] **Step 3: Add test-only setters**

In `lib/ui/app_controller.dart`:

```dart
@visibleForTesting
void debugSetImportProgressForTest(ImageImportProgress? progress) {
  _imageImportProgress = progress;
  _projectActivity = ProjectActivity.importing;
  notifyListeners();
}

@visibleForTesting
void debugSetProjectActivityForTest(ProjectActivity activity) {
  _projectActivity = activity;
  notifyListeners();
}
```

- [ ] **Step 4: Render progress surface**

In `WorkbenchScreen.build`, above the quick label bar:

```dart
if (controller.projectActivity == ProjectActivity.importing)
  _ImageImportProgressBanner(controller: controller),
```

Add widget:

```dart
class _ImageImportProgressBanner extends StatelessWidget {
  const _ImageImportProgressBanner({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final progress = controller.imageImportProgress;
    final value = progress == null || progress.total <= 0
        ? null
        : progress.processed / progress.total;
    final text = progress == null || progress.total <= 0
        ? WorkbenchCopy.importScanning
        : _importProgressText(progress);

    return Container(
      key: const ValueKey('image-import-progress'),
      decoration: const BoxDecoration(
        color: _workbenchPanel,
        border: Border(top: BorderSide(color: _workbenchBorder)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: LinearProgressIndicator(value: value),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

String _importProgressText(ImageImportProgress progress) {
  final parts = [
    '이미지 불러오는 중 ${progress.processed} / ${progress.total}',
    '추가 ${progress.added}개',
    '건너뜀 ${progress.skipped}개',
  ];
  if (progress.errors > 0) {
    parts.add('오류 ${progress.errors}개');
  }
  return parts.join(' · ');
}
```

- [ ] **Step 5: Disable conflicting actions during import**

Use existing `automationRunning` checks plus:

```dart
final importRunning = controller.projectActivity == ProjectActivity.importing;
final busyForProjectMutation = automationRunning || importRunning;
```

Use `busyForProjectMutation` for:

- image import menu enabled state.
- export button.
- confirm/complete button.

- [ ] **Step 6: Run focused widget tests**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart --name "importing progress|scanning state|automation running locks editing"
```

Expected: PASS.

---

### Task 5: Cleanup And Verification

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `lib/ui/windows_dialog_service.dart` only if image import methods are now unused.
- Modify: `test/ui/workbench_widget_test.dart`
- Modify: `test/widget_test.dart`
- Modify: `test/ui/project_home_widget_test.dart`

**Interfaces:**
- Consumes all prior task outputs.
- Produces no new public API.

- [ ] **Step 1: Remove obsolete image import dialog usage**

Search:

```powershell
rg -n "ImageFolderPathDialog|pickImageFiles|pickFolder|_showImageFolderPathDialog|empty-workbench-choose-folder|image-list-empty-choose-folder" lib test
```

Expected after cleanup:

- `ImageFolderPathDialog` may remain only in its own tests if intentionally retained.
- `WindowsDialogService.pickImageFiles` is not used by image import.
- Old empty import keys are not expected by active widget tests.

- [ ] **Step 2: Run formatter**

Run:

```powershell
C:\tools\flutter\bin\dart.bat format lib test
```

Expected: formatter completes.

- [ ] **Step 3: Run analyzer**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat analyze
```

Expected: `No issues found!`

- [ ] **Step 4: Run full test suite**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test
```

Expected: all tests pass.

- [ ] **Step 5: Manual smoke check**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat run -d windows
```

Expected:

- New project shows one center import action.
- Center import action opens a menu with folder and file choices.
- Folder choice opens a native file selector folder dialog, not the custom path modal.
- During a large folder import, progress appears before the import finishes.
- After import, top app bar image-add menu appears.

- [ ] **Step 6: Commit if Git is available**

Run:

```powershell
git status --short
git add pubspec.yaml pubspec.lock lib test docs/superpowers/plans/2026-07-08-image-import-entrypoint-progress.md docs/superpowers/specs/2026-07-08-image-import-entrypoint-progress-design.md
git commit -m "feat: improve image import entrypoint and progress"
```

Expected in this workspace today: Git may fail because `C:\workspace\bbox` is not a Git repository. If so, report that commit was skipped.
