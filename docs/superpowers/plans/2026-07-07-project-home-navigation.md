# Project Home Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a safe, explicit Project Home navigation flow from the workbench, with save status feedback and project-home source-folder health.

**Architecture:** `AppController` owns the project lifecycle, save status, and return-home command. `BboxApp` continues switching screens from `controller.hasProject`. `WorkbenchScreen` exposes the navigation action and save status, while `StartScreen` remains the project hub and adds lightweight source-folder health.

**Tech Stack:** Flutter desktop, Dart, `ChangeNotifier`, existing `ProjectLibrary`, existing `ProjectStore`, Flutter widget tests, Flutter unit tests.

## Global Constraints

- Source images must not be copied, moved, or modified.
- Project file open/save dialogs must not be reintroduced.
- Returning home must not discard in-memory annotations when save fails.
- Normal home navigation must not show a confirmation dialog.
- Save status must use text plus icon, not color alone.
- The workbench must keep the labeling surface focused and avoid a permanent project sidebar.
- Existing direct `AppController.createProject` tests must keep working.
- Use `C:\tools\flutter\bin\cache\dart-sdk\bin\dart.exe` for Dart formatting in this workspace.
- Git commit steps are included. In this workspace, `Test-Path .git` is currently `False` and `git` is not on `PATH`; if that is still true during execution, skip the commit step and report it.

---

## File Structure

- Modify `lib/ui/app_controller.dart`
  - Add `SaveStatus`.
  - Add `saveStatus`, `lastSaveError`, and `returnToProjectHome()`.
  - Make manual save and autosave update shared save status.
  - Clear active project state only after a successful save.

- Modify `lib/ui/workbench_screen.dart`
  - Add a `Project home` action in the app bar.
  - Add a compact save status indicator near the project title.
  - Call `controller.returnToProjectHome()` and show a save-failure snackbar without navigating away.

- Modify `lib/ui/start_screen.dart`
  - Show source-folder health for entries with missing image folders.
  - Keep rename/delete interactions unchanged.

- Modify `test/ui/app_controller_library_test.dart`
  - Add controller tests for successful return-home and failed return-home.

- Modify `test/widget_test.dart`
  - Add app-level tests for workbench-to-home navigation and save-failure behavior.

- Modify `test/ui/project_home_widget_test.dart`
  - Add a project-home list test for missing image folder state.

---

### Task 1: Controller Save Status And Return-Home Command

**Files:**
- Modify: `test/ui/app_controller_library_test.dart`
- Modify: `lib/ui/app_controller.dart`

**Interfaces:**
- Produces:
  - `enum SaveStatus { saved, saving, failed }`
  - `SaveStatus get saveStatus`
  - `Object? get lastSaveError`
  - `Future<void> returnToProjectHome()`
- Consumes:
  - Existing `ProjectStore.save(AnnotationProject project, String projectFilePath)`
  - Existing `ProjectLibrary.refreshEntry(AnnotationProject project)`
  - Existing `ProjectLibrary.listProjects()`

- [ ] **Step 1: Write failing controller tests**

Add these tests inside the existing `group('AppController project library', () { ... })` in `test/ui/app_controller_library_test.dart`:

```dart
    test('returns to project home after saving the current project', () async {
      await controller.createLibraryProject('Home Demo');
      controller.loadProject(
        controller.project!.copyWith(
          images: const [
            AnnotatedImage(
              id: 1,
              relativePath: 'done.jpg',
              width: 100,
              height: 80,
              status: ImageStatus.confirmed,
            ),
          ],
        ),
      );

      await controller.returnToProjectHome();

      expect(controller.hasProject, isFalse);
      expect(controller.selectedImageId, isNull);
      expect(controller.selectedBoxId, isNull);
      expect(controller.saveStatus, SaveStatus.saved);
      expect(controller.lastSaveError, isNull);
      expect(controller.projectLibraryEntries.single.name, 'Home Demo');
      expect(controller.projectLibraryEntries.single.imageCount, 1);
      expect(controller.projectLibraryEntries.single.confirmedImageCount, 1);
    });

    test('keeps the project open when returning home cannot save', () async {
      controller.createProject('Unsaved Direct Project');

      await expectLater(
        controller.returnToProjectHome(),
        throwsA(isA<StateError>()),
      );

      expect(controller.hasProject, isTrue);
      expect(controller.project!.name, 'Unsaved Direct Project');
      expect(controller.saveStatus, SaveStatus.failed);
      expect(controller.lastSaveError, isA<StateError>());
    });
```

- [ ] **Step 2: Run the controller tests and verify they fail**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\app_controller_library_test.dart -r expanded
```

Expected: FAIL because `returnToProjectHome`, `SaveStatus`, `saveStatus`, or `lastSaveError` is not defined.

- [ ] **Step 3: Add save status state to `AppController`**

In `lib/ui/app_controller.dart`, add the enum below `ImageListFilter`:

```dart
enum SaveStatus { saved, saving, failed }
```

Inside `class AppController extends ChangeNotifier`, add fields near the existing state fields:

```dart
  SaveStatus _saveStatus = SaveStatus.saved;
  Object? _lastSaveError;
```

Add getters near the existing public getters:

```dart
  SaveStatus get saveStatus => _saveStatus;

  Object? get lastSaveError => _lastSaveError;
```

- [ ] **Step 4: Reset save status when project context changes**

In `createProject`, before `notifyListeners();`, add:

```dart
    _saveStatus = SaveStatus.saved;
    _lastSaveError = null;
```

In `loadProject`, before `notifyListeners();`, add:

```dart
    _saveStatus = SaveStatus.saved;
    _lastSaveError = null;
```

In `createLibraryProject`, before `notifyListeners();`, add:

```dart
    _saveStatus = SaveStatus.saved;
    _lastSaveError = null;
```

In `openLibraryProject`, after `_projectLibraryEntries = await _projectLibrary.listProjects();`, add:

```dart
    _saveStatus = SaveStatus.saved;
    _lastSaveError = null;
```

In `renameLibraryProject`, after `_projectLibraryEntries = await _projectLibrary.listProjects();`, add:

```dart
    _saveStatus = SaveStatus.saved;
    _lastSaveError = null;
```

In `deleteLibraryProject`, inside `if (_currentLibraryProjectId == id) { ... }`, before the closing brace, add:

```dart
      _saveStatus = SaveStatus.saved;
      _lastSaveError = null;
```

In `reconnectSelectedProjectImageFolder`, before `notifyListeners();`, add:

```dart
    _saveStatus = SaveStatus.saved;
    _lastSaveError = null;
```

- [ ] **Step 5: Update manual save to report saving, saved, and failed states**

Replace the existing `saveProject` method in `lib/ui/app_controller.dart` with:

```dart
  Future<void> saveProject([String? projectFilePath]) async {
    _saveStatus = SaveStatus.saving;
    _lastSaveError = null;
    notifyListeners();
    try {
      final targetPath = projectFilePath ?? _requireProject().projectFilePath;
      if (targetPath == null) {
        throw StateError('Project path is required.');
      }
      await _autoSaveChain;
      _project = await ProjectStore.save(_requireProject(), targetPath);
      _currentLibraryProjectId = _libraryProjectIdForPath(
        _project!.projectFilePath,
      );
      await _refreshLibraryEntryIfNeeded();
      _saveStatus = SaveStatus.saved;
      _lastSaveError = null;
      notifyListeners();
    } catch (error) {
      lastError = error;
      _lastSaveError = error;
      _saveStatus = SaveStatus.failed;
      notifyListeners();
      rethrow;
    }
  }
```

- [ ] **Step 6: Update autosave to report shared save status**

Replace the existing `_scheduleAutoSave` method in `lib/ui/app_controller.dart` with:

```dart
  void _scheduleAutoSave() {
    final path = _project?.projectFilePath;
    if (path == null) {
      return;
    }
    _saveStatus = SaveStatus.saving;
    _lastSaveError = null;
    notifyListeners();
    _autoSaveChain = _autoSaveChain
        .then((_) async {
          final project = _project;
          if (project == null) {
            return;
          }
          _project = await ProjectStore.save(project, path);
          _currentLibraryProjectId = _libraryProjectIdForPath(
            _project!.projectFilePath,
          );
          await _refreshLibraryEntryIfNeeded();
          _saveStatus = SaveStatus.saved;
          _lastSaveError = null;
          notifyListeners();
        })
        .catchError((Object error) {
          lastError = error;
          _lastSaveError = error;
          _saveStatus = SaveStatus.failed;
          notifyListeners();
        });
    unawaited(_autoSaveChain);
  }
```

- [ ] **Step 7: Add the return-home command and active-project cleanup**

Add these methods above `_requireProject()` in `lib/ui/app_controller.dart`:

```dart
  Future<void> returnToProjectHome() async {
    await saveProject();
    _clearActiveProject();
    await loadProjectLibrary();
  }

  void _clearActiveProject() {
    _project = null;
    _currentLibraryProjectId = null;
    _selectedImageId = null;
    _selectedBoxId = null;
    _imageListFilter = ImageListFilter.all;
    _undoStack.clear();
    _redoStack.clear();
    _saveStatus = SaveStatus.saved;
    _lastSaveError = null;
    notifyListeners();
  }
```

- [ ] **Step 8: Run the controller tests and verify they pass**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\app_controller_library_test.dart -r expanded
```

Expected: PASS for all tests in `test/ui/app_controller_library_test.dart`.

- [ ] **Step 9: Run analyzer**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' analyze
```

Expected: `No issues found!`

- [ ] **Step 10: Commit or record skipped commit**

Run:

```powershell
Test-Path .git
Get-Command git -ErrorAction SilentlyContinue
```

If both git checks pass:

```powershell
git add lib\ui\app_controller.dart test\ui\app_controller_library_test.dart
git commit -m "feat: add project home return controller flow"
```

If either git check fails, record: `Commit skipped because this workspace has no .git directory or git executable.`

---

### Task 2: Workbench Project Home Action And Save Status UI

**Files:**
- Modify: `test/widget_test.dart`
- Modify: `lib/ui/workbench_screen.dart`

**Interfaces:**
- Consumes:
  - `AppController.returnToProjectHome()`
  - `AppController.saveStatus`
  - `SaveStatus.saved`
  - `SaveStatus.saving`
  - `SaveStatus.failed`
- Produces:
  - Workbench button key `project-home-action`
  - Save status keys `save-status-saved`, `save-status-saving`, `save-status-failed`

- [ ] **Step 1: Write failing app-level widget tests**

In `test/widget_test.dart`, add these tests after the existing widget test:

```dart
  testWidgets('workbench project home action saves and returns home', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'bbox_widget_home_return',
    );
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final controller = AppController(
      projectLibrary: MemoryProjectLibrary(
        rootPath: tempDir.path,
        fixedId: 'home-return-project',
      ),
    );

    await tester.pumpWidget(BboxApp(controller: controller));
    await tester.pump();
    await _pumpRealAsync(tester);
    await tester.enterText(
      find.byKey(const ValueKey('new-project-name')),
      'Return Demo',
    );
    await tester.tap(find.byKey(const ValueKey('create-project')));
    await tester.pump();
    await _pumpRealAsync(tester);

    expect(find.byKey(const ValueKey('project-home-action')), findsOneWidget);
    expect(find.byKey(const ValueKey('save-status-saved')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('project-home-action')));
    await tester.pump();
    await _pumpRealAsync(tester);

    expect(find.byKey(const ValueKey('project-home')), findsOneWidget);
    expect(find.byKey(const ValueKey('project-entry-home-return-project')), findsOneWidget);
    expect(controller.hasProject, isFalse);
  });

  testWidgets('workbench stays open when project home save fails', (
    tester,
  ) async {
    final controller = AppController();
    controller.createProject('Unsaved Direct Project');

    await tester.pumpWidget(BboxApp(controller: controller));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('project-home-action')));
    await tester.pump();
    await _pumpRealAsync(tester);

    expect(find.byKey(const ValueKey('choose-image-folder')), findsOneWidget);
    expect(find.byKey(const ValueKey('project-home')), findsNothing);
    expect(find.textContaining('Project home was not opened'), findsOneWidget);
    expect(find.byKey(const ValueKey('save-status-failed')), findsOneWidget);
  });
```

If the first test line is longer than the formatter accepts, allow `dart format` to wrap it.

- [ ] **Step 2: Run the widget tests and verify they fail**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\widget_test.dart -r expanded
```

Expected: FAIL because `project-home-action` and save status widgets are not present.

- [ ] **Step 3: Add the workbench app bar layout**

In `lib/ui/workbench_screen.dart`, replace the current `appBar: AppBar(` block header through the `title` line:

```dart
          appBar: AppBar(
            title: Text(project.name),
            actions: [
```

with:

```dart
          appBar: AppBar(
            titleSpacing: 8,
            title: Row(
              children: [
                TextButton.icon(
                  key: const ValueKey('project-home-action'),
                  onPressed: () => _returnToProjectHome(context),
                  icon: const Icon(Icons.home_outlined),
                  label: const Text('Project home'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    project.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                _SaveStatusIndicator(status: controller.saveStatus),
              ],
            ),
            actions: [
```

- [ ] **Step 4: Add the return-home UI handler**

In `lib/ui/workbench_screen.dart`, add this method below `_saveProject`:

```dart
  Future<void> _returnToProjectHome(BuildContext context) async {
    try {
      await controller.returnToProjectHome();
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      _showError(
        context,
        'Current changes could not be saved. Project home was not opened. $error',
      );
    }
  }
```

- [ ] **Step 5: Add the save status indicator widget**

In `lib/ui/workbench_screen.dart`, add this private widget below `_MissingImageFolderBanner`:

```dart
class _SaveStatusIndicator extends StatelessWidget {
  const _SaveStatusIndicator({required this.status});

  final SaveStatus status;

  @override
  Widget build(BuildContext context) {
    final (key, icon, label, color) = switch (status) {
      SaveStatus.saved => (
        const ValueKey('save-status-saved'),
        Icons.check_circle_outline,
        'Saved',
        Theme.of(context).colorScheme.primary,
      ),
      SaveStatus.saving => (
        const ValueKey('save-status-saving'),
        Icons.sync,
        'Saving...',
        Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      SaveStatus.failed => (
        const ValueKey('save-status-failed'),
        Icons.error_outline,
        'Save failed',
        Theme.of(context).colorScheme.error,
      ),
    };
    return Semantics(
      label: label,
      child: Tooltip(
        message: label,
        child: Row(
          key: key,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 6: Run the widget tests and verify they pass**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\widget_test.dart -r expanded
```

Expected: PASS for all tests in `test/widget_test.dart`.

- [ ] **Step 7: Run workbench widget tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart -r expanded
```

Expected: PASS for all tests in `test/ui/workbench_widget_test.dart`.

- [ ] **Step 8: Commit or record skipped commit**

Run:

```powershell
Test-Path .git
Get-Command git -ErrorAction SilentlyContinue
```

If both git checks pass:

```powershell
git add lib\ui\workbench_screen.dart test\widget_test.dart
git commit -m "feat: add workbench project home navigation"
```

If either git check fails, record: `Commit skipped because this workspace has no .git directory or git executable.`

---

### Task 3: Project Home Source Folder Health

**Files:**
- Modify: `test/ui/project_home_widget_test.dart`
- Modify: `lib/ui/start_screen.dart`

**Interfaces:**
- Consumes:
  - `ProjectLibraryEntry.imageFolderPath`
  - Existing project list item key `project-entry-<id>`
- Produces:
  - Project-home text `Image folder missing`
  - Project-home key `project-source-missing-<id>`

- [ ] **Step 1: Write the failing project-home widget test**

In `test/ui/project_home_widget_test.dart`, add this test inside the existing `group('Project home', () { ... })`:

```dart
    testWidgets('shows when a project source image folder is missing', (
      tester,
    ) async {
      final tempDir = Directory.systemTemp.createTempSync(
        'bbox_project_home_missing',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final library = MemoryProjectLibrary(
        rootPath: tempDir.path,
        fixedId: 'missing-folder-project',
      );
      final project = await library.createProject('Missing Folder');
      await library.refreshEntry(
        project.copyWith(
          imageFolderPath:
              '${tempDir.path}${Platform.pathSeparator}missing-images',
        ),
      );
      final controller = AppController(projectLibrary: library);

      await tester.pumpWidget(MaterialApp(home: StartScreen(controller: controller)));
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();

      expect(
        find.byKey(
          const ValueKey('project-source-missing-missing-folder-project'),
        ),
        findsOneWidget,
      );
      expect(find.text('Image folder missing'), findsOneWidget);
    });
```

If `Directory`, `Platform`, `MaterialApp`, `StartScreen`, or `AppController` imports are missing, add these imports at the top of the file:

```dart
import 'dart:io';

import 'package:bbox_labeler/ui/app_controller.dart';
import 'package:bbox_labeler/ui/start_screen.dart';
import 'package:flutter/material.dart';
```

- [ ] **Step 2: Run the project-home tests and verify they fail**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\project_home_widget_test.dart -r expanded
```

Expected: FAIL because `project-source-missing-<id>` is not present.

- [ ] **Step 3: Add source-folder health display**

In `lib/ui/start_screen.dart`, add this import at the top:

```dart
import 'dart:io';
```

Inside the project list `itemBuilder`, immediately after:

```dart
                              final entry = widget
                                  .controller
                                  .projectLibraryEntries[index];
```

add:

```dart
                              final sourceMissing =
                                  entry.imageFolderPath != null &&
                                  !Directory(entry.imageFolderPath!).existsSync();
```

Replace the current `subtitle: Text(...)` in the `ListTile` with:

```dart
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${entry.imageCount} images - '
                                      '${entry.confirmedImageCount} confirmed - '
                                      '${entry.errorImageCount} errors',
                                    ),
                                    if (sourceMissing)
                                      Row(
                                        key: ValueKey(
                                          'project-source-missing-${entry.id}',
                                        ),
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.folder_off_outlined,
                                            size: 16,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.error,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            'Image folder missing',
                                            style: TextStyle(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.error,
                                            ),
                                          ),
                                        ],
                                      ),
                                  ],
                                ),
```

- [ ] **Step 4: Run the project-home tests and verify they pass**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\project_home_widget_test.dart -r expanded
```

Expected: PASS for all tests in `test/ui/project_home_widget_test.dart`.

- [ ] **Step 5: Run the app-level widget tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\widget_test.dart -r expanded
```

Expected: PASS for all tests in `test/widget_test.dart`.

- [ ] **Step 6: Commit or record skipped commit**

Run:

```powershell
Test-Path .git
Get-Command git -ErrorAction SilentlyContinue
```

If both git checks pass:

```powershell
git add lib\ui\start_screen.dart test\ui\project_home_widget_test.dart
git commit -m "feat: show project source folder health"
```

If either git check fails, record: `Commit skipped because this workspace has no .git directory or git executable.`

---

### Task 4: Final Verification

**Files:**
- Verify: all modified files

**Interfaces:**
- Consumes:
  - All behavior from Tasks 1-3
- Produces:
  - Formatted, analyzed, tested, and Windows-built project

- [ ] **Step 1: Format check**

Run:

```powershell
& 'C:\tools\flutter\bin\cache\dart-sdk\bin\dart.exe' format --set-exit-if-changed .
```

Expected: exit code `0`. If files are formatted, run the command again and expect `0 changed`.

- [ ] **Step 2: Analyze**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' analyze
```

Expected: `No issues found!`

- [ ] **Step 3: Run full test suite**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test
```

Expected: `All tests passed!`

- [ ] **Step 4: Build Windows app**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' build windows
```

Expected: `Built build\windows\x64\runner\Release\bbox_labeler.exe`

- [ ] **Step 5: Check removed file-open workflow stays removed**

Run:

```powershell
rg -n "openProjectFile|saveProjectFile" lib test
```

Expected: no matches and exit code `1`.

- [ ] **Step 6: Record final git status or skipped status**

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
  - Explicit `Project home` action: Task 2.
  - Save before home navigation: Task 1 and Task 2.
  - Save failure keeps user in workbench: Task 1 and Task 2.
  - Save status text and icon: Task 2.
  - Project home as a work hub: Task 3.
  - Source folder missing visibility: Task 3.
  - No file-open workflow: Task 4.

- Type consistency:
  - `SaveStatus` is defined in `lib/ui/app_controller.dart`.
  - `saveStatus` and `lastSaveError` are getters on `AppController`.
  - `returnToProjectHome()` is a `Future<void>` on `AppController`.
  - Widget keys match the test expectations exactly.

- Verification:
  - Each task begins with failing tests.
  - Each task has a focused pass command.
  - Final verification includes format, analyze, full tests, Windows build, and file-open workflow search.
