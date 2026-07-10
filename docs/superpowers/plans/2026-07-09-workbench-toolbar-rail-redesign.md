# Workbench Toolbar Rail Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace visually separate workbench control boxes with unified toolbar rails that feel aligned and professional.

**Architecture:** Keep the existing `WorkbenchScreen` structure and controller APIs. Add small private toolbar wrapper widgets in `lib/ui/workbench_screen.dart`, then update tests in `test/ui/workbench_widget_test.dart` to assert the visual structure.

**Tech Stack:** Flutter, Material widgets, `flutter_test`.

## Global Constraints

- 지원 언어는 한글 UI다.
- 버튼은 과하게 둥글지 않게 유지한다.
- 메인 선택 색상은 오렌지 계열이다.
- 기존 라벨링, 저장, undo/redo, export, zoom, draw, pan 동작은 유지한다.
- Production code changes must follow TDD: add failing widget tests before implementation.

---

### Task 1: Top Toolbar Rail

**Files:**
- Modify: `test/ui/workbench_widget_test.dart`
- Modify: `lib/ui/workbench_screen.dart`

**Interfaces:**
- Consumes: existing keys `top-status-group`, `top-document-actions`, `top-edit-actions`, `save-project`, `export-coco`.
- Produces: new key `top-action-rail`.

- [ ] **Step 1: Write failing tests**

Add assertions that `top-action-rail` exists, that the top separator is not black, and that the action groups share a consistent height.

- [ ] **Step 2: Run focused test**

Run: `C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart --plain-name "top bar action rail is visually subtle and aligned"`

Expected: FAIL because `top-action-rail` does not exist and the separator is still a vertical divider.

- [ ] **Step 3: Implement top rail**

Wrap right-side actions in a light bordered rail, replace black-looking separators with subtle spacing/dividers, and keep existing action keys.

- [ ] **Step 4: Verify**

Run the focused test again and expect PASS.

### Task 2: Center Canvas Toolbar Rail

**Files:**
- Modify: `test/ui/workbench_widget_test.dart`
- Modify: `lib/ui/workbench_screen.dart`

**Interfaces:**
- Consumes: existing keys `center-automation-toolbar`, `center-edit-toolbar`, `center-view-toolbar`.
- Produces: new key `center-toolbar-rail`.

- [ ] **Step 1: Write failing tests**

Add assertions that one `center-toolbar-rail` contains all three center groups, and that group decorators do not use individual borders.

- [ ] **Step 2: Run focused test**

Run: `C:\tools\flutter\bin\flutter.bat test test\ui\workbench_widget_test.dart --plain-name "center controls render as one toolbar rail"`

Expected: FAIL because the center rail does not exist.

- [ ] **Step 3: Implement center rail**

Introduce one rail wrapper around automation, edit, and view controls. Convert `_ToolbarGroup` into an unbordered segment and add internal separators between groups.

- [ ] **Step 4: Verify**

Run the focused test again and expect PASS.

### Task 3: Regression Verification and Build

**Files:**
- Modify: no production files unless regressions are found.

**Interfaces:**
- Consumes: all workbench tests and Flutter build pipeline.
- Produces: Windows build at `build/windows/x64/runner/Release/bbox_labeler.exe`.

- [ ] **Step 1: Format**

Run: `C:\tools\flutter\bin\dart.bat format lib\ui\workbench_screen.dart test\ui\workbench_widget_test.dart`

- [ ] **Step 2: Analyze**

Run: `C:\tools\flutter\bin\flutter.bat analyze`

- [ ] **Step 3: Test**

Run: `C:\tools\flutter\bin\flutter.bat test`

- [ ] **Step 4: Build**

Run: `C:\tools\flutter\bin\flutter.bat build windows`
