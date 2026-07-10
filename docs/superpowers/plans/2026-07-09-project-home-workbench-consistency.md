# Project Home Workbench Consistency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the project home and workbench feel like one coherent Korean desktop labeling tool with restrained professional control radii.

**Architecture:** Keep the current `StartScreen` and `WorkbenchScreen` ownership boundaries. Add small copy and metric helpers under `lib/ui`, then update tests and widgets in place without changing annotation, project storage, canvas, or export behavior.

**Tech Stack:** Flutter, Dart, Material widgets, FORUI theme bridge, Pretendard, `flutter_test`.

## Global Constraints

- All visible product UI copy must be Korean-first.
- Keep standard technical terms only where useful, such as `COCO`, `BBox`, and keyboard shortcut labels.
- Buttons use `4px` corner radius.
- Text fields, menus, and small badges use `4px` corner radius.
- List rows use `4px` to `6px` corner radius.
- Panels use `0px` at full-height screen edges, or `6px` only for contained surfaces.
- Large repeated cards are avoided; if required, max `8px`.
- Do not change annotation domain models.
- Do not change bbox coordinates, canvas transforms, or COCO export rules.
- Do not add cloud, account, collaboration, or training features.
- Do not replace the three-panel workbench.
- Do not create a decorative landing page.
- This workspace is currently not a git repository. For commit steps, first run `git rev-parse --show-toplevel`; if it fails with `not a git repository`, skip the commit and record the skipped commit message in the task notes.

---

## File Structure

- Create `lib/ui/project_home_copy.dart`: Korean-only copy constants and helper formatters for the project home.
- Modify `lib/ui/app_theme.dart`: add shared radius constants and apply restrained Material shape defaults.
- Modify `lib/ui/start_screen.dart`: replace English copy, polish the project home layout, and use compact professional radii.
- Modify `lib/ui/workbench_copy.dart`: add Korean undo/redo copy if not present.
- Modify `lib/ui/workbench_screen.dart`: replace remaining English tooltips and reduce exaggerated radii.
- Modify `lib/ui/bbox_app.dart`: update app title to Korean technical product title.
- Modify `test/ui/project_home_widget_test.dart`: assert Korean home copy, row metadata, menu labels, and delete reassurance.
- Modify `test/widget_test.dart`: update app-level home expectations.
- Modify `test/ui/workbench_widget_test.dart`: assert undo/redo tooltips are Korean and key controls use restrained shapes.

---

### Task 1: Project Home Korean Copy Tests

**Files:**
- Modify: `test/ui/project_home_widget_test.dart`
- Modify: `test/widget_test.dart`

**Interfaces:**
- Consumes: existing `BboxApp`, `AppController`, `MemoryProjectLibrary`, widget keys.
- Produces: failing tests that require Korean project-home copy and metadata.

- [ ] **Step 1: Update project home empty-state test to Korean**

Replace the first test in `test/ui/project_home_widget_test.dart` with:

```dart
    testWidgets('first launch shows a Korean project home', (tester) async {
      await tester.pumpWidget(BboxApp(controller: controller));
      await tester.pump();
      await _pumpRealAsync(tester);

      expect(find.byKey(const ValueKey('project-home')), findsOneWidget);
      expect(find.text('프로젝트 홈'), findsOneWidget);
      expect(find.text('라벨링 프로젝트를 만들거나 이어서 작업하세요.'), findsOneWidget);
      expect(find.byKey(const ValueKey('new-project-name')), findsOneWidget);
      expect(find.text('프로젝트 이름'), findsOneWidget);
      expect(find.byKey(const ValueKey('create-project')), findsOneWidget);
      expect(find.text('만들기'), findsOneWidget);
      expect(find.text('프로젝트가 없습니다'), findsOneWidget);
      expect(find.text('새 프로젝트를 만들어 이미지 라벨링을 시작하세요.'), findsOneWidget);
      expect(find.text('No projects yet'), findsNothing);
      expect(find.text('Project name'), findsNothing);
      expect(find.text('New project'), findsNothing);
    });
```

- [ ] **Step 2: Add project row metadata and menu Korean assertions**

In `test/ui/project_home_widget_test.dart`, add this test after `returning launch lists and opens saved projects`:

```dart
    testWidgets('project rows use Korean metadata and action labels', (
      tester,
    ) async {
      await library.createProject('저장된 프로젝트');

      await tester.pumpWidget(BboxApp(controller: controller));
      await tester.pump();
      await _pumpRealAsync(tester);

      expect(find.text('저장된 프로젝트'), findsOneWidget);
      expect(find.textContaining('이미지 0장'), findsOneWidget);
      expect(find.textContaining('완료 0장'), findsOneWidget);
      expect(find.textContaining('문제 0장'), findsOneWidget);

      final menu = find.byKey(const ValueKey('project-menu-home-project'));
      expect(tester.widget<PopupMenuButton<String>>(menu).tooltip, '프로젝트 작업');

      await tester.tap(menu);
      await tester.pumpAndSettle();

      expect(find.text('이름 변경'), findsOneWidget);
      expect(find.text('삭제'), findsOneWidget);
      expect(find.text('Rename'), findsNothing);
      expect(find.text('Delete'), findsNothing);
    });
```

- [ ] **Step 3: Update delete confirmation assertion**

In `test/ui/project_home_widget_test.dart`, replace:

```dart
        expect(
          find.textContaining('Source images will not be deleted'),
          findsOneWidget,
        );
```

with:

```dart
        expect(find.text('프로젝트 삭제'), findsOneWidget);
        expect(
          find.text('내부 프로젝트 데이터만 삭제됩니다. 원본 이미지는 삭제되지 않습니다.'),
          findsOneWidget,
        );
        expect(find.text('Source images will not be deleted'), findsNothing);
```

- [ ] **Step 4: Update root widget home expectations**

In `test/widget_test.dart`, replace:

```dart
    expect(find.text('Bounding Box Labeler'), findsOneWidget);
```

with:

```dart
    expect(find.text('프로젝트 홈'), findsOneWidget);
    expect(find.text('Bounding Box Labeler'), findsNothing);
```

In the `project home uses Pretendard and FORUI primary action` test, replace:

```dart
    final title = tester.widget<Text>(find.text('Bounding Box Labeler'));
    expect(title.style?.fontFamily, 'Pretendard');
```

with:

```dart
    final title = tester.widget<Text>(find.text('프로젝트 홈'));
    expect(title.style?.fontFamily, 'Pretendard');
```

- [ ] **Step 5: Run tests and verify they fail for the expected reason**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\project_home_widget_test.dart test\widget_test.dart
```

Expected: FAIL because current UI still contains `Bounding Box Labeler`, `Project name`, `New project`, `No projects yet`, English menu/dialog copy, and not the new Korean strings.

- [ ] **Step 6: Commit or record skipped commit**

Run:

```powershell
git rev-parse --show-toplevel
```

If it succeeds:

```powershell
git add test\ui\project_home_widget_test.dart test\widget_test.dart
git commit -m "test: specify Korean project home copy"
```

If it fails with `not a git repository`, record this skipped commit message in task notes:

```text
Skipped commit: test: specify Korean project home copy
```

---

### Task 2: Project Home Implementation

**Files:**
- Create: `lib/ui/project_home_copy.dart`
- Modify: `lib/ui/start_screen.dart`
- Modify: `lib/ui/bbox_app.dart`
- Test: `test/ui/project_home_widget_test.dart`
- Test: `test/widget_test.dart`

**Interfaces:**
- Consumes: failing tests from Task 1.
- Produces: `ProjectHomeCopy` constants and a Korean professional project home.

- [ ] **Step 1: Create project home copy constants**

Create `lib/ui/project_home_copy.dart`:

```dart
class ProjectHomeCopy {
  const ProjectHomeCopy._();

  static const appTitle = 'BBox 라벨러';
  static const title = '프로젝트 홈';
  static const subtitle = '라벨링 프로젝트를 만들거나 이어서 작업하세요.';
  static const projectName = '프로젝트 이름';
  static const defaultProjectName = '새 라벨링 프로젝트';
  static const createProject = '만들기';
  static const noProjects = '프로젝트가 없습니다';
  static const noProjectsMessage = '새 프로젝트를 만들어 이미지 라벨링을 시작하세요.';
  static const projectActions = '프로젝트 작업';
  static const rename = '이름 변경';
  static const delete = '삭제';
  static const cancel = '취소';
  static const renameTitle = '프로젝트 이름 변경';
  static const renameConfirm = '변경';
  static const deleteTitle = '프로젝트 삭제';
  static const deleteMessage =
      '내부 프로젝트 데이터만 삭제됩니다. 원본 이미지는 삭제되지 않습니다.';

  static String projectSummary({
    required int images,
    required int confirmed,
    required int errors,
  }) {
    return '이미지 $images장 · 완료 $confirmed장 · 문제 $errors장';
  }

  static String actionFailed(Object error) {
    return '프로젝트 작업을 완료하지 못했습니다. 다시 시도하세요. $error';
  }
}
```

- [ ] **Step 2: Import project home copy in `start_screen.dart`**

Add this import:

```dart
import 'project_home_copy.dart';
```

- [ ] **Step 3: Update default project name**

In `_StartScreenState`, replace:

```dart
  final TextEditingController _nameController = TextEditingController(
    text: 'BBox Project',
  );
```

with:

```dart
  final TextEditingController _nameController = TextEditingController(
    text: ProjectHomeCopy.defaultProjectName,
  );
```

- [ ] **Step 4: Replace the project home title and subtitle**

In `StartScreen.build`, replace the single title `Text('Bounding Box Labeler', ...)` with:

```dart
                      Text(
                        ProjectHomeCopy.title,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              fontFamily: BboxAppTheme.fontFamily,
                              fontWeight: FontWeight.w800,
                              color: WorkbenchPalette.foreground,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        ProjectHomeCopy.subtitle,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(
                              color: WorkbenchPalette.mutedForeground,
                            ),
                      ),
                      const SizedBox(height: 20),
```

Remove the old `const SizedBox(height: 20)` that immediately followed the old title so spacing is not duplicated.

- [ ] **Step 5: Replace input and create button copy**

In the new project row, replace:

```dart
                                labelText: 'Project name',
```

with:

```dart
                                labelText: ProjectHomeCopy.projectName,
```

Replace:

```dart
                              label: const Text('New project'),
```

with:

```dart
                              label: const Text(ProjectHomeCopy.createProject),
```

- [ ] **Step 6: Replace empty state copy**

Replace:

```dart
                        const Expanded(
                          child: Center(child: Text('No projects yet')),
                        )
```

with:

```dart
                        Expanded(
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.folder_open_outlined,
                                  size: 28,
                                  color: WorkbenchPalette.mutedForeground,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  ProjectHomeCopy.noProjects,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  ProjectHomeCopy.noProjectsMessage,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        color:
                                            WorkbenchPalette.mutedForeground,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        )
```

- [ ] **Step 7: Replace project row metadata and menu copy**

In the `ListTile` subtitle `Text`, replace the English interpolation:

```dart
                                      '${entry.imageCount} images - '
                                      '${entry.confirmedImageCount} confirmed - '
                                      '${entry.errorImageCount} errors',
```

with:

```dart
                                      ProjectHomeCopy.projectSummary(
                                        images: entry.imageCount,
                                        confirmed: entry.confirmedImageCount,
                                        errors: entry.errorImageCount,
                                      ),
```

Replace:

```dart
                                      tooltip: 'Project actions',
```

with:

```dart
                                      tooltip: ProjectHomeCopy.projectActions,
```

Replace menu item children:

```dart
                                          child: const Text('Rename'),
```

with:

```dart
                                          child: const Text(
                                            ProjectHomeCopy.rename,
                                          ),
```

and:

```dart
                                          child: const Text('Delete'),
```

with:

```dart
                                          child: const Text(
                                            ProjectHomeCopy.delete,
                                          ),
```

- [ ] **Step 8: Replace create fallback name**

In `_createProject`, replace:

```dart
        ? 'BBox Project'
```

with:

```dart
        ? ProjectHomeCopy.defaultProjectName
```

- [ ] **Step 9: Replace rename dialog copy**

In `_renameProject`, replace:

```dart
            title: const Text('Rename project'),
```

with:

```dart
            title: const Text(ProjectHomeCopy.renameTitle),
```

Replace field label:

```dart
                labelText: 'Project name',
```

with:

```dart
                labelText: ProjectHomeCopy.projectName,
```

Replace action labels:

```dart
                child: const Text('Cancel'),
```

with:

```dart
                child: const Text(ProjectHomeCopy.cancel),
```

and:

```dart
                child: const Text('Rename'),
```

with:

```dart
                child: const Text(ProjectHomeCopy.renameConfirm),
```

- [ ] **Step 10: Replace delete dialog copy**

In `_deleteProject`, replace:

```dart
            title: Text('Delete $name?'),
            content: const Text(
              'This removes the internal project data. Source images will not be deleted.',
            ),
```

with:

```dart
            title: const Text(ProjectHomeCopy.deleteTitle),
            content: const Text(ProjectHomeCopy.deleteMessage),
```

Replace action labels:

```dart
                child: const Text('Cancel'),
```

with:

```dart
                child: const Text(ProjectHomeCopy.cancel),
```

and:

```dart
                child: const Text('Delete'),
```

with:

```dart
                child: const Text(ProjectHomeCopy.delete),
```

- [ ] **Step 11: Replace project action error copy**

Replace:

```dart
                            'Project action failed. $_error',
```

with:

```dart
                            ProjectHomeCopy.actionFailed(_error!),
```

- [ ] **Step 12: Update app title**

In `lib/ui/bbox_app.dart`, add:

```dart
import 'project_home_copy.dart';
```

Replace:

```dart
      title: 'Bounding Box Labeler',
```

with:

```dart
      title: ProjectHomeCopy.appTitle,
```

- [ ] **Step 13: Run project home tests**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\project_home_widget_test.dart test\widget_test.dart
```

Expected: PASS for updated project-home tests.

- [ ] **Step 14: Commit or record skipped commit**

Run:

```powershell
git rev-parse --show-toplevel
```

If it succeeds:

```powershell
git add lib\ui\project_home_copy.dart lib\ui\start_screen.dart lib\ui\bbox_app.dart test\ui\project_home_widget_test.dart test\widget_test.dart
git commit -m "feat: localize project home"
```

If it fails with `not a git repository`, record this skipped commit message in task notes:

```text
Skipped commit: feat: localize project home
```

---

### Task 3: Shared Professional Radii And Workbench Korean Tooltips

**Files:**
- Modify: `lib/ui/app_theme.dart`
- Modify: `lib/ui/workbench_copy.dart`
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: current `WorkbenchPalette`, `WorkbenchCopy`, workbench widget keys.
- Produces: shared radii constants, Korean undo/redo tooltips, reduced pill-like shapes.

- [ ] **Step 1: Add failing workbench tooltip and radius assertions**

In `test/ui/workbench_widget_test.dart`, add this test after `top bar presents project context and global actions`:

```dart
    testWidgets('top bar uses Korean undo redo tooltips', (tester) async {
      final controller = AppController();
      controller.createProject('demo');

      await tester.pumpWidget(_app(controller));

      final undoButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.undo),
      );
      final redoButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.redo),
      );

      expect(undoButton.tooltip, '실행 취소');
      expect(redoButton.tooltip, '다시 실행');
    });
```

Add this test after `desktop workbench gives queue and inspector more room`:

```dart
    testWidgets('image queue rows use restrained desktop radius', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());

      await tester.pumpWidget(_app(controller));

      final rowMaterial = tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(const ValueKey('image-row-1')),
              matching: find.byType(Material),
            )
            .first,
      );
      final borderRadius = rowMaterial.borderRadius! as BorderRadius;
      expect(borderRadius.topLeft.x, 6);
      expect(borderRadius.topRight.x, 6);
      expect(borderRadius.bottomLeft.x, 6);
      expect(borderRadius.bottomRight.x, 6);
    });
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart
```

Expected: FAIL because undo and redo tooltips are still English. The radius assertion may pass only after the implementation if the current row radius is `8`.

- [ ] **Step 3: Add shared radius constants**

In `lib/ui/app_theme.dart`, after `BboxAppTheme`, add:

```dart
class AppRadii {
  const AppRadii._();

  static const button = 4.0;
  static const field = 4.0;
  static const badge = 4.0;
  static const row = 6.0;
  static const panel = 6.0;
  static const large = 8.0;
}
```

- [ ] **Step 4: Apply restrained Material shape defaults**

In `BboxAppTheme.materialTheme`, add these properties inside `base.copyWith(...)`:

```dart
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.button),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.button),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.button),
          ),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.field),
            ),
          ),
        ),
      ),
```

Then in the existing `inputDecorationTheme`, replace every `BorderRadius.circular(8)` with:

```dart
BorderRadius.circular(AppRadii.field)
```

- [ ] **Step 5: Add Korean undo redo copy**

In `lib/ui/workbench_copy.dart`, after `saveProjectTooltip`, add:

```dart
  static const undo = '실행 취소';
  static const redo = '다시 실행';
```

- [ ] **Step 6: Replace workbench top bar tooltips**

In `lib/ui/workbench_screen.dart`, replace:

```dart
                      tooltip: 'Undo',
```

with:

```dart
                      tooltip: WorkbenchCopy.undo,
```

Replace:

```dart
                      tooltip: 'Redo',
```

with:

```dart
                      tooltip: WorkbenchCopy.redo,
```

- [ ] **Step 7: Replace exaggerated workbench radii**

In `lib/ui/workbench_screen.dart`, make these exact replacements:

```dart
BorderRadius.circular(999)
```

to:

```dart
BorderRadius.circular(AppRadii.badge)
```

Replace image queue row radii:

```dart
BorderRadius.circular(8)
```

in `_ImageQueueRow` with:

```dart
BorderRadius.circular(AppRadii.row)
```

Replace canvas tool button shape:

```dart
RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))
```

with:

```dart
RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(AppRadii.button),
)
```

Replace `_ToolbarGroup` radius:

```dart
BorderRadius.circular(8)
```

with:

```dart
BorderRadius.circular(AppRadii.panel)
```

Replace `_BoxRow`, selected details, and quick label chip radii:

```dart
BorderRadius.circular(8)
BorderRadius.circular(7)
BorderRadius.circular(5)
```

with the closest matching shared values:

```dart
BorderRadius.circular(AppRadii.row)
BorderRadius.circular(AppRadii.button)
BorderRadius.circular(AppRadii.badge)
```

Keep `_resizeHandleRadius = 2.0` and overlay badge painter radius `4`; those are canvas affordances and already restrained.

- [ ] **Step 8: Run workbench tests**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart
```

Expected: PASS.

- [ ] **Step 9: Commit or record skipped commit**

Run:

```powershell
git rev-parse --show-toplevel
```

If it succeeds:

```powershell
git add lib\ui\app_theme.dart lib\ui\workbench_copy.dart lib\ui\workbench_screen.dart test\ui\workbench_widget_test.dart
git commit -m "style: align workbench controls with desktop radii"
```

If it fails with `not a git repository`, record this skipped commit message in task notes:

```text
Skipped commit: style: align workbench controls with desktop radii
```

---

### Task 4: Final Copy Scan And Regression Verification

**Files:**
- Modify: only files needed to fix failures found by scan or tests.
- Test: all touched tests and analyzer.

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: verified consistency pass with no obvious visible English leftovers in project home or workbench top-level controls.

- [ ] **Step 1: Scan UI files for known English leftovers**

Run:

```powershell
Select-String -Path lib\ui\*.dart -Pattern "'Bounding Box Labeler'|'Project name'|'New project'|'No projects yet'|'Project actions'|'Rename'|'Delete'|'Cancel'|'Undo'|'Redo'|'Project action failed'"
```

Expected: no matches in visible UI copy. Matches in test descriptions or comments are acceptable only outside `lib/ui`.

- [ ] **Step 2: Fix any scan matches**

If the scan finds a visible UI string in `lib/ui`, replace it with the exact Korean copy from `ProjectHomeCopy` or `WorkbenchCopy`.

Use these replacements:

```text
Bounding Box Labeler -> 프로젝트 홈 for visible home title, BBox 라벨러 for app title
Project name -> 프로젝트 이름
New project -> 만들기
No projects yet -> 프로젝트가 없습니다
Project actions -> 프로젝트 작업
Rename -> 이름 변경 or 변경 in confirm button
Delete -> 삭제
Cancel -> 취소
Undo -> 실행 취소
Redo -> 다시 실행
Project action failed. -> 프로젝트 작업을 완료하지 못했습니다. 다시 시도하세요.
```

- [ ] **Step 3: Run focused tests**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\project_home_widget_test.dart test\widget_test.dart test\ui\workbench_widget_test.dart
```

Expected: PASS.

- [ ] **Step 4: Run analyzer**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat analyze
```

Expected: PASS with no new errors.

- [ ] **Step 5: Run full test suite**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test
```

Expected: PASS. If the full suite is too slow or blocked by environment configuration, record the exact command output and do not claim full-suite success.

- [ ] **Step 6: Commit or record skipped commit**

Run:

```powershell
git rev-parse --show-toplevel
```

If it succeeds and there were final fixes:

```powershell
git add lib test
git commit -m "chore: verify home workbench consistency"
```

If it fails with `not a git repository`, record this skipped commit message in task notes:

```text
Skipped commit: chore: verify home workbench consistency
```

---

## Self-Review

Spec coverage:

- Korean-only visible project home copy is covered by Tasks 1 and 2.
- Shared project home and workbench visual rules are covered by Tasks 2 and 3.
- Reduced roundness is covered by Task 3.
- Workbench English undo/redo tooltips are covered by Task 3.
- No model, export, or canvas behavior changes are included.
- Verification and English-copy scan are covered by Task 4.

Placeholder scan:

- The plan contains no placeholder markers or unspecified deferred-work steps.
- Every test and implementation step names the exact files and code to add or replace.

Type consistency:

- `ProjectHomeCopy` is introduced in Task 2 before use in `StartScreen` and `BboxApp`.
- `AppRadii` is introduced in Task 3 before use in `WorkbenchScreen`.
- `WorkbenchCopy.undo` and `WorkbenchCopy.redo` are introduced before use in top bar tooltips.
