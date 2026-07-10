# Labeling Workflow Speed Design

## Goal

Improve the real repeated labeling workflow for users who annotate many images
in one session.

The current app has useful tools for box editing, label assignment, and image
confirmation, but the workflow still asks the user to repeatedly decide what to
do next. This pass turns existing capabilities into a faster loop:

```text
Select image -> review/edit boxes -> assign label -> next unfinished box
-> complete image -> next image
```

## Relationship To Previous UX Spec

This design builds on:

- `2026-07-08-review-simplification-ux-design.md`

That spec removes left filters, simplifies terminology, and improves automatic
box visibility. This spec focuses on the repeated work rhythm after those
simplifications.

## Accepted Direction

Use a workflow-first design:

1. Add a primary `Complete and next` action.
2. After assigning a label, automatically select the next box that needs a
   label in the current image.
3. After completing an image, automatically move to the next image that needs
   work.
4. Keep manual selection, undo, and direct editing available.
5. Show short reasons when the current image cannot be completed.

## Core Workflow

The target workflow for a normal image with automatic boxes:

1. User selects an image.
2. User reviews visible boxes.
3. User selects or adjusts a box.
4. User presses a label shortcut.
5. App assigns the label and selects the next box needing a label.
6. User repeats until no boxes need labels.
7. `Complete and next` becomes enabled.
8. User presses the action or shortcut.
9. App marks the image complete and selects the next image needing work.

The target workflow for a no-object image:

1. User selects an image.
2. User sees there are no boxes.
3. `Complete as no objects and next` is enabled.
4. User completes the image and moves to the next image.

## Complete And Next

### UI

Replace or supplement the current confirm button with a workflow-oriented
primary action.

Recommended visible labels:

- If boxes exist: `완료하고 다음`
- If no boxes exist: `객체 없음, 다음`

Encoding-safe references:

```text
완료하고 다음 = \uc644\ub8cc\ud558\uace0 \ub2e4\uc74c
객체 없음, 다음 = \uac1d\uccb4 \uc5c6\uc74c, \ub2e4\uc74c
```

The existing single-image confirmation behavior remains available internally.
The new action performs confirmation and image navigation together.

### Behavior

When invoked:

1. Validate the current image using the existing confirmation rules.
2. If valid, mark it complete.
3. Select the next image that needs work.
4. If no later image needs work, select the next unfinished image before the
   current image.
5. If all images are complete or only error images remain, keep the completed
   image selected and show a short completion message.

### Shortcut

Add a keyboard shortcut:

- Preferred: `Ctrl+Enter`
- Optional secondary: `Enter` when the canvas has focus and no text field is
  active.

Use `Ctrl+Enter` as the safer first implementation because plain Enter may
conflict with text input and future inline editing.

## Auto-Select Next Box Needing Label

### Trigger

After assigning a label through:

- Quick-label chip click.
- Label shortcut key.
- Label selector action, if still present.

### Selection Rule

After the selected box is labeled:

1. Search visible boxes in current image order.
2. Prefer the next box after the current box whose status is not labeled or
   whose `labelId` is null.
3. If none exists after the current box, wrap to the first box needing a label.
4. If no boxes need labels, keep the just-labeled box selected or clear
   selection. Prefer keeping the box selected so the user can immediately undo,
   move, or inspect it.

This behavior should not run after manual box movement or resize. It only runs
after label assignment.

### User Control

Manual selection always wins. If the user clicks another box, the app selects
that box immediately. The auto-selection behavior only happens as a consequence
of label assignment.

Undo restores both the annotation state and the selection state if the existing
undo architecture can support it without broad changes. If selection restoration
requires too much churn, undo must at least restore the annotation data and keep
a valid current selection.

## Next Image Selection

### Definition Of Needs Work

An image needs work when:

- It is in a review state.
- It has boxes needing labels.
- It has valid no-object potential but has not been completed.

Error images are not selected automatically by `Complete and next`; they remain
visible in the list and summary.

### Selection Order

Use project image order.

When moving next:

1. Search from the image after the current image to the end.
2. Pick the first image that needs work.
3. If none exists, search from the beginning to the image before current.
4. If none exists, stay on the current image.

Do not use hidden filters or sorting in this pass.

## Completion Blocker Reasons

When the completion action is disabled, show a short reason near the action.

Examples:

```text
라벨 필요한 박스 2개
이미지 밖 박스 1개
문제 있는 이미지는 완료할 수 없습니다
```

Encoding-safe references:

```text
라벨 필요한 박스 2개 = \ub77c\ubca8 \ud544\uc694\ud55c \ubc15\uc2a4 2\uac1c
이미지 밖 박스 1개 = \uc774\ubbf8\uc9c0 \ubc16 \ubc15\uc2a4 1\uac1c
문제 있는 이미지는 완료할 수 없습니다 = \ubb38\uc81c \uc788\ub294 \uc774\ubbf8\uc9c0\ub294 \uc644\ub8cc\ud560 \uc218 \uc5c6\uc2b5\ub2c8\ub2e4
```

Rules:

- Keep the message to one line when possible.
- Prioritize the most actionable blocker first.
- Do not open a modal for normal completion blockers.

## Left Image List

The left list remains unfiltered, as accepted in the simplification spec.

Enhance navigation by highlighting the current next work target:

- Current selected image keeps the existing selected row style.
- The first image needing work may receive a subtle "next" hint only when no
  image is selected or after all work is completed.
- Avoid adding another persistent status filter or complex queue UI.

Rows continue to show status and a concise box summary.

## Right Inspector

The right inspector should support review and completion, not become the main
place for repeated actions.

Keep:

- Current image details.
- Completion action and blocker reason.
- Box list.
- Selected box coordinates.

Avoid:

- Duplicating the global label bar.
- Requiring scroll to reach the primary completion action.
- Making coordinate data more visually important than label status.

## Box List Priority

Box rows should prioritize the user's next action.

Display order within a row:

1. Label name or `라벨 필요`.
2. Status badge.
3. Coordinates and area as secondary text.

For the selected image, a small section summary can be shown above the list:

```text
박스 5개 · 라벨 필요 2개
```

This helps the user understand why completion is still blocked.

## Non-Goals

- Do not add search, sorting, or advanced filters.
- Do not add custom shortcut settings.
- Do not change project JSON schema unless required for selection restoration.
- Do not change COCO export semantics.
- Do not add cloud, collaboration, or model training behavior.
- Do not make automatic detection run for every image by default.

## Implementation Notes

- Add controller methods for:
  - complete selected image and move to next work image.
  - select next image needing work.
  - select next box needing label after label assignment.
  - compute completion blocker reason.
- Keep existing `confirmSelectedImage` for tests and simple internal use.
- Update quick-label assignment paths to use the new next-box selection rule.
- Update keyboard handling to support `Ctrl+Enter`.
- Ensure text input fields in label management do not trigger canvas-level
  completion shortcuts.

## Test Coverage

Unit tests:

- Completing an image selects the next later image needing work.
- Completing the last unfinished image wraps to earlier unfinished images.
- Completing when no other image needs work keeps selection stable.
- Error images are skipped by automatic next-image selection.
- Label assignment selects the next box needing a label.
- Label assignment wraps to the first unlabeled box when needed.
- Label assignment keeps the current box selected when all boxes are labeled.
- Completion blocker reason reports unlabeled boxes.
- Completion blocker reason reports invalid boxes.

Widget tests:

- The inspector shows `완료하고 다음` for labelable images.
- The no-object state shows `객체 없음, 다음`.
- Disabled completion action shows a short blocker reason.
- Pressing `Ctrl+Enter` completes and advances when the image can be completed.
- Pressing a quick-label shortcut labels the selected box and selects the next
  unlabeled box.
- Manual box selection overrides the auto-selected next box.

Manual checks:

- Label a multi-box image using only number keys and verify focus advances.
- Complete several images in a row using `Ctrl+Enter`.
- Confirm a no-object image and verify the next work image is selected.
- Try to complete an image with one unlabeled box and verify the reason is
  immediately visible.
- Verify Undo after label assignment and completion remains understandable.

## Acceptance Criteria

- A user can process several images without repeatedly clicking the left list.
- A user can label multiple boxes with shortcut keys without manually selecting
  each next unlabeled box.
- The primary completion action advances to the next image needing work.
- The user can still manually select any image or box at any time.
- Disabled completion actions explain the blocker in one short message.
- Existing save/load/export behavior remains unchanged.
- `flutter analyze` and relevant Flutter tests pass after implementation.
