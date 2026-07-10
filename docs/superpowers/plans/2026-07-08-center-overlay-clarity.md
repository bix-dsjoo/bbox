# Center Overlay Clarity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the center image viewer render bounding boxes as clean single-color overlays and keep resize anchors visually stable across zoom levels.

**Architecture:** Keep the change inside the existing workbench overlay widgets. `workbench_screen.dart` remains responsible for visual rendering, while `canvas_interaction.dart` continues to own hit testing and resize math.

**Tech Stack:** Flutter widget tests, Material widgets, existing `InteractiveViewer`, existing annotation models.

## Global Constraints

- Do not change original-image coordinate storage or COCO/export behavior.
- Keep box editing in original image pixel coordinates.
- Keep resize handles accessible with a larger hit area than visual area.
- Avoid broad workbench refactors.

---

### Task 1: Lock Overlay Visual Behavior

**Files:**
- Modify: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: existing widget keys `selected-box-box-1`, `box-contrast-box-1`, `resize-handle-visual-box-1-topLeft`, `zoom-in`, `zoom-out`.
- Produces: failing tests that require a single visual border layer and fixed screen-size resize handles.

- [ ] **Step 1: Write failing tests**

Add assertions that selected boxes no longer render a separate `box-contrast-*` layer and that resize handle visual rectangles keep the same tester rect size before and after zooming.

- [ ] **Step 2: Run focused test to verify failure**

Run: `flutter test test/ui/workbench_widget_test.dart --plain-name "selected automatic box keeps high contrast gray styling"`

Expected: FAIL because the current widget still renders `box-contrast-box-1`.

Run: `flutter test test/ui/workbench_widget_test.dart --plain-name "resize handle visual keeps the same screen size after zooming"`

Expected: FAIL if zoom changes the measured handle visual size.

### Task 2: Simplify Overlay Rendering

**Files:**
- Modify: `lib/ui/workbench_screen.dart`

**Interfaces:**
- Consumes: `_automaticBoxColor`, `_resizeHandleHitSize`, `_resizeHandleVisualSize`, current `_OverlayBox` and `_ResizeHandle` widgets.
- Produces: one-color bounding box styling, selected outer emphasis, fixed visual handle sizing.

- [ ] **Step 1: Remove the contrast overlay layer**

Delete the separate `box-contrast-*` positioned container. Keep one primary border on the box container and use an optional selected outline that is visually subordinate to the box color.

- [ ] **Step 2: Make handle visual size screen-stable**

Use a constant visual size inside the handle hit area and avoid zoom-derived visual scaling that compounds with `InteractiveViewer`. Keep hit size large enough for interaction.

- [ ] **Step 3: Run focused tests**

Run: `flutter test test/ui/workbench_widget_test.dart --plain-name "selected automatic box keeps high contrast gray styling"`

Expected: PASS.

Run: `flutter test test/ui/workbench_widget_test.dart --plain-name "resize handle visual keeps the same screen size after zooming"`

Expected: PASS.

### Task 3: Verify Existing Interaction Safety

**Files:**
- Test: `test/ui/workbench_widget_test.dart`
- Test: `test/ui/canvas_interaction_test.dart`

**Interfaces:**
- Consumes: existing drag, resize, selection, hit-test behavior.
- Produces: confidence that visual cleanup did not change editing geometry.

- [ ] **Step 1: Run focused interaction tests**

Run: `flutter test test/ui/canvas_interaction_test.dart test/ui/workbench_widget_test.dart`

Expected: PASS.

## Self-Review

- Spec coverage: covers clean one-color boxes, selected-state clarity, fixed resize handles, and unchanged coordinate behavior.
- Placeholder scan: no TODO/TBD placeholders.
- Type consistency: only existing widget keys, constants, and tests are referenced.
