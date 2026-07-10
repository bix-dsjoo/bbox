# Project Home And Workbench Consistency Design

Date: 2026-07-09

## Context

The app is a Flutter Windows desktop tool for creating object detection
bounding-box labels and exporting COCO JSON.

The workbench already has the stronger product structure:

- Korean operational copy through `WorkbenchCopy`.
- Pretendard and FORUI-backed theme setup.
- Three-panel labeling workspace.
- Save status, project-home navigation, image import, canvas tools, inspector,
  and quick label bar.

The project home is still visually and linguistically behind the workbench. It
uses English copy such as `Bounding Box Labeler`, `Project name`,
`New project`, `No projects yet`, `Rename`, and `Delete`. Its layout also feels
like a simple starter screen rather than the entry point of the same desktop
labeling product.

This pass should make the project home and the internal box-labeling screen feel
like one coherent Korean desktop tool.

## Goals

- Make all visible product UI copy Korean-first.
- Keep standard technical terms only where they are useful, such as `COCO`,
  `BBox`, and keyboard shortcut labels.
- Modernize the project home without making it a marketing page.
- Align project home and workbench visual rules: surfaces, borders, spacing,
  typography, status badges, list rows, and action hierarchy.
- Reduce overly rounded controls so the app feels like a professional desktop
  labeling tool.
- Preserve existing project, image import, annotation, save, return-home, and
  COCO export behavior.

## Non-Goals

- Do not change annotation domain models.
- Do not change bbox coordinates, canvas transforms, or COCO export rules.
- Do not add cloud, account, collaboration, or training features.
- Do not introduce a new navigation model.
- Do not replace the three-panel workbench.
- Do not create a decorative landing page.
- Do not expand into a full localization framework unless the current copy
  organization becomes a blocker.

## Recommended Direction

Use a shared desktop-tool design language and apply it to both screens.

The recommended approach is not a large UI rewrite. It is a consistency pass:

1. Normalize Korean copy.
2. Define compact shared visual rules.
3. Update project home to use the same product language as the workbench.
4. Adjust workbench details where it still differs from the shared rules.
5. Add focused widget tests for the new Korean copy and key layout states.

This fits the current codebase because the workbench already has a usable
structure and the app theme is already centralized in `lib/ui/app_theme.dart`.

## Product Tone

The app should feel like:

- a local Windows desktop production tool,
- quiet and work-focused,
- dense enough for repeated labeling,
- clear for first-time project setup,
- professional rather than playful.

The app should not feel like:

- a marketing landing page,
- a mobile-first consumer app,
- a decorative card grid,
- a casual toy interface,
- a one-color rounded SaaS mockup.

## Korean Copy Rules

All user-facing app copy should be Korean unless a technical term is clearer in
its original form.

Allowed technical terms:

- `COCO`
- `BBox` when referring to the product or technical concept
- keyboard shortcut labels such as `Ctrl+Enter`
- file extensions and file format labels

Recommended common terms:

- `프로젝트 홈`
- `새 프로젝트`
- `프로젝트 이름`
- `만들기`
- `이름 변경`
- `삭제`
- `취소`
- `이미지`
- `이미지 추가`
- `이미지 폴더`
- `이미지 파일`
- `검토 필요`
- `완료`
- `문제 있음`
- `라벨 필요`
- `저장됨`
- `저장 중`
- `저장 실패`
- `COCO 내보내기`

Avoid mixed-language labels such as:

- `Project name`
- `New project`
- `No projects yet`
- `Project actions`
- `Rename`
- `Delete`
- `Undo`
- `Redo`

For undo and redo, use Korean tooltips:

- `실행 취소`
- `다시 실행`

## Shape And Roundness Rules

The app currently reads too rounded in some controls. This makes it feel less
like a professional desktop production tool.

Use restrained corner radii:

- Buttons: `4px`.
- Text fields and menus: `4px`.
- Small badges: `4px`.
- List rows: `4px` to `6px`.
- Panels: `0px` at full-height screen edges, or `6px` only for contained
  surfaces.
- Large repeated cards: avoid where possible; if required, max `8px`.

Avoid:

- pill-shaped buttons,
- overly rounded project rows,
- floating rounded cards inside other surfaces,
- decorative shadows,
- soft consumer-app shapes.

Prefer:

- crisp borders,
- subtle selected-row background,
- a left accent bar for selection where useful,
- clear alignment,
- compact spacing,
- restrained status color.

Icon-only circular buttons are acceptable for compact toolbar tools only when
the button has a tooltip and the action is familiar, such as zoom, save, undo,
or redo.

## Shared Visual System

### Surfaces

- App background: very light neutral gray.
- Top bars and panels: white.
- Borders: 1px low-contrast gray.
- Section dividers: subtle and functional.
- Shadows: avoid for primary layout surfaces.

### Color

Use the current neutral palette in `WorkbenchPalette` as the base:

- `appBackground` for the app shell.
- `panel` for top bars and panels.
- `border` for separation.
- `foreground` for primary text.
- `mutedForeground` for secondary text.
- `accent` for primary actions and current selection.
- `danger` for destructive actions and blocking errors.
- `warning` for warnings.

Do not let the whole app become a single teal or mint surface. Accent color
should guide attention, not dominate the interface.

### Typography

- Use Pretendard app-wide.
- Project title and screen title should be medium-sized, not hero-scale.
- Panel titles should be compact and semibold.
- Metadata should use muted color and smaller text.
- Button labels should stay short.
- Do not use oversized empty-state headings.

### Density

The UI should support long labeling sessions.

- Top bar height: about `56px` to `64px`.
- Panel padding: `12px` to `16px`.
- Row height: compact desktop list density.
- Button height: about `34px` to `38px`.
- Avoid large vertical gaps unless separating major work zones.

## Project Home Design

### Purpose

The project home is a workspace hub. It should answer:

```text
어떤 프로젝트를 열거나 새로 만들까요?
```

It is not a landing page.

### Layout

Use a centered content column with a professional desktop width, but make the
internal structure match the workbench:

1. Header area.
2. New project action row.
3. Project list surface.
4. Error/status feedback.

Recommended header:

```text
프로젝트 홈
라벨링 프로젝트를 만들거나 이어서 작업하세요.
```

The supporting sentence should be short and action-oriented.

### New Project Row

Replace current English copy:

- `Project name` -> `프로젝트 이름`
- `New project` button -> `만들기`
- new-project concept or section label -> `새 프로젝트`
- default `BBox Project` -> `새 라벨링 프로젝트`

Recommended structure:

```text
[프로젝트 이름 입력] [만들기]
```

The button should use the primary accent color but restrained `4px` radius.

### Empty State

When there are no projects:

```text
프로젝트가 없습니다
새 프로젝트를 만들어 이미지 라벨링을 시작하세요.
```

Keep the primary action in the new-project row. Do not duplicate large CTAs.

### Project Rows

Project rows should feel like a desktop list, not rounded cards.

Each row should show:

- project name,
- image count,
- confirmed image count,
- error image count,
- last updated time,
- overflow menu.

Recommended metadata:

```text
이미지 128장 · 완료 80장 · 문제 7장
```

Recommended menu labels:

- `이름 변경`
- `삭제`

Recommended tooltip:

- `프로젝트 작업`

### Rename Dialog

Use Korean copy:

- title: `프로젝트 이름 변경`
- field label: `프로젝트 이름`
- cancel: `취소`
- confirm: `변경`

### Delete Dialog

Use Korean copy and reassure that original images remain untouched:

- title: `프로젝트 삭제`
- message: `내부 프로젝트 데이터만 삭제됩니다. 원본 이미지는 삭제되지 않습니다.`
- cancel: `취소`
- confirm: `삭제`

The destructive confirm button should use danger styling if available. It
should not look like the normal primary action.

## Workbench Consistency Adjustments

The workbench keeps its current structure:

```text
Top project bar
Left image queue | Center annotation canvas | Right workflow panel
Bottom quick label bar
```

### Top Bar

The top bar should align with project-home copy and restrained shape rules.

Keep:

- `프로젝트 홈`
- current project name,
- save status,
- image add action,
- save,
- undo/redo,
- `COCO 내보내기`.

Update remaining English tooltips:

- `Undo` -> `실행 취소`
- `Redo` -> `다시 실행`

Buttons should use compact shapes. Text buttons in the app bar should not look
like large rounded pills.

### Left Image Queue

The image queue already follows the right direction. Align row shape and state
display with project home rows.

Rules:

- Use compact rows.
- Keep filenames truncating cleanly.
- Use status text or a shared badge.
- Avoid large rounded card rows.
- Summary copy remains Korean:

```text
이미지 N장 · 작업 필요 N장 · 완료 N장 · 문제 N장
```

### Center Canvas

Do not change canvas behavior.

Visual consistency requirements:

- Tool groups use restrained button radius.
- Automation, edit, and view groups remain clearly separated.
- Destructive actions remain visually separated from frequent work actions.
- Empty states use short Korean action copy.

### Right Workflow Panel

Keep the workflow-panel direction:

- selected image/file context,
- completion action,
- blocker feedback,
- boxes grouped by work state,
- selected box details lower priority.

Apply shared shape rules:

- no pill rows,
- no overly rounded action surfaces,
- subdued badges,
- selected rows use border/background rather than heavy rounded styling.

### Bottom Quick Label Bar

The quick label bar is operational and should remain dense.

Rules:

- label chips should be compact,
- avoid pill-like exaggerated rounding,
- preserve shortcut badges,
- keep label colors readable but not decorative.

## Shared Component Guidance

Add only small internal UI helpers when they reduce repetition.

Candidates:

- `AppStatusBadge`
- `AppPanelSurface`
- `AppSectionHeader`
- `AppListRow`
- `AppToolbarButton`

These should not become a large custom design system. They should encode the
few rules needed for consistency:

- Korean labels and tooltips,
- compact radius,
- border and background treatment,
- status color mapping,
- text overflow behavior.

For this pass, keep implementation local to `lib/ui` unless reuse clearly
justifies a separate file.

## Accessibility

- Buttons and icon buttons must have Korean tooltips or semantic labels.
- Status must not rely on color alone.
- Text should truncate predictably rather than overflow.
- Focus order should remain natural:
  project home actions, project list, workbench top bar, image queue, canvas,
  inspector, quick label bar.
- Destructive actions must remain discoverable but not visually dominant.

## Error Handling

Do not change controller behavior.

Copy should be Korean and short:

- project action failure,
- save failure,
- return-home failure,
- image import failure,
- export warning/blocking dialog.

Where possible, explain impact and next action:

```text
프로젝트 작업을 완료하지 못했습니다. 다시 시도하세요.
```

```text
내부 프로젝트 데이터만 삭제됩니다. 원본 이미지는 삭제되지 않습니다.
```

## Code Boundaries

Likely affected files:

- `lib/ui/start_screen.dart`
- `lib/ui/workbench_screen.dart`
- `lib/ui/workbench_copy.dart`
- `lib/ui/app_theme.dart`
- `test/ui/project_home_widget_test.dart`
- `test/widget_test.dart`
- related workbench widget tests that assert visible copy

Keep domain files unchanged unless a test fixture requires updated display
strings.

## Testing Plan

Widget tests:

- Project home title is `프로젝트 홈`.
- Project name input label is `프로젝트 이름`.
- Create button is labeled `만들기`.
- Empty project list shows Korean empty state.
- Project row metadata uses Korean units and terms.
- Project menu shows `이름 변경` and `삭제`.
- Delete dialog says original images are not deleted.
- Workbench top bar no longer exposes English `Undo` or `Redo` tooltips.
- Existing return-home flow still works.
- Existing image import, label assignment, completion, and export warning tests
  still pass.

Static/manual checks:

- Search `lib/ui` for leftover user-facing English copy.
- Inspect home and workbench at a desktop size such as 1366x768.
- Check long project names and long filenames.
- Check selected rows do not use overly rounded pill styling.
- Check all buttons feel compact and professional.

Verification commands:

```powershell
C:\tools\flutter\bin\flutter.bat test test\ui\project_home_widget_test.dart
C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart
C:\tools\flutter\bin\flutter.bat analyze
```

Run the full suite if time allows:

```powershell
C:\tools\flutter\bin\flutter.bat test
```

## Acceptance Criteria

- Project home and workbench feel like one coherent Korean desktop app.
- No primary visible UI on project home remains in English.
- Workbench top-bar tooltips and primary controls use Korean copy.
- Buttons and controls use restrained professional radii.
- Home project rows and workbench image rows share similar density and state
  hierarchy.
- Existing annotation, save/load, return-home, image import, and COCO export
  behavior remains unchanged.
- Relevant widget tests pass, or any local verification blocker is documented.
