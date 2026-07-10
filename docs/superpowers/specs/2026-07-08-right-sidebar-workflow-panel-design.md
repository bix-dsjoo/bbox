# Right Sidebar Workflow Panel Design

## Goal

Redesign the right sidebar so it helps a labeling worker finish the current
image quickly.

The sidebar should no longer behave like a full information inspector. It
should answer one practical question:

```text
What do I need to do to complete this image?
```

This design removes or lowers information that does not help the repeated
labeling loop, including automatic-box origin, constant coordinates, area, and
large destructive actions.

## Product Principles

This pass follows the previously researched Toss UX principles:

- Easy to answer: show the next action instead of exposing many parallel facts.
  https://toss.tech/article/insurance-claim-process
- User perspective: internal concepts such as automatic/proposal box origin are
  not the worker's main concern.
  https://toss.tech/article/thinking-user-perspective
- Recommend one clear path: the primary path is label unfinished boxes, then
  complete and move on.
  https://toss.tech/article/recommend-just-one
- Patterned components: box rows should use one consistent hierarchy and avoid
  competing colors.
  https://toss.tech/article/toss-design-system

## Accepted Direction

Use the right sidebar as a workflow panel:

1. Show current image name and a compact work summary.
2. Keep `완료하고 다음` / `객체 없음, 다음` as the primary action.
3. Show completion blockers directly below the primary action.
4. Group boxes by worker-facing state: `라벨 필요`, then `완료`, then
   `문제 있음`.
5. Remove `자동 박스` from the right sidebar's normal box rows.
6. Move coordinates and area out of every box row and into a low-priority
   selected-detail area.
7. Move `이미지 제거` out of the main action stack and into a small overflow
   action.
8. Reduce color usage so label colors, selection, and errors do not compete.

## Information Hierarchy

### Current Structure To Replace

The current right sidebar roughly shows:

```text
선택 이미지
file name
image size
status badge
[완료하고 다음]
[이미지 제거]
helper/blocker text

박스
box rows with label/status/coordinates/area

선택 박스
x/y/w/h/area
```

This is too inspector-like. File metadata, destructive actions, and coordinate
data appear at almost the same level as the repeated completion workflow.

### New Structure

For an image with unfinished boxes:

```text
file_name.jpg
박스 5개 · 라벨 필요 2개

[완료하고 다음]
라벨 필요 박스 2개

라벨 필요
[라벨 필요]
[라벨 필요]

완료
[Walnut Donut]
[Croffle]
[Waffle]

상세
선택 박스 x 10 · y 20 · w 40 · h 50
이미지 1920 x 1080
```

For an image with no boxes:

```text
file_name.jpg
박스 없음

[객체 없음, 다음]

상세
이미지 1920 x 1080
```

For a completed/ready-to-complete image:

```text
file_name.jpg
박스 5개 · 라벨 완료

[완료하고 다음]

완료
[Walnut Donut]
[Croffle]
[Waffle]
```

## Copy Rules

Use worker-facing terms only.

Keep:

- `박스 없음`
- `박스 N개 · 라벨 필요 N개`
- `라벨 완료`
- `라벨 필요`
- `완료하고 다음`
- `객체 없음, 다음`
- `문제 있음 이미지는 완료할 수 없습니다`
- `이미지 밖 박스 N개`

Remove from normal right-sidebar rows:

- `선택 이미지`
- `선택 박스`
- `자동 박스`
- `후보`
- `미라벨`
- `확정`
- `area`

The app may still use automatic/proposal internally. The right sidebar should
not make that origin a primary user concept.

## Automatic Box Origin

The worker does not care whether a visible box came from automatic detection or
manual drawing during normal labeling. They care whether it needs a label.

Rules:

- A proposal box with no label displays as `라벨 필요`.
- A manual box with no label also displays as `라벨 필요`.
- A labeled box displays the label name.
- `자동 박스` should not appear in the right sidebar's normal box row status.
- Do not show automatic/manual origin anywhere in the right sidebar in this
  pass.
- Canvas overlay styling can still use neutral gray to communicate unlabeled
  boxes visually.

## Header

Remove the `선택 이미지` section title.

The file name becomes the panel header:

```text
file_name.jpg
```

Below it, show a compact work summary:

```text
박스 5개 · 라벨 필요 2개
```

Summary rules:

- No boxes: `박스 없음`
- Some unlabeled boxes: `박스 N개 · 라벨 필요 N개`
- All boxes labeled: `박스 N개 · 라벨 완료`
- Error image: include `문제 있음` in the status area or blocker message.

Image dimensions are not part of the header. Move them to detail.

## Primary Action

Keep one prominent primary action:

- `완료하고 다음`
- `객체 없음, 다음`

When disabled, show one short blocker immediately below it:

- `라벨 필요 박스 N개`
- `이미지 밖 박스 N개`
- `문제 있음 이미지는 완료할 수 없습니다`

Do not show a modal for normal completion blockers.

## Image Remove Action

`이미지 제거` is rare and destructive. It should not sit directly under the
primary completion action.

Move it to a small overflow menu near the header.

Recommended UI:

```text
file_name.jpg                       [...]
```

Menu item:

```text
이미지 제거
```

Keep the existing confirmation dialog before removing an image.

## Box List

### Grouping

Group visible boxes by work state:

1. `라벨 필요`
2. `완료`
3. `문제 있음`

Within each group, preserve image box order.

If a group is empty, omit it. Do not show empty group headings.

### Row Content

Rows should be compact.

Unlabeled row:

```text
라벨 필요
```

Labeled row:

```text
Walnut Donut
```

Problem row:

```text
문제 있음
```

Do not show x/y/w/h/area in every row.

### Selection

The selected row uses a subtle background or border. It should not need a strong
status badge to be understood.

Clicking a row still selects the same box on the canvas.

## Color Rules

The right sidebar should use less color than the canvas.

Rules:

- Label color appears as one small dot or thin strip.
- `라벨 필요` uses text and very subtle neutral styling, not a strong badge.
- `문제 있음` may use red text or a small warning icon.
- Selection uses a light background or border.
- Do not use both a strong colored strip and a strong colored status badge in
  the same row.
- Do not use automatic-box gray as a major right-sidebar state color.

The canvas can remain more visually expressive because it is where boxes are
edited. The sidebar should stay calm and scannable.

## Details Area

Move technical metadata to a lower-priority `상세` area.

Show:

- Selected box coordinates, only when a box is selected.
- Selected box area if still useful.
- Image dimensions.

Recommended default:

```text
상세
선택 박스 x 10 · y 20 · w 40 · h 50
이미지 1920 x 1080
```

If no box is selected:

```text
상세
이미지 1920 x 1080
```

This area is always visible in a small, low-emphasis style for this pass.

## Empty States

No selected image:

```text
이미지를 선택하세요
```

Do not repeat a long explanation if the center canvas already has the primary
empty state.

No boxes in selected image:

```text
박스 없음
[객체 없음, 다음]
```

Do not show a separate sentence explaining that the image can be completed as no
objects in this pass.

## Non-Goals

- Do not change annotation data models.
- Do not change COCO export behavior.
- Do not change detector behavior.
- Do not remove automatic box functionality from the canvas toolbar.
- Do not change canvas overlay semantics in this pass.
- Do not add advanced sorting, search, or filters.
- Do not add a collapsible panel system in this pass.

## Implementation Notes

- Keep the right sidebar implementation in `lib/ui/workbench_screen.dart` for
  this pass.
- The internal `BoxStatus.proposal` remains unchanged.
- `_boxStatusLabel` may still exist for canvas or other contexts, but right
  sidebar box rows should use worker-facing row labels.
- Add helper getters/functions for:
  - visible unlabeled boxes
  - visible labeled boxes
  - visible invalid boxes
  - image work summary text
- Preserve row-to-canvas selection behavior.
- Preserve completion and `Ctrl+Enter` behavior from the workflow speed work.
- Preserve label shortcut text-input guards.

## Test Coverage

Widget tests should cover:

- Right sidebar no longer shows `선택 이미지`.
- Right sidebar header shows file name and compact work summary.
- Right sidebar does not show `자동 박스` in normal box rows.
- Unlabeled proposal boxes display as `라벨 필요`.
- Manual unlabeled boxes also display as `라벨 필요` if covered by fixtures.
- Box rows do not show coordinate text by default.
- Selected box coordinates appear in the detail area.
- `이미지 제거` is available from an overflow action, not as a large button
  directly under completion.
- Boxes are grouped with `라벨 필요` before `완료`.
- Clicking a row still selects the box.
- Completion blocker remains directly below the primary action.

Manual checks:

- Image with no boxes.
- Image with two unlabeled boxes and three labeled boxes.
- Image with only labeled boxes.
- Image with an invalid box.
- Long file name.
- Narrow right sidebar width.

## Acceptance Criteria

- The right sidebar reads as a work-progress panel, not a technical inspector.
- The primary completion action is visually dominant.
- A worker can immediately see how many boxes still need labels.
- Automatic/proposal origin is not presented as a normal sidebar concept.
- Box rows are calmer and shorter.
- Technical details are still available, but lower priority.
- Existing selection, label assignment, completion, save/load, and export
  behavior still works.
- `flutter analyze`, relevant widget tests, and the full test suite pass after
  implementation.
