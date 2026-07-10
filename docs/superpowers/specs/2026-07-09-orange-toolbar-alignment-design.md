# Orange Toolbar Alignment Design

Date: 2026-07-09

## Context

The current workbench is functional, but the screenshot review exposed two
visual problems:

- Selected toolbar buttons use a dark/black treatment, which is too close to
  normal dark command buttons and makes selected state hard to distinguish.
- The top app bar and center canvas toolbars feel loosely grouped. Controls have
  inconsistent visual rhythm, so the screen looks less aligned than it should.

The app is a Korean desktop bounding-box labeling tool. This pass should keep
the dense professional tool feel while making state and alignment clearer.

## Goals

- Change the main accent from teal to a bread-friendly orange amber.
- Make selected states clearly different from normal, disabled, and destructive
  buttons.
- Rework the top app bar grouping so project context, status, document actions,
  edit controls, and export do not feel mixed together.
- Align the center toolbars so automation, edit, and view controls share the
  same height, padding, border rhythm, and left edge.
- Tighten the bottom quick-label bar so label chips look like one aligned tool
  strip.
- Preserve existing annotation, save/load, image import, label assignment,
  keyboard shortcut, and COCO export behavior.

## Non-Goals

- Do not change canvas coordinate math.
- Do not change annotation models.
- Do not change detector, export, or project storage behavior.
- Do not redesign the whole app shell.
- Do not add a new design dependency.
- Do not make a marketing-style or decorative UI.

## Visual Direction

Use orange amber as the app's primary action and selected-state color.

Recommended palette:

- `accent`: `#D97706`
- `accentSoft`: `#FFF3E0`
- `accentStrong`: `#B45309`
- `accentBorder`: `#F59E0B`

Selection should not be black. Selected states should read as:

- orange background or orange-tinted background,
- clear orange border,
- strong foreground contrast,
- optional left accent bar for list rows.

Normal controls should remain quiet:

- white or panel background,
- gray border,
- dark text.

Disabled controls should remain visibly disabled:

- muted foreground,
- light gray surface,
- gray border.

Destructive controls still use the danger palette, not orange.

## Top App Bar

The top app bar should read as grouped desktop tool chrome.

Recommended order:

1. Project context group:
   - `프로젝트 홈`
   - current project name
2. Save status group:
   - `저장됨`, `저장 중`, or `저장 실패` as a small status badge, not a button.
3. Document action group:
   - `이미지 추가`
   - `COCO 내보내기`
4. Edit utility group:
   - save icon
   - undo
   - redo

Rules:

- Groups use fixed spacing and subtle separators.
- `저장됨` must not look like a primary command button.
- `이미지 추가` and `COCO 내보내기` use matching height and style.
- Icon-only utilities use compact square buttons with Korean tooltips.
- Long project names truncate before pushing action groups off-screen.

## Center Toolbars

The center toolbars should feel like one aligned work toolbar, not scattered
cards.

Current conceptual grouping remains:

- Automation: `자동 박스`, `박스 전체 삭제`
- Editing: `선택`, `박스 그리기`, `이동`, `선택 박스 삭제`
- View: zoom out, fit, zoom in, actual size

Rules:

- Automation row and editing/view row share the same left edge.
- Toolbar group height is consistent.
- Group padding is consistent.
- Button height is consistent.
- Selected tool state uses orange selected styling.
- The view group should not feel detached from the edit group.
- Toolbars may wrap or scroll horizontally only when the window is too narrow.

## Bottom Quick Label Bar

The quick label bar should read as an aligned shortcut strip.

Rules:

- Chip height is consistent with toolbar controls where practical.
- Selected chip uses orange selected styling instead of black/dark styling.
- Disabled chips remain visibly muted.
- Shortcut badges align consistently inside each chip.
- Row gaps and chip gaps are fixed.

## Implementation Boundaries

Likely affected files:

- `lib/ui/app_theme.dart`
- `lib/ui/workbench_screen.dart`
- `test/ui/workbench_widget_test.dart`
- `test/widget_test.dart` if app theme assertions need updates

Keep changes inside the UI layer.

Do not change:

- `lib/annotation`
- `lib/export`
- `lib/detector`
- `lib/viewer/viewport_transform.dart`
- project persistence files

## Testing Plan

Widget tests should cover:

- `WorkbenchPalette.accent` is the new orange value.
- selected canvas toolbar buttons resolve to orange selected styling, not black.
- top app bar exposes grouped actions with stable keys.
- save status remains a badge-like status element.
- image add and COCO export actions have matching visual treatment where testable.
- image queue selected row uses orange-accent selected treatment.
- quick label selected chip uses label/orange styling and does not use black.
- existing workbench behavior tests still pass.

Manual inspection should cover:

- screenshot-like 1600x900 desktop size,
- long project name,
- image with selected box and selected quick label,
- disabled delete selected box state,
- empty project workbench.

## Acceptance Criteria

- The selected state is visually orange and no longer confused with black command
  buttons.
- The top app bar reads as separated groups: context, status, document actions,
  edit utilities, export.
- The center toolbar rows align cleanly and share height/padding rhythm.
- The bottom quick-label bar feels aligned and less uneven.
- Existing labeling, save, undo/redo, import, and COCO export behavior remains
  unchanged.
- Relevant widget tests, `flutter analyze`, and `flutter test` pass.

