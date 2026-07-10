# Workbench Toolbar Rail Redesign

## Goal

Make the workbench controls read as one professional labeling workspace instead of separate floating button boxes.

## Requirements

- The top toolbar keeps project context on the left and groups document/edit actions on the right with consistent heights.
- The top toolbar does not use a visually heavy black divider.
- The center canvas controls appear as one continuous toolbar rail with internal segments for automation, editing, and viewing.
- Selected controls use the orange accent, while non-selected controls remain quiet and neutral.
- The quick-label strip keeps label identity colors but uses orange only for selected/active state.
- Existing keyboard shortcuts, semantics, keys, and labeling behavior remain intact.

## Design

The top app bar remains a Material `AppBar`, but the right-side actions become a compact toolbar rail with light border and muted background. The document and edit groups remain key-addressable for tests, and separators are changed from heavy vertical dividers to subtle spacers.

The center canvas toolbar changes from multiple bordered `_ToolbarGroup` boxes into a single `_CanvasToolbarRail`. Automation, edit, and view sections sit inside that rail and are separated by muted internal dividers. This preserves existing widget keys while removing the stacked floating-box look.

Quick-label chips remain compact two-row controls. A selected chip receives orange accent background and border; label color remains visible in the shortcut badge and dot.

## Verification

- Widget tests assert top separators are subtle instead of black.
- Widget tests assert the center toolbar has one rail and no separate group borders.
- Existing workbench interaction tests continue passing.
- Run `flutter analyze`, `flutter test`, and `flutter build windows`.
