# Workbench UI Refresh Design

## Context

The current workbench works functionally, but it still feels like a prototype.
The screenshot from the current app shows a wide pale background, thin dividers,
flat panels, scattered toolbar actions, and a weak empty state. The interface
communicates that features exist, but it does not yet feel like a mature desktop
labeling tool.

This refresh should not turn the app into a marketing page or a decorative
interface. The product is a local desktop annotation tool. The design must stay
dense, calm, and operational while making the next action obvious.

## References

- Toss Tech, user perspective assumptions:
  https://toss.tech/article/thinking-user-perspective
- Toss Tech, Easy to answer:
  https://toss.tech/article/insurance-claim-process
- Toss Tech, design-system component quality:
  https://toss.tech/article/toss-design-system
- Toss Tech, PC-based tools product design:
  https://toss.tech/article/Designer

## Product Principles For This UI

### Easy To Answer

The screen should ask the user an easy question at each state.

Bad empty-state question:

```text
Select an image.
```

This is hard when there are no images.

Better empty-state question:

```text
Choose an image folder to start labeling.
```

This matches the user's real next action.

### User Purpose First

The user wants to build object detection training data, not manage software
state. UI hierarchy should prioritize:

1. Choose or inspect images.
2. Draw and verify boxes.
3. Assign labels.
4. Confirm images.
5. Export COCO.

Project navigation, saving, and settings should be visible but secondary.

### Patterned Components

Repeated UI should use consistent patterns:

- Panel header.
- Panel summary row.
- Empty state.
- Toolbar icon button.
- Primary action button.
- Status badge.
- List row.
- Section heading.

This avoids the current prototype feeling where every area has a slightly
different visual rhythm.

### Desktop Tool, Not Mobile App

The app should borrow Toss's clarity and user-centered thinking, not its mobile
spacing scale. This is a Windows desktop labeling tool, so it should remain
work-focused, compact, and scannable.

## Current Problems From Screenshot

- The image count panel says there are no images, but the strongest message in
  the center still says to select an image.
- The primary next action, choosing an image folder, is hidden in the top app
  bar instead of being presented in the empty state.
- The app bar mixes navigation, project identity, save state, folder import,
  manual save, undo, redo, and export at the same visual level.
- The center canvas is mostly empty but has no helpful onboarding action.
- The left filter chips overflow horizontally and look clipped.
- The right panel has low hierarchy: selected image text and empty guidance
  look like raw debug labels.
- The pale background covers every area, so panels and working surface do not
  feel intentionally separated.
- Dividers make the app look like a wireframe instead of a finished tool.
- Korean UI copy appears inconsistent in the running app and should be cleaned
  up during this UI pass.

## Recommended Direction

Use a polished three-panel desktop workspace:

```text
Top project bar
Left image queue | Center annotation canvas | Right inspector
```

The layout stays familiar, but the hierarchy changes:

- Top bar: context and global actions.
- Left panel: image queue and review filters.
- Center panel: annotation work surface and empty-state primary action.
- Right panel: selected image, boxes, labels, confirmation.

## Top Bar

### Purpose

The top bar should answer:

```text
Where am I, is my work saved, and what global actions are available?
```

### Layout

Left:

- `Project home` button.
- Project name.

Center/right:

- Save status badge.
- Undo and redo icon buttons.
- Image folder action.
- COCO export action.

Manual save can remain as an icon button for reassurance, but it should be less
prominent than image import and export.

### Visual Rules

- Use a white or near-white top bar with a subtle bottom border.
- Keep height around 56px to 64px.
- Use compact icon buttons for undo, redo, and save.
- Use icon plus text for `Project home`, `Image folder`, and `Export` because
  these change major workflow state.
- Project name should truncate before actions overflow.

## Left Image Queue Panel

### Purpose

The left panel should answer:

```text
What images are in this project, and which ones need work?
```

### Header

Use a compact header:

```text
Images
0 total
```

When images exist:

```text
Images
128 total · 41 need review · 80 confirmed · 7 errors
```

### Filters

Replace horizontally scrolling chips with a segmented/filter row that wraps or
uses compact labels:

- All
- Review
- Confirmed
- Errors
- Unlabeled

The selected filter should be visually clear but not heavy.

### Empty State

When there are no images:

```text
No images yet
Choose a folder to import images for this project.
[Choose image folder]
```

This puts the next action where the user is looking.

### Image Rows

Rows should show:

- Thumbnail fallback or thumbnail.
- File name.
- Status badge.
- Box summary, for example `3 boxes · 1 unlabeled`.

Avoid long mixed text strings that are hard to scan.

## Center Annotation Canvas

### Purpose

The center panel is the primary workspace. It should have the strongest visual
weight.

### Empty Project State

When the project has no images:

```text
Start by choosing an image folder
Supported images will appear in the left queue. Your original files stay unchanged.
[Choose image folder]
```

This is the main CTA on the screen.

### No Image Selected State

When images exist but none is selected:

```text
Select an image from the queue
```

This state should be secondary, because the user now has a real image list.

### Canvas Styling

- Use a neutral app background around the canvas.
- Use a white or checkerboard-like canvas surface only where an image appears.
- Do not show a huge blank pale area without a frame or action.
- Keep zoom tools in a small canvas toolbar, not floating as unrelated buttons.
- The canvas panel should feel like the working surface, not an empty page.

## Right Inspector Panel

### Purpose

The right panel should answer:

```text
What is selected, and what can I do with it?
```

### Empty State

When no image is selected:

```text
No image selected
Select an image to review boxes and labels.
```

If the project has no images, this panel can show lighter empty guidance and
not repeat the primary folder action.

### Selected Image Structure

Use clear sections:

1. Image
   - File name.
   - Size.
   - Status badge.
   - Confirm button.

2. Labels
   - Label input.
   - Existing label buttons.

3. Boxes
   - Box list.
   - Selected box controls.

Section headings should be compact and consistent.

## Visual System

### Color

Use a neutral professional palette:

- App background: very light gray.
- Panels: white.
- Borders: low-contrast gray.
- Primary action: teal/green from the current app theme.
- Confirmed: green.
- Warning/missing: amber or red depending on severity.
- Error: red.
- Proposal boxes: gray.
- Labeled boxes: label colors.

Avoid a one-note mint-tinted entire app background. The current screenshot reads
too much like a single pale color wash.

### Surfaces

- Top bar: white.
- Left and right panels: white.
- Center workspace: neutral gray, with explicit canvas area.
- Avoid nested cards.
- Use 1px borders and subtle section dividers.

### Spacing

- App shell: 0 outer padding; panels fill the window.
- Panel padding: 16px.
- Section gap: 20px.
- Row gap: 8px to 12px.
- Button height: 36px to 40px.
- Panel widths:
  - Left: 300px to 320px.
  - Right: 340px to 360px.

### Typography

- Project title: medium, not hero-scale.
- Panel title: 16px to 18px.
- Section title: 13px to 14px, semibold.
- Body/help text: 13px to 14px.
- Do not use oversized empty-state text.

## Copy Guidelines

Use short, action-centered Korean copy.

Recommended labels:

- `프로젝트 홈`
- `이미지 폴더`
- `COCO 내보내기`
- `저장됨`
- `저장 중`
- `저장 실패`
- `이미지`
- `전체`
- `미확정`
- `확정`
- `오류`
- `미라벨`
- `이미지 폴더 선택`
- `이미지 폴더를 선택하면 라벨링을 시작할 수 있어요.`
- `원본 이미지는 수정되지 않아요.`

Avoid corrupted or mixed-language strings in visible UI.

English technical terms can remain where they are standard:

- COCO
- bbox
- export if paired with Korean is awkward, prefer `COCO 내보내기`.

## Behavior Requirements

- The image folder action must be available from both top bar and empty center
  state when the project has no images.
- The same image folder selection logic should be reused for both entry points.
- Returning to project home must keep the save-before-navigation behavior.
- Save status must remain visible.
- Export must remain available even when images are unconfirmed.
- Existing keyboard shortcuts must keep working.
- The UI must not add modals for normal repetitive work.

## Testing Requirements

Widget tests should cover:

- Empty project workbench shows the primary image-folder CTA in the center.
- Tapping the center CTA imports images through the existing folder path
  provider.
- Workbench top bar still shows project home, save status, image folder, and
  COCO export actions.
- Left panel empty state shows image folder CTA when there are no images.
- Existing image selection, label assignment, confirmation, reconnect, and
  export warning tests still pass.

Visual regressions to manually inspect:

- Empty project at 1366x768.
- Empty project at 1024x768.
- Project with image list at 1366x768.
- Long project name.
- Narrow enough window where top bar actions approach overflow.

## Non-Goals

- Do not redesign the project home in this pass.
- Do not change annotation data models.
- Do not change COCO export behavior.
- Do not add account, cloud, or collaboration features.
- Do not add a permanent project switcher sidebar.
- Do not introduce a new design dependency unless already available in the
  project.

## Acceptance Criteria

- The workbench no longer looks like a raw prototype in the empty project state.
- The primary next action is obvious when there are no images.
- The top bar has clear hierarchy between context, status, and actions.
- The left and right panels feel like finished desktop tool panels.
- Empty states explain what to do next without long tutorial text.
- Existing labeling, saving, returning home, reconnecting folders, and COCO
  export behavior still works.
