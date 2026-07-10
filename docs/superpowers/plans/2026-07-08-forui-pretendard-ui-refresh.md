# FORUI Pretendard UI Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply Pretendard typography and a FORUI-backed visual refresh to the Flutter desktop labeling app without changing annotation behavior.

**Architecture:** Add a focused theme module that creates one FORUI desktop theme and derives a Material theme from it. Keep the existing Material/custom canvas widgets, but wrap the app in `FTheme`, `FToaster`, and `FTooltipGroup`, then restyle high-visibility surfaces and controls through small local wrappers.

**Tech Stack:** Flutter 3.44.4, Dart 3.12.2, FORUI 0.23.0, Material interoperability via `FThemeData.toApproximateMaterialTheme()`, local Pretendard font asset.

## Global Constraints

- Preserve project, import, annotation, save, and export behavior.
- Keep canvas coordinate and overlay behavior unchanged except for colors and surrounding chrome.
- Do not rewrite project storage, COCO export, detector behavior, or data models.
- Use `C:\tools\flutter\bin\flutter.bat` for local Flutter commands because `flutter` is not on PATH.
- The workspace at `C:\workspace\bbox` is not a Git repository, so commit steps are replaced by explicit verification and changed-file reporting.
- Use FORUI 0.23.0 because Flutter 3.44.4 satisfies FORUI 0.22.0+ requirements and the package is already in the local Pub cache.

---

## File Structure

- Modify `pubspec.yaml`: add `forui: ^0.23.0` and register `Pretendard` font assets.
- Create `assets/fonts/pretendard/PretendardVariable.ttf`: local font file used by Flutter.
- Create `lib/ui/app_theme.dart`: owns FORUI theme creation, Material bridge theme, app font constants, and shared workbench colors.
- Modify `lib/ui/bbox_app.dart`: wrap the app in FORUI theme providers and use the derived Material theme.
- Modify `lib/ui/start_screen.dart`: improve first-run project home layout with FORUI buttons and theme tokens while preserving keys and controller calls.
- Modify `lib/ui/workbench_screen.dart`: restyle workbench shell, toolbar actions, panel surfaces, badges, progress bars, and quick labels; preserve all existing behavior and keys.
- Modify `lib/ui/label_management_popover.dart`: restyle the popover with FORUI buttons and theme colors; preserve validation.
- Modify `test/widget_test.dart`: add focused assertions for theme wiring and font usage before implementation.

---

### Task 1: Theme Dependency, Font Asset, and App Theme

**Files:**
- Modify: `C:\workspace\bbox\pubspec.yaml`
- Create: `C:\workspace\bbox\assets\fonts\pretendard\PretendardVariable.ttf`
- Create: `C:\workspace\bbox\lib\ui\app_theme.dart`
- Modify: `C:\workspace\bbox\lib\ui\bbox_app.dart`
- Test: `C:\workspace\bbox\test\widget_test.dart`

**Interfaces:**
- Produces: `class BboxAppTheme`, `BboxAppTheme.foruiTheme`, `BboxAppTheme.materialTheme`, `BboxAppTheme.fontFamily`, `class WorkbenchPalette`
- Consumes: FORUI `FThemes.zinc.light.desktop`, `FTheme`, `FToaster`, `FTooltipGroup`, and `toApproximateMaterialTheme()`

- [ ] **Step 1: Write the failing root theme test**

Add this import and test to `C:\workspace\bbox\test\widget_test.dart`:

```dart
import 'package:forui/forui.dart';

testWidgets('app root provides FORUI theme with Pretendard typography', (
  tester,
) async {
  final tempDir = Directory.systemTemp.createTempSync('bbox_theme_test');
  addTearDown(() => tempDir.deleteSync(recursive: true));
  final controller = AppController(
    projectLibrary: MemoryProjectLibrary(
      rootPath: tempDir.path,
      fixedId: 'theme-project',
    ),
  );

  await tester.pumpWidget(BboxApp(controller: controller));
  await tester.pump();

  final context = tester.element(find.byKey(const ValueKey('project-home')));
  final foruiTheme = FTheme.of(context);
  final materialTheme = Theme.of(context);

  expect(foruiTheme.typography.body.fontFamily, 'Pretendard');
  expect(foruiTheme.typography.display.fontFamily, 'Pretendard');
  expect(materialTheme.textTheme.bodyMedium?.fontFamily, 'Pretendard');
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\widget_test.dart --plain-name "app root provides FORUI theme with Pretendard typography"
```

Expected: FAIL because `package:forui/forui.dart` is not a dependency yet or because `FTheme` is not present.

- [ ] **Step 3: Add FORUI dependency and Pretendard font registration**

In `pubspec.yaml`, add:

```yaml
dependencies:
  forui: ^0.23.0
```

Under `flutter:`, add:

```yaml
  fonts:
    - family: Pretendard
      fonts:
        - asset: assets/fonts/pretendard/PretendardVariable.ttf
          weight: 400
```

Create `assets/fonts/pretendard/` and place `PretendardVariable.ttf` there. Use the official Pretendard variable font file if it is already available locally; otherwise download it from the official Pretendard GitHub release source during implementation.

- [ ] **Step 4: Create app theme module**

Create `lib/ui/app_theme.dart` with:

```dart
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

class BboxAppTheme {
  const BboxAppTheme._();

  static const fontFamily = 'Pretendard';

  static final FThemeData foruiTheme = _buildForuiTheme();

  static ThemeData get materialTheme {
    final base = foruiTheme.toApproximateMaterialTheme();
    return base.copyWith(
      scaffoldBackgroundColor: WorkbenchPalette.appBackground,
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: WorkbenchPalette.panel,
        foregroundColor: WorkbenchPalette.foreground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
      dividerTheme: base.dividerTheme.copyWith(
        color: WorkbenchPalette.border,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: WorkbenchPalette.panel,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: WorkbenchPalette.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: WorkbenchPalette.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(
            color: WorkbenchPalette.accent,
            width: 1.4,
          ),
        ),
      ),
    );
  }

  static FThemeData _buildForuiTheme() {
    final base = FThemes.zinc.light.desktop;
    final typeface = FTypeface.inherit(
      colors: base.colors,
      touch: false,
      fontFamily: fontFamily,
      fontFamilyFallback: const ['Malgun Gothic', 'Segoe UI'],
    );
    return base.copyWith(
      typography: base.typography.copyWith(display: typeface, body: typeface),
    );
  }
}

class WorkbenchPalette {
  const WorkbenchPalette._();

  static const appBackground = Color(0xfff6f7f9);
  static const panel = Color(0xffffffff);
  static const panelMuted = Color(0xfff9fafb);
  static const border = Color(0xffd7dde4);
  static const borderStrong = Color(0xffb9c3cf);
  static const foreground = Color(0xff181c20);
  static const mutedForeground = Color(0xff66717f);
  static const accent = Color(0xff0f766e);
  static const accentSoft = Color(0xffdff5f1);
  static const warning = Color(0xffb45309);
  static const warningSoft = Color(0xfffff3d6);
  static const danger = Color(0xffb42318);
  static const dangerSoft = Color(0xffffe4e0);
}
```

- [ ] **Step 5: Wrap app with FORUI theme**

Update `lib/ui/bbox_app.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'app_controller.dart';
import 'app_theme.dart';
import 'start_screen.dart';
import 'workbench_screen.dart';
```

Replace the `MaterialApp` theme block with:

```dart
return MaterialApp(
  title: 'Bounding Box Labeler',
  theme: BboxAppTheme.materialTheme,
  builder: (context, child) => FTheme(
    data: BboxAppTheme.foruiTheme,
    child: FToaster(child: FTooltipGroup(child: child!)),
  ),
  home: AnimatedBuilder(
    animation: _controller,
    builder: (context, _) {
      if (!_controller.hasProject) {
        return StartScreen(controller: _controller);
      }
      return WorkbenchScreen(controller: _controller);
    },
  ),
);
```

- [ ] **Step 6: Resolve dependencies**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat pub get
```

Expected: exit code 0 and `forui 0.23.0` present in `pubspec.lock`.

- [ ] **Step 7: Run test to verify it passes**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\widget_test.dart --plain-name "app root provides FORUI theme with Pretendard typography"
```

Expected: PASS.

---

### Task 2: Project Home Visual Refresh

**Files:**
- Modify: `C:\workspace\bbox\lib\ui\start_screen.dart`
- Test: `C:\workspace\bbox\test\widget_test.dart`

**Interfaces:**
- Consumes: `BboxAppTheme.materialTheme`, `WorkbenchPalette`, FORUI `FButton`
- Produces: refreshed project home preserving keys `project-home`, `new-project-name`, `create-project`, and `project-entry-*`

- [ ] **Step 1: Write the failing project-home visual test**

Add to `test/widget_test.dart`:

```dart
testWidgets('project home uses Pretendard and FORUI primary action', (
  tester,
) async {
  final tempDir = Directory.systemTemp.createTempSync('bbox_home_visual_test');
  addTearDown(() => tempDir.deleteSync(recursive: true));
  final controller = AppController(
    projectLibrary: MemoryProjectLibrary(
      rootPath: tempDir.path,
      fixedId: 'home-visual-project',
    ),
  );

  await tester.pumpWidget(BboxApp(controller: controller));
  await tester.pump();
  await _pumpRealAsync(tester);

  expect(find.byKey(const ValueKey('project-home-shell')), findsOneWidget);
  expect(find.byKey(const ValueKey('create-project-forui')), findsOneWidget);

  final title = tester.widget<Text>(find.text('Bounding Box Labeler'));
  expect(title.style?.fontFamily, 'Pretendard');
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\widget_test.dart --plain-name "project home uses Pretendard and FORUI primary action"
```

Expected: FAIL because `project-home-shell` and `create-project-forui` are not present.

- [ ] **Step 3: Restyle project home**

In `start_screen.dart`, import:

```dart
import 'package:forui/forui.dart';

import 'app_theme.dart';
```

Add `key: const ValueKey('project-home-shell')` to the main padded shell and replace the create button with:

```dart
FButton(
  key: const ValueKey('create-project-forui'),
  onPress: _createProject,
  prefix: const Icon(Icons.add, size: 18),
  child: const Text('New project'),
)
```

Keep an invisible or outer compatibility key only if needed by existing tests:

```dart
KeyedSubtree(
  key: const ValueKey('create-project'),
  child: FButton(...),
)
```

Set the title style explicitly:

```dart
style: Theme.of(context).textTheme.headlineMedium?.copyWith(
  fontFamily: BboxAppTheme.fontFamily,
  fontWeight: FontWeight.w800,
  color: WorkbenchPalette.foreground,
),
```

Use `WorkbenchPalette.appBackground` for the scaffold and `WorkbenchPalette.panel` for project list rows.

- [ ] **Step 4: Run existing and new project-home tests**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\widget_test.dart
```

Expected: PASS for project creation and home return flows.

---

### Task 3: Workbench Surface, Toolbar, and Status Refresh

**Files:**
- Modify: `C:\workspace\bbox\lib\ui\workbench_screen.dart`
- Test: `C:\workspace\bbox\test\widget_test.dart`

**Interfaces:**
- Consumes: `WorkbenchPalette`, FORUI `FButton`, existing `AppController`
- Produces: refreshed workbench preserving keys `workbench-top-bar`, `workbench-shell`, `project-home-action`, `save-project`, `export-coco`, `confirm-image`, and canvas keys

- [ ] **Step 1: Write the failing workbench visual test**

Add to `test/widget_test.dart`:

```dart
testWidgets('workbench exposes refreshed shell and FORUI toolbar actions', (
  tester,
) async {
  final tempDir = Directory.systemTemp.createTempSync('bbox_workbench_visual');
  addTearDown(() => tempDir.deleteSync(recursive: true));
  final controller = AppController(
    projectLibrary: MemoryProjectLibrary(
      rootPath: tempDir.path,
      fixedId: 'workbench-visual-project',
    ),
  );

  await tester.pumpWidget(BboxApp(controller: controller));
  await tester.pump();
  await _pumpRealAsync(tester);
  await tester.enterText(
    find.byKey(const ValueKey('new-project-name')),
    'Workbench Visual',
  );
  await tester.tap(find.byKey(const ValueKey('create-project')));
  await tester.pump();
  await _pumpRealAsync(tester);

  expect(find.byKey(const ValueKey('workbench-forui-toolbar')), findsOneWidget);
  expect(find.byKey(const ValueKey('save-status-badge')), findsOneWidget);
  expect(find.byKey(const ValueKey('workbench-shell')), findsOneWidget);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\widget_test.dart --plain-name "workbench exposes refreshed shell and FORUI toolbar actions"
```

Expected: FAIL because `workbench-forui-toolbar` and `save-status-badge` are not present.

- [ ] **Step 3: Import theme and FORUI in workbench**

Add imports:

```dart
import 'package:forui/forui.dart';

import 'app_theme.dart';
```

Replace top constants:

```dart
const _workbenchBackground = WorkbenchPalette.appBackground;
const _workbenchPanel = WorkbenchPalette.panel;
const _workbenchBorder = WorkbenchPalette.border;
```

- [ ] **Step 4: Add toolbar marker and FORUI buttons**

Wrap the app bar actions row content with:

```dart
KeyedSubtree(
  key: const ValueKey('workbench-forui-toolbar'),
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      // existing action widgets converted where low-risk
    ],
  ),
)
```

Convert low-risk text toolbar actions to `FButton`:

```dart
FButton(
  key: const ValueKey('export-coco-forui'),
  onPress: busyForProjectMutation ? null : () => _showExportWarnings(context),
  size: FButtonSizeVariant.sm,
  variant: FButtonVariant.outline,
  prefix: const Icon(Icons.ios_share, size: 16),
  child: const Text(WorkbenchCopy.cocoExport),
)
```

Keep the existing `export-coco` key by wrapping:

```dart
KeyedSubtree(
  key: const ValueKey('export-coco'),
  child: FButton(...),
)
```

- [ ] **Step 5: Restyle save status as badge**

In `_SaveStatusIndicator`, add:

```dart
key: const ValueKey('save-status-badge'),
```

to the outer visible container and use:

```dart
DecoratedBox(
  decoration: BoxDecoration(
    color: color.withAlpha(22),
    borderRadius: BorderRadius.circular(999),
    border: Border.all(color: color.withAlpha(80)),
  ),
  child: Padding(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    child: Row(...),
  ),
)
```

Keep the existing status-specific keys on inner rows so old tests still find `save-status-saved`, `save-status-saving`, and `save-status-failed`.

- [ ] **Step 6: Restyle panel surfaces and rows**

Update `_PanelSurface` decoration:

```dart
decoration: const BoxDecoration(
  color: WorkbenchPalette.panel,
  border: Border(right: BorderSide(color: WorkbenchPalette.border)),
)
```

Use `WorkbenchPalette.panelMuted`, `accentSoft`, and `border` for selected image rows, box rows, empty states, and quick label chips while keeping all keys and callbacks unchanged.

- [ ] **Step 7: Run workbench widget tests**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\widget_test.dart
```

Expected: PASS.

---

### Task 4: Label Management Popover Refresh

**Files:**
- Modify: `C:\workspace\bbox\lib\ui\label_management_popover.dart`
- Test: `C:\workspace\bbox\test\widget_test.dart`

**Interfaces:**
- Consumes: `WorkbenchPalette`, FORUI `FButton`
- Produces: refreshed popover preserving keys `label-management-popover`, `label-name-input`, `label-shortcut-input`, `create-managed-label`, `update-managed-label`, and `managed-label-row-*`

- [ ] **Step 1: Write the failing label popover visual test**

Add to `test/widget_test.dart`:

```dart
testWidgets('label management popover uses refreshed action button', (
  tester,
) async {
  final tempDir = Directory.systemTemp.createTempSync('bbox_label_visual');
  addTearDown(() => tempDir.deleteSync(recursive: true));
  final controller = AppController(
    projectLibrary: MemoryProjectLibrary(
      rootPath: tempDir.path,
      fixedId: 'label-visual-project',
    ),
  );

  await tester.pumpWidget(BboxApp(controller: controller));
  await tester.pump();
  await _pumpRealAsync(tester);
  await tester.enterText(
    find.byKey(const ValueKey('new-project-name')),
    'Label Visual',
  );
  await tester.tap(find.byKey(const ValueKey('create-project')));
  await tester.pump();
  await _pumpRealAsync(tester);

  await tester.tap(find.byKey(const ValueKey('open-label-management')));
  await tester.pump();

  expect(find.byKey(const ValueKey('label-management-popover')), findsOneWidget);
  expect(find.byKey(const ValueKey('create-managed-label-forui')), findsOneWidget);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\widget_test.dart --plain-name "label management popover uses refreshed action button"
```

Expected: FAIL because `create-managed-label-forui` is not present.

- [ ] **Step 3: Restyle popover**

Import:

```dart
import 'package:forui/forui.dart';

import 'app_theme.dart';
```

Change the `Material` surface to:

```dart
Material(
  key: const ValueKey('label-management-popover'),
  color: WorkbenchPalette.panel,
  elevation: 10,
  shadowColor: Colors.black.withAlpha(30),
  borderRadius: BorderRadius.circular(8),
  child: ...
)
```

Replace the create/update button with:

```dart
KeyedSubtree(
  key: ValueKey(isEditing ? 'update-managed-label' : 'create-managed-label'),
  child: FButton(
    key: ValueKey(
      isEditing
          ? 'update-managed-label-forui'
          : 'create-managed-label-forui',
    ),
    onPress: isEditing ? _update : _create,
    size: FButtonSizeVariant.sm,
    child: Text(isEditing ? '?섏젙' : '異붽?'),
  ),
)
```

Do not change `_validate`, `_submit`, or callback wiring.

- [ ] **Step 4: Run label popover test and full widget tests**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\widget_test.dart
```

Expected: PASS.

---

### Task 5: Full Verification and Visual Sanity

**Files:**
- Verify: `C:\workspace\bbox\pubspec.yaml`
- Verify: `C:\workspace\bbox\lib\ui\app_theme.dart`
- Verify: `C:\workspace\bbox\lib\ui\bbox_app.dart`
- Verify: `C:\workspace\bbox\lib\ui\start_screen.dart`
- Verify: `C:\workspace\bbox\lib\ui\workbench_screen.dart`
- Verify: `C:\workspace\bbox\lib\ui\label_management_popover.dart`
- Verify: `C:\workspace\bbox\test\widget_test.dart`

**Interfaces:**
- Consumes: completed Tasks 1-4
- Produces: verified UI refresh summary

- [ ] **Step 1: Format Dart files**

Run:

```powershell
& C:\tools\flutter\bin\dart.bat format lib\ui\app_theme.dart lib\ui\bbox_app.dart lib\ui\start_screen.dart lib\ui\workbench_screen.dart lib\ui\label_management_popover.dart test\widget_test.dart
```

Expected: exit code 0.

- [ ] **Step 2: Analyze**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat analyze
```

Expected: no errors.

- [ ] **Step 3: Run widget tests**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test
```

Expected: all tests pass.

- [ ] **Step 4: Build Windows app enough to catch asset registration errors**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat build windows --debug
```

Expected: build succeeds and includes the Pretendard font asset.

- [ ] **Step 5: Report changed files**

Run:

```powershell
Get-ChildItem -Path lib\ui,test,assets\fonts\pretendard -Recurse | Select-Object FullName, LastWriteTime
```

Expected: output includes only the intended source, test, and font files for this UI refresh. Include `pubspec.yaml`, `pubspec.lock`, the plan, and the spec in the final summary.
