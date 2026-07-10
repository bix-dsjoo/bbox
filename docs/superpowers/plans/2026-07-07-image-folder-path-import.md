# Image Folder Path Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let repetitive labeling workers paste or type an image folder path and import it without relying only on the Windows folder tree picker.

**Architecture:** Keep image import behavior in `AppController.importImagesFromFolder()`. Add a small Flutter dialog in `WorkbenchScreen` that accepts a path, can still open the existing native folder picker, validates basic empty input, and calls the same controller import method.

**Tech Stack:** Flutter desktop, Material widgets, existing `AppController`, existing `WindowsDialogService`, Flutter widget tests.

---

### Task 1: Widget Test for Path-Based Folder Import

**Files:**
- Modify: `C:\workspace\bbox\test\ui\workbench_widget_test.dart`

- [ ] **Step 1: Write the failing test**

Add a widget test that creates a temporary image folder, opens the image folder dialog, enters the folder path, taps import, and verifies the image list updates.

```dart
testWidgets('imports images from a typed folder path', (tester) async {
  final tempDir = await Directory.systemTemp.createTemp('bbox_path_import');
  addTearDown(() => tempDir.delete(recursive: true));
  await File('${tempDir.path}${Platform.pathSeparator}typed.jpg')
      .writeAsBytes(img.encodeJpg(img.Image(width: 32, height: 24)));

  final controller = AppController();
  controller.createProject('demo');

  await tester.pumpWidget(_app(controller));
  await tester.tap(find.byKey(const ValueKey('choose-image-folder')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('image-folder-path-input')),
    tempDir.path,
  );
  await tester.tap(find.byKey(const ValueKey('import-image-folder-path')));
  await tester.pumpAndSettle();

  expect(controller.project!.imageFolderPath, tempDir.path);
  expect(controller.project!.images, hasLength(1));
  expect(find.byKey(const ValueKey('image-row-1')), findsOneWidget);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ui/workbench_widget_test.dart -r compact`

Expected: FAIL because `image-folder-path-input` and `import-image-folder-path` do not exist yet.

### Task 2: Implement the Path Import Dialog

**Files:**
- Modify: `C:\workspace\bbox\lib\ui\workbench_screen.dart`

- [ ] **Step 1: Replace direct native picker call with a Flutter dialog**

Change `_chooseImageFolder` so it opens an app dialog with:

- `TextField` key `image-folder-path-input`
- `TextButton` key `browse-image-folder`
- `ElevatedButton` key `import-image-folder-path`

The import button trims text and returns the path to `_chooseImageFolder`.

- [ ] **Step 2: Keep native browse as an optional helper**

Inside the dialog, `browse-image-folder` calls `WindowsDialogService.pickFolder(title: '이미지 폴더 선택')`. If a path is returned, populate the text field instead of importing immediately.

- [ ] **Step 3: Import through the existing controller**

After the dialog returns a non-null path, call:

```dart
await controller.importImagesFromFolder(folderPath);
```

If import fails, keep the existing snack bar error style:

```dart
_showError(context, '이미지 폴더를 불러오지 못했습니다. $error');
```

### Task 3: Verify and QA

**Files:**
- No code files beyond Task 1 and Task 2.

- [ ] **Step 1: Run targeted test**

Run: `flutter test test/ui/workbench_widget_test.dart -r compact`

Expected: PASS.

- [ ] **Step 2: Run full automated verification**

Run:

```powershell
dart format --set-exit-if-changed .
flutter analyze
flutter test
flutter build windows
```

Expected: all commands exit 0.

- [ ] **Step 3: Run Windows QA**

Open the release executable, create a project, click `이미지 폴더 선택`, paste `C:\workspace\bbox\qa_samples\images`, import, and verify that the image list is no longer empty.
