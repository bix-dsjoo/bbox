# QA Fix 1 implementation report

Date: 2026-07-13 (Asia/Seoul)  
Result: DONE_WITH_CONCERNS  
Implementation commit: `587e1fd` (`fix: make export flow recoverable and popover viewport-safe`)

## Implemented

### Label management overlay

- Measures the label-management trigger in overlay coordinates.
- Uses a responsive width capped at 380 logical pixels with a 12-pixel viewport margin.
- Clamps horizontal placement against both viewport edges while preserving the existing `LayerLink`, non-modal overlay, outside-click dismissal, create/update behavior, and automation lockout.
- Scales the compact form as one usable unit when less than 300 logical pixels are available, keeping name, shortcut, color, and the primary action inside the popover.

### COCO destination and lifecycle

- Removed the PowerShell/WinForms `SaveFileDialog` implementation and its active workbench reference.
- Added `WindowsCocoExportDestinationPicker`, based on `filepicker_windows` `SaveFilePicker`, with title `COCO JSON 내보내기`, JSON filter, default filter index 0, `.json` extension, and filesystem-only results.
- Added injectable destination-picker and writer seams to `WorkbenchScreen`.
- Extracted `CocoExportWarningDialog` so one local attempt owns its `inFlight` and error state.
- Duplicate activation is disabled/ignored while pending.
- Cancellation leaves the warning open and immediately restores retry without error feedback.
- Picker and write exceptions show concise actionable inline feedback and restore retry in `finally`.
- Success closes the warning and shows a snackbar containing the saved path.
- No project-level exporting state was added.

## TDD evidence

### RED

1. `flutter test test/ui/workbench/quick_label_bar_test.dart --plain-name "label management popover stays inside a 1585x943 viewport at the right edge"`
   - Failed as expected: `label-management-popover bottom-right must be inside the viewport` (`Actual: false`).
2. `flutter test test/ui/workbench/quick_label_bar_test.dart --plain-name "label management popover stays inside a 1280x720 viewport"`
   - Failed as expected: viewport containment was false.
3. `flutter test test/ui/label_management_popover_test.dart --plain-name "keeps the primary action reachable at narrow desktop width"`
   - Failed as expected: `RenderFlex overflowed by 24 pixels on the right`; the action bottom-right was outside the popover.
4. `flutter test test/ui/windows_dialog_service_test.dart --plain-name "WindowsDialogService has no production reference to the PowerShell save dialog"`
   - Failed as expected because production source contained `SaveFileDialog`.
5. Minimal bounded cancel/retry harness:
   - Failed as expected: after cancellation, `AlertDialog` count was 0 instead of 1.
6. Delayed-picker single-flight regression:
   - Failed as expected: picker calls were 2 instead of 1.
7. Picker exception regression:
   - Failed as expected with uncaught `Exception: picker unavailable`; no `export-attempt-error` existed.
8. Write exception regression:
   - Failed as expected because no `export-attempt-error` existed.
9. Initial route-owned success/lifecycle test attempts did not terminate within the outer timeout. Investigation showed the test retained an awaited `showDialog` route/Future. After three attempts, the lifecycle was extracted into `CocoExportWarningDialog`; direct bounded widget tests replaced the non-deterministic harness, and one workbench integration test explicitly closes the route on success.

### GREEN

- Popover 1585x943 focused test: 1/1 passed.
- Popover 1280x720 and narrow-form focused tests: 2/2 passed.
- Obsolete PowerShell production-reference test: 1/1 passed.
- Extracted lifecycle tests: 4/4 passed (cancel/retry success, delayed single-flight, picker error recovery, write error recovery).
- Combined focused suite:
  - Command: `flutter test test/ui/coco_export_destination_picker_test.dart test/ui/coco_export_warning_dialog_test.dart test/ui/workbench/export_success_integration_test.dart test/ui/workbench/quick_label_bar_test.dart test/ui/label_management_popover_test.dart test/ui/windows_dialog_service_test.dart test/ui/workbench/export_and_completion_test.dart --no-pub`
  - Result: 42/42 passed in 7.0 seconds.
- Full suite:
  - Command: `flutter test --no-pub`
  - Result: 353/353 passed in 12.5 seconds.
- Static analysis:
  - Command: `flutter analyze --no-pub`
  - Result: `No issues found!` in 5.9 seconds.
- Formatting: all changed Dart files were formatted with `dart format`.
- Diff checks: `git diff --check` and `git diff --cached --check` passed.
- Source audit: `rg` found no production `SaveFileDialog` or `WindowsDialogService.saveCocoFile` reference and no new exporting-status assignment.

## Changed files

- `lib/ui/coco_export_destination_picker.dart`
- `lib/ui/coco_export_warning_dialog.dart`
- `lib/ui/label_management_popover.dart`
- `lib/ui/windows_dialog_service.dart`
- `lib/ui/workbench/quick_label_bar.dart`
- `lib/ui/workbench/workbench_screen.dart`
- `test/ui/coco_export_destination_picker_test.dart`
- `test/ui/coco_export_warning_dialog_test.dart`
- `test/ui/label_management_popover_test.dart`
- `test/ui/windows_dialog_service_test.dart`
- `test/ui/workbench/export_and_completion_test.dart`
- `test/ui/workbench/export_success_integration_test.dart`
- `test/ui/workbench/quick_label_bar_test.dart`
- `test/ui/workbench/workbench_test_support.dart`

## Self-review and concerns

- Scope is limited to the two reported root causes and their tests.
- Existing project persistence, COCO generation, label create/update behavior, and automation gating remain unchanged.
- The native COM save picker itself cannot be opened in headless Flutter tests; configuration and the absence of the obsolete PowerShell path are automated, while final owned-window behavior still requires Windows release smoke QA.
