# Orange Toolbar Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply an orange amber primary color and clean up top, center, and quick-label toolbar alignment so selected states and command groups are visually clear.

**Architecture:** Keep all changes in the Flutter UI layer. Reuse `WorkbenchPalette`, `AppRadii`, `WorkbenchCopy`, and existing workbench widgets rather than introducing a new design system.

**Tech Stack:** Flutter, Dart, Material widgets, FORUI theme bridge, `flutter_test`.

## Global Constraints

- Main accent is orange amber: `accent #D97706`, `accentSoft #FFF3E0`, `accentStrong #B45309`, `accentBorder #F59E0B`.
- Selected states must not use black/dark command styling.
- Top app bar groups must read as context, status, document actions, edit utilities.
- Center toolbars must share left edge, height, padding, and border rhythm.
- Bottom quick-label chips must have consistent row/chip gaps and selected styling.
- Do not change annotation models, canvas coordinate math, detector, export, or project storage behavior.
- Keep changes inside `lib/ui` and related widget tests.
- This workspace is not a git repository; skip commit steps if `git rev-parse --show-toplevel` fails.

---

## File Structure

- Modify `lib/ui/app_theme.dart`: update orange palette and add helper colors if needed.
- Modify `lib/ui/workbench_screen.dart`: update selected styles, app bar grouping, toolbar alignment, and quick-label chip layout.
- Modify `test/ui/workbench_widget_test.dart`: add visual-state tests for orange selection, top bar groups, and quick-label selected styling.
- Modify `test/widget_test.dart` only if theme assertions require it.

---

### Task 1: Orange Palette And Selected-State Tests

**Files:**
- Modify: `lib/ui/app_theme.dart`
- Modify: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Produces: orange palette constants and tests that enforce selected states do not resolve to black.

- [ ] **Step 1: Add failing palette test**

In `test/ui/workbench_widget_test.dart`, add a test near existing visual shell tests:

```dart
    testWidgets('workbench palette uses orange accent colors', (tester) async {
      expect(WorkbenchPalette.accent, const Color(0xffd97706));
      expect(WorkbenchPalette.accentSoft, const Color(0xfffff3e0));
      expect(WorkbenchPalette.accentStrong, const Color(0xffb45309));
      expect(WorkbenchPalette.accentBorder, const Color(0xfff59e0b));
    });
```

If `WorkbenchPalette` is not imported, add:

```dart
import 'package:bbox_labeler/ui/app_theme.dart';
```

- [ ] **Step 2: Add selected toolbar style test**

Add this test after `canvas toolbar exposes select draw and pan tools`:

```dart
    testWidgets('selected canvas tool uses orange selected styling', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());

      await tester.pumpWidget(_app(controller));

      final selectedButton = tester.widget<TextButton>(
        find.widgetWithText(TextButton, WorkbenchCopy.selectMoveTool),
      );
      final style = selectedButton.style!;
      expect(
        style.backgroundColor?.resolve(<WidgetState>{}),
        WorkbenchPalette.accent,
      );
      expect(
        style.foregroundColor?.resolve(<WidgetState>{}),
        Colors.white,
      );
    });
```

- [ ] **Step 3: Run red test**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart
```

Expected: FAIL because palette is still teal and selected canvas tool still uses Material primary container styling.

- [ ] **Step 4: Update palette**

In `lib/ui/app_theme.dart`, replace the current accent colors and add new strong/border constants:

```dart
  static const accent = Color(0xffd97706);
  static const accentSoft = Color(0xfffff3e0);
  static const accentStrong = Color(0xffb45309);
  static const accentBorder = Color(0xfff59e0b);
```

- [ ] **Step 5: Update `_CanvasToolButton` selected styling**

In `lib/ui/workbench_screen.dart`, change the selected `TextButton.styleFrom(...)` values to:

```dart
          foregroundColor: selected
              ? Colors.white
              : colorScheme.onSurfaceVariant,
          backgroundColor: selected
              ? WorkbenchPalette.accent
              : Colors.transparent,
          side: selected
              ? const BorderSide(color: WorkbenchPalette.accentStrong)
              : BorderSide.none,
```

Keep existing padding and shape unless Task 2 changes them.

- [ ] **Step 6: Run green test**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart
```

Expected: PASS.

---

### Task 2: Top And Center Toolbar Alignment

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: orange palette from Task 1.
- Produces: grouped top app bar, aligned center toolbar groups, stable keys for tests.

- [ ] **Step 1: Add top app bar grouping test**

In `test/ui/workbench_widget_test.dart`, add after `top bar presents project context and global actions`:

```dart
    testWidgets('top bar groups context status document and edit actions', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());

      await tester.pumpWidget(_app(controller));

      expect(find.byKey(const ValueKey('top-context-group')), findsOneWidget);
      expect(find.byKey(const ValueKey('top-status-group')), findsOneWidget);
      expect(find.byKey(const ValueKey('top-document-actions')), findsOneWidget);
      expect(find.byKey(const ValueKey('top-edit-actions')), findsOneWidget);
      expect(find.byKey(const ValueKey('save-status-badge')), findsOneWidget);
    });
```

- [ ] **Step 2: Add center toolbar alignment test**

Add after `center toolbar separates automation editing and view groups`:

```dart
    testWidgets('center toolbar groups share a left edge and height rhythm', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(_project());

      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_app(controller));

      final automation = tester.getRect(
        find.byKey(const ValueKey('center-automation-toolbar')),
      );
      final editing = tester.getRect(
        find.byKey(const ValueKey('center-edit-toolbar')),
      );
      final view = tester.getRect(
        find.byKey(const ValueKey('center-view-toolbar')),
      );

      expect((automation.left - editing.left).abs(), lessThanOrEqualTo(1));
      expect((editing.height - view.height).abs(), lessThanOrEqualTo(1));
    });
```

- [ ] **Step 3: Run red test**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart
```

Expected: FAIL because the new top group keys do not exist and center group heights may differ.

- [ ] **Step 4: Refactor app bar grouping**

In `WorkbenchScreen.build`, keep the existing `AppBar` but structure `leading`, `title`, and `actions` like this:

- `leadingWidth`: enough for project home button.
- `leading`: wrap the project home button in `KeyedSubtree(key: ValueKey('top-context-group'), ...)`.
- `title`: project name only, truncating.
- `actions`: a row containing:
  - `KeyedSubtree(key: ValueKey('top-status-group'), child: _SaveStatusIndicator(...))`
  - separator
  - `KeyedSubtree(key: ValueKey('top-document-actions'), child: Row(... image add, export ...))`
  - separator
  - `KeyedSubtree(key: ValueKey('top-edit-actions'), child: Row(... save, undo, redo ...))`

Use a small private widget for separators if useful:

```dart
class _ToolbarSeparator extends StatelessWidget {
  const _ToolbarSeparator();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 24,
      child: VerticalDivider(width: 16, thickness: 1),
    );
  }
}
```

- [ ] **Step 5: Make document actions visually matched**

Ensure `이미지 추가` and `COCO 내보내기` are both `TextButton.icon` or both `OutlinedButton.icon` with the same minimum height and padding. Prefer `TextButton.icon` with orange foreground for primary document actions:

```dart
style: TextButton.styleFrom(
  foregroundColor: WorkbenchPalette.accentStrong,
  minimumSize: const Size(0, 36),
  padding: const EdgeInsets.symmetric(horizontal: 10),
)
```

- [ ] **Step 6: Align center toolbar as a column**

In `_ViewerPanelState._buildSelectedImage`, wrap center toolbars in a width-constrained `Align(alignment: Alignment.centerLeft, child: Column(...))` so automation and edit/view rows share the same left edge:

```dart
        Align(
          alignment: Alignment.centerLeft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CenterAutoBoxesToolbar(controller: controller),
              const SizedBox(height: 8),
              _CanvasActionToolbar(...),
            ],
          ),
        ),
```

Remove duplicated standalone toolbar calls if needed.

- [ ] **Step 7: Normalize `_ToolbarGroup` height**

Update `_ToolbarGroup` to enforce a minimum height:

```dart
child: ConstrainedBox(
  constraints: const BoxConstraints(minHeight: 48),
  child: Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    child: child,
  ),
),
```

- [ ] **Step 8: Run green test**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart
```

Expected: PASS.

---

### Task 3: Quick Label Strip Polish And Final Verification

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Modify: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: orange palette and toolbar grouping from Tasks 1-2.
- Produces: aligned quick-label chip styling and final verification.

- [ ] **Step 1: Add selected quick label style test**

In `test/ui/workbench_widget_test.dart`, add after `quick label chip assigns an existing label to selected box`:

```dart
    testWidgets('selected quick label avoids black selected styling', (
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
      controller.selectBox('box-1');

      await tester.pumpWidget(_app(controller));

      final chip = tester.widget<Container>(
        find
            .descendant(
              of: find.byKey(const ValueKey('quick-label-1')),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = chip.decoration! as BoxDecoration;
      expect(decoration.color, isNot(Colors.black));
    });
```

- [ ] **Step 2: Run red or current-state test**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart
```

Expected: PASS or FAIL depending on current chip color; if PASS, keep the test as regression coverage.

- [ ] **Step 3: Tighten quick label chip dimensions**

In `_QuickLabelChip`, keep the existing behavior but make the strip more aligned:

- chip height: `34` or `36`, consistent across all chips,
- shortcut badge size: consistent square,
- fixed gap: `6`,
- selected border uses `WorkbenchPalette.accentBorder` if the label color is too low-contrast, otherwise label color is acceptable.

Do not change label assignment behavior.

- [ ] **Step 4: Run focused tests**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart test\widget_test.dart
```

Expected: PASS.

- [ ] **Step 5: Run analyzer and full suite**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat analyze
C:\tools\flutter\bin\flutter.bat test
```

Expected: both PASS.

- [ ] **Step 6: Build Windows**

Run:

```powershell
C:\tools\flutter\bin\flutter.bat build windows
```

Expected: PASS and produce `build\windows\x64\runner\Release\bbox_labeler.exe`.

---

## Self-Review

- Palette requirement maps to Task 1.
- Top app bar grouping and center toolbar alignment map to Task 2.
- Bottom quick-label strip maps to Task 3.
- Existing behavior preservation is covered by focused workbench tests and full `flutter test`.
- No task touches annotation, export, detector, storage, or viewport transform files.

