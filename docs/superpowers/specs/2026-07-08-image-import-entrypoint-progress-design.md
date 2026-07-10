# Image Import Entrypoint And Progress Design

## Context

New empty projects currently show three image import entrypoints:

- Top app bar image-add menu.
- Left image queue empty-state folder button.
- Center viewer empty-state folder button.

This makes the first-use screen feel duplicated. Folder import also opens a custom path-entry modal and then an old Windows Forms folder picker. Large image imports can take a long time without a visible progress signal, so users cannot tell whether the app is still working.

## Goals

- Show one clear primary image import action in an empty project.
- Keep image adding quick after a project already has images.
- Use a modern native file/folder picker instead of the path-entry modal for the default flow.
- Show import progress immediately for large folders or many selected files.
- Preserve support for adding either folders or specific image files.

## Non-Goals

- No cloud import, drag-and-drop import, or account features.
- No detector changes.
- No COCO save dialog changes in this implementation.
- No new project data model fields unless needed for import status.

## Recommended UX

Empty project:

- The center viewer empty state owns the only primary action.
- The action label should map to `WorkbenchCopy.importImages`.
- Clicking it opens a compact menu with:
  - `WorkbenchCopy.addImageFolder`
  - `WorkbenchCopy.addImageFiles`
- The left image queue shows an informational empty state only, with no button.
- The top app bar hides `WorkbenchCopy.imageAdd` while the project has zero images.

Project with images:

- The top app bar shows `WorkbenchCopy.imageAdd`.
- The top menu offers folder and file import.
- The center viewer does not show an import CTA unless the project is empty.

## Dialog Strategy

Default folder/file selection should use the Flutter `file_selector` plugin:

- `getDirectoryPath` for folder import.
- `openFiles` with image extensions for multi-file import.

The current custom `ImageFolderPathDialog` should be removed from the normal import path. If manual path entry remains useful for tests or power users, it should be moved behind a secondary explicit action in a later change, not shown by default.

## Import Progress UX

Import should show visible progress as soon as scanning begins.

Top-level behavior:

- While importing, show a slim progress surface near the top or bottom of the workbench.
- Text should include phase and counts:
  - scanning state before the total is known.
  - determinate state when `ImageImportProgress.total` is known.
  - added and skipped counts when available.
- Disable conflicting import/export/confirm actions while import is active.
- Keep view controls and existing image selection available where safe.

Completion behavior:

- Show a brief summary message with added, skipped, and error counts.
- Error images remain in the list with existing error state behavior.

Implementation note:

- `AppController` already exposes `projectActivity` and `imageImportProgress`.
- UI should consume those instead of introducing a separate progress state.
- If folder scanning blocks before `imageImportProgress.total` is known, show an indeterminate scanning state first, then switch to determinate counts once scanned files are known.

## Architecture

Introduce an import picker abstraction so UI code does not depend directly on a package or PowerShell:

- `ImageImportPicker`
  - `Future<String?> pickImageFolder()`
  - `Future<List<String>> pickImageFiles()`

Production implementation:

- Uses `file_selector`.
- Filters files to `jpg`, `jpeg`, and `png`.

Testing implementation:

- Existing tests can inject callbacks or a fake picker.
- Widget tests should not open native dialogs.

`WindowsDialogService` can remain temporarily for COCO save if needed, but image import should stop using PowerShell dialogs.

## Testing

Add or update widget tests:

- Empty project shows only one visible import CTA.
- Left empty image queue has no import button.
- Top app bar hides image add when there are no images.
- Top app bar shows image add after images exist.
- Empty center import menu can trigger folder import.
- Import progress appears while `projectActivity == ProjectActivity.importing`.
- Progress text reflects processed, total, added, and skipped counts.

Add service/controller tests if picker abstraction contains path filtering or output mapping.

## Acceptance Criteria

- A new empty project has one primary import action, not three.
- Folder import no longer shows the path-entry modal by default.
- File and folder picking use native picker APIs from `file_selector`.
- Large imports show visible progress before completion.
- Import completion summarizes added, skipped, and error counts.
- Existing image import, save/load, and export tests continue to pass.
