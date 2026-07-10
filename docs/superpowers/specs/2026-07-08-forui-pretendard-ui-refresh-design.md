# FORUI and Pretendard UI Refresh Design

Date: 2026-07-08

## Context

The app is a Flutter desktop bounding-box labeling tool. The current UI is mostly Material 3 with a useful three-panel workbench structure:

- Project home for creating and reopening local projects.
- Left image queue, center image viewer, right inspector, and bottom quick label bar.
- Custom canvas interaction code for box drawing, selection, movement, resize, and overlays.

The requested change is to improve the UI using the Pretendard font and the FORUI UI library. This should improve visual consistency without destabilizing annotation behavior.

## Goals

- Use Pretendard as the app-wide UI font.
- Add FORUI as the UI system foundation.
- Give the app a cleaner desktop-tool look: denser, calmer, and easier to scan during repeated labeling.
- Preserve the existing project, import, annotation, save, and export behavior.
- Keep canvas coordinate and overlay behavior unchanged except for colors and surrounding chrome.

## Non-Goals

- Do not rewrite the annotation canvas interaction model.
- Do not change project storage, COCO export, detector behavior, or data models.
- Do not add cloud, account, collaboration, or training features.
- Do not attempt a full string/localization rewrite in this UI pass, although visibly broken copy may remain a separate follow-up risk.

## Recommended Approach

Use a progressive FORUI adoption.

1. Add `forui` dependency and wrap the app with `FTheme`.
2. Use FORUI's approximate Material theme bridge so existing Material widgets inherit a coherent visual base.
3. Add Pretendard font assets and set both Material and FORUI typography to use Pretendard where supported by the installed FORUI version.
4. Replace high-visibility controls with FORUI components where the API is straightforward and low-risk:
   - project-home primary actions,
   - workbench toolbar buttons,
   - panel section headers and status badges,
   - progress/status surfaces,
   - label management popover controls.
5. Keep complex custom canvas widgets and gestures in Material/custom widgets, but restyle their containers, colors, and typography to match the FORUI theme.

This avoids a risky full UI rewrite while still making FORUI the visible design foundation.

## Architecture

### Theme Layer

Create a small UI theme module, for example `lib/ui/app_theme.dart`, responsible for:

- choosing the FORUI desktop light theme,
- applying Pretendard font family,
- deriving a Material `ThemeData` from FORUI via `toApproximateMaterialTheme()`,
- exposing shared workbench colors for panel backgrounds, borders, selected rows, muted text, and status surfaces.

`BboxApp` should become the only place that wires `MaterialApp`, `FTheme`, `FToaster`, and `FTooltipGroup`.

### Asset Layer

Add Pretendard font files under `assets/fonts/pretendard/`.

Register a `Pretendard` family in `pubspec.yaml`. The app should include regular, medium, semi-bold, and bold weights if available. If the implementation uses a variable font, register that one asset for the family.

### UI Component Layer

Add small internal wrapper widgets only where they reduce repetition:

- `WorkbenchPanelSurface`
- `WorkbenchStatusBadge`
- `WorkbenchIconButton` or focused toolbar button helpers

These wrappers should not become a new design system. They should exist only to keep the workbench readable and consistent.

### Existing Screens

Project home:

- Keep the first screen action-focused.
- Use Pretendard typography, tighter spacing, clearer project list rows, and a stronger create-project action.
- Continue to expose project create, open, rename, and delete flows.

Workbench:

- Keep the current three-panel layout.
- Make panels visually quieter with FORUI-inspired borders, muted backgrounds, and compact headers.
- Improve status badges for image state, save state, unlabeled count, and errors.
- Keep the bottom quick-label bar dense and horizontal.
- Keep tool buttons icon-first with tooltips.

Label management popover:

- Restyle input, color picker surface, rows, and action buttons.
- Preserve duplicate-label validation and shortcut rules.

## Data Flow

No domain data flow changes.

UI actions continue to call `AppController` methods. Theme and component changes must not mutate annotation models directly or alter controller responsibilities.

## Error Handling

Existing project, save, import, and export error paths remain unchanged.

FORUI adoption should not replace current dialog flows until the installed package version and APIs are verified locally. If FORUI dialog APIs are unavailable or incompatible, keep Material dialogs but let them inherit the FORUI-derived Material theme.

## Testing

Because this is a UI refresh, use focused widget tests before production changes:

- App root builds with the FORUI/Pretendard theme and still shows project home.
- Project creation flow still opens the workbench.
- Workbench return-home action still works.
- Label management popover still creates and edits labels if touched.

After implementation:

- Run `flutter pub get`.
- Run `flutter test`.
- If a Flutter executable is unavailable in PATH, document that verification is blocked and do not claim tests passed.

## Risks

- FORUI 0.22.0+ requires a very recent Flutter SDK. The installed local SDK must be checked. If the local SDK is older, pin a compatible FORUI version rather than upgrading the whole project blindly.
- This environment currently has no `flutter` command in PATH, so dependency resolution and tests may require locating the SDK or using the user's configured Flutter environment.
- Some Korean UI copy appears mojibake-corrupted in existing source files. This UI refresh should avoid expanding scope into full copy repair unless the user explicitly asks for it.
- Full conversion of every Material widget to FORUI would be slower and higher risk because the workbench includes a custom image canvas and many tested keys.

## Acceptance Criteria

- `pubspec.yaml` includes FORUI and Pretendard font registration.
- `BboxApp` provides FORUI theme context and Material theme bridging.
- App-wide visible text uses Pretendard.
- Start screen and workbench look visually more consistent, compact, and professional.
- Existing widget tests still pass or any verification blocker is clearly reported.
- Annotation canvas behavior, project library behavior, and COCO export behavior remain unchanged.
