# Review Simplification UX Design

## Goal

User review found three friction points in the current workbench:

- The left image status filters are unclear and make the product feel harder.
- Product terms are too technical.
- Automatically generated boxes are hard to see when gray outlines overlap.

This pass simplifies the labeling workspace without changing annotation data,
COCO export rules, project save/load behavior, or detector behavior.

## Toss UX References

The design follows these Toss Tech principles:

- Easy to answer: ask a question users can answer quickly instead of exposing
  abstract workflow choices.
  https://toss.tech/article/insurance-claim-process
- User perspective: maker-facing concepts are not automatically clear to users.
  https://toss.tech/article/thinking-user-perspective
- Recommend one clear path: reduce unnecessary choices when one path is usually
  best.
  https://toss.tech/article/recommend-just-one
- Patterned components: repeated UI states should use consistent, predictable
  component behavior.
  https://toss.tech/article/toss-design-system

## Accepted Direction

Use the recommended balanced simplification:

1. Remove the left image status filters completely.
2. Keep a compact image progress summary in the left header.
3. Rename visible terms from system state language to user action language.
4. Improve automatic box visibility while preserving gray as the semantic color
   for unlabeled automatic boxes.

## Left Image List

### Remove Filters

Remove the always-visible filter chips from the left image list:

- All
- Needs review
- Confirmed
- Error
- Unlabeled

The image list should always show all project images in project order.

This means the user no longer has to understand status categories before
starting work. The left panel answers a simpler question:

```text
What image should I work on next?
```

### Keep Progress Summary

Keep the header summary because it helps with long image folders, but write it
in action-centered language.

Target Korean text:

```text
이미지 128장 · 작업 필요 41장 · 완료 80장 · 문제 7장
```

If an encoding-safe reference is needed, the same text is:

```text
\uc774\ubbf8\uc9c0 128\uc7a5 \u00b7 \uc791\uc5c5 \ud544\uc694 41\uc7a5 \u00b7 \uc644\ub8cc 80\uc7a5 \u00b7 \ubb38\uc81c 7\uc7a5
```

The summary is informational only. It should not act like a filter.

### Empty State

The empty left panel keeps the existing primary action:

```text
이미지가 없습니다
라벨링할 이미지 폴더를 선택하세요.
[이미지 추가]
```

## Vocabulary

Visible UI terms should describe what the user needs to do, not the internal
state model.

| Current visible term | New visible term | Reason |
| --- | --- | --- |
| 미확정 | 검토 필요 | Tells the user what to do next. |
| 확정 | 완료 | Shorter and more familiar for a finished item. |
| 오류 | 문제 있음 | Less technical and clearer in lists. |
| 미라벨 | 라벨 필요 | Describes the missing action. |
| 후보 | 자동 박스 | Explains where the box came from. |
| 라벨됨 | 라벨 완료 | Matches the action language. |
| 탐지 중 | 찾는 중 | Avoids model jargon in the UI. |

Encoding-safe target labels:

```text
검토 필요 = \uac80\ud1a0 \ud544\uc694
완료 = \uc644\ub8cc
문제 있음 = \ubb38\uc81c \uc788\uc74c
라벨 필요 = \ub77c\ubca8 \ud544\uc694
자동 박스 = \uc790\ub3d9 \ubc15\uc2a4
라벨 완료 = \ub77c\ubca8 \uc644\ub8cc
찾는 중 = \ucc3e\ub294 \uc911
```

Domain model enum names do not need to change in this pass. `ImageStatus` and
`BoxStatus` can remain as implementation names. Only user-facing copy changes.

COCO remains visible as `COCO 내보내기` because it is a standard export format.

## Automatic Box Visibility

Automatic boxes remain distinct from labeled boxes. They should still read as
gray/unlabeled, but overlapping boxes need stronger contrast.

### Automatic Box Style

For unselected automatic boxes:

- Use a darker neutral stroke than plain `Colors.grey`.
- Add a subtle light outer contrast stroke or equivalent layered border so the
  line remains visible on dark and busy images.
- Keep fill very light and transparent.
- Keep the label chip visible with `자동 박스` or `라벨 필요`.

Recommended colors:

- Outer contrast: white at high opacity.
- Main stroke: `0xff5f6772` or similar neutral gray.
- Fill: same gray at low opacity.

### Selected Automatic Box Style

For the selected automatic box:

- Render above overlapping boxes.
- Use a thicker main stroke.
- Keep resize handles visible with a white contrast border.
- Preserve gray semantic color so users know it still needs a label.

### Labeled Box Style

Labeled boxes continue to use the label color. If a box has a label, it should
not use the automatic gray style.

## Component Behavior

### Image Rows

Rows should continue to show:

- Thumbnail or fallback icon.
- File name.
- Status badge using the new terms.
- Box summary using action language.

Target Korean example:

```text
박스 3개 · 라벨 필요 1개
```

Encoding-safe reference:

```text
\ubc15\uc2a4 3\uac1c \u00b7 \ub77c\ubca8 \ud544\uc694 1\uac1c
```

### Box Rows

Box rows should show:

- Label name, or `라벨 필요` if unlabeled.
- Status badge: `자동 박스`, `라벨 완료`, or `문제 있음`.
- Coordinates and area can remain because this is a labeling tool, but they
  should be visually secondary.

### Export Warning

Export warning copy should use the same language:

- `검토 필요 이미지`
- `라벨 필요한 자동 박스`
- `문제 있는 이미지`

The export behavior does not change. Users can still export with unfinished
images when there are no blocking COCO errors.

## Implementation Notes

- Remove `ImageListFilter` UI usage from the workbench.
- The controller can either remove `ImageListFilter` entirely or leave it
  unused if removal creates unnecessary churn. Prefer removing it if tests stay
  straightforward.
- Replace `controller.filteredImages` usage with the project image list.
- Update widget tests that expect filter chips or filtered image behavior.
- Update copy tests to the new Korean strings.
- Update overlay tests that currently expect `Colors.grey` exactly for selected
  automatic boxes.

## Non-Goals

- Do not redesign project home.
- Do not change project JSON schema.
- Do not change COCO export structure.
- Do not change detector confidence, model selection, or proposal generation.
- Do not add search, sorting, or advanced filtering in this pass.
- Do not hide error states; only rename and present them more clearly.

## Test Coverage

Update or add tests for:

- Left image list no longer renders filter chips.
- Image list always shows all images regardless of status.
- Header summary uses action-centered terms.
- Image status badges use `검토 필요`, `완료`, and `문제 있음`.
- Box status badges use `자동 박스`, `라벨 완료`, and `문제 있음`.
- Export warning uses the same vocabulary.
- Unselected automatic boxes use the new high-contrast gray style.
- Selected automatic boxes remain visually gray but have stronger contrast.
- Assigning a label changes the box to the label color and enables confirmation.

## Acceptance Criteria

- The left image list has no status filter controls.
- A new user can start from the image list without understanding internal
  status categories.
- User-facing terms describe actions or outcomes instead of implementation
  states.
- Automatic boxes remain visibly different from labeled boxes.
- Overlapping automatic boxes are easier to see on dark, light, and busy images.
- Existing label assignment, confirmation, save/load, and COCO export behavior
  still works.
- `flutter analyze` and relevant Flutter tests pass after implementation.
