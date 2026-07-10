# Tray-Based Training Data Design

## Goal

Improve automatic bread bounding-box proposals for the real operating setup where bread is placed on a wooden tray with white liner paper over a dark table.

The current detector can find many bread objects, but on real tray images it also emits large grouped boxes that cover multiple breads. The next training dataset should teach the detector that tray borders, liner paper, dark table regions, and full bread groups are not the target. The target remains individual bread objects.

## Current Context

The current detection model is trained as a one-class YOLO detector:

- Class `0`: `bread`
- Existing synthetic dataset: `outputs/training/bixolon_bread_yolo_synth_v0.1.0`
- Existing model output: `models/bread_yolov8n_1class_best.pt`

The existing synthetic generator creates simple dark backgrounds, simple tray-like rectangles, white paper blocks, and pasted bread cutouts. This is useful, but it is less realistic than the operating images because it does not strongly model the real tray perspective, wooden rim, liner placement, lighting, shadows, and bread overlap.

## Recommended Strategy

Use three dataset roles together:

1. Real tray negative images
2. Real tray template based synthetic images
3. Real operating evaluation images

These roles must stay separate. Negative images and synthetic images are training inputs. Evaluation images are held out so they can measure whether the model improves in the real operating environment.

AI-generated empty tray images can be used as supplemental training assets in the first two roles. They are useful for quickly increasing variation, but they should not replace real empty tray photos because generated images may miss camera noise, lens behavior, lighting quirks, and subtle tray-paper details from the actual operating setup.

## Dataset Layout

Recommended local structure:

```text
datasets/
  bread_tray_negatives_v0_1/
    generated/
    images/
      train/
      val/
    labels/
      train/
      val/
    dataset.yaml

  bread_tray_templates_v0_1/
    generated/
    real/

  bread_tray_synth_v0_2/
    images/
      train/
      val/
    labels/
      train/
      val/
    dataset.yaml

  bread_tray_eval_v0_1/
    images/
    labels/
    dataset.yaml

outputs/
  training/
    bread_yolov8n_1class_tray_v0_2/
```

`datasets/` is ignored as local development data. The trained runtime model that the app uses should still be copied intentionally into `models/` after evaluation.

## Negative Images

Negative images are images with no bread annotations. They should use empty YOLO label files with matching stems.

Examples:

- Empty wooden tray
- Wooden tray with liner paper only
- Dark table only
- Tray with crumbs or small non-bread marks
- Tray at slightly different rotations and crop positions
- AI-generated empty tray images that visually match the operating setup

Do not add a `tray` class. The detector target remains only `bread`. The value of negative images is that the model sees tray and paper features without a bread label.

Recommended proportion:

- Start with 5-15% negative images in train and validation.
- Keep validation negatives separate enough to confirm false positives on empty trays are reduced.

## Tray-Based Synthetic Images

Synthetic generation should use real empty tray photographs as background templates instead of only drawing rectangles.
AI-generated empty tray images can also be included in the template pool as supplemental backgrounds, especially before enough real empty tray photos are collected.

Generation rules:

- Use real empty tray images as the canvas source.
- Mix AI-generated empty tray images into the template pool at a lower priority than real empty tray photos.
- Paste bread cutouts mostly within the liner paper area.
- Allow realistic partial overlap between breads.
- Preserve actual tray perspective and dark-table context.
- Add mild brightness, contrast, blur, and shadow variation.
- Keep labels as individual bread boxes, not group boxes.
- Avoid placing bread unrealistically outside the tray except for a small augmentation rate if real operation can include it.

The current synthetic generator can be extended rather than replaced. Its `make_background` step should accept a template-background mode, and the existing drawn-background mode can remain as a lower-priority augmentation.

## Real Operating Evaluation Images

The provided `E0701.jpg` and `M0711.jpg` are valuable operating samples. They should not be added to training at first.

Use them as a held-out evaluation set:

- Label each individual bread box manually.
- Save them under `datasets/bread_tray_eval_v0_1/`.
- Run the current model and the new tray-trained model on this same set.
- Compare false positives, missed breads, and large grouped boxes.

After enough additional real operating images are collected, split them so some can become training data while at least a small fixed golden evaluation set remains held out.

## Acceptance Criteria

The tray-trained detector is better only if it improves on held-out operating images, not merely on synthetic validation.

Minimum checks:

- Fewer large group boxes on tray images.
- No bread boxes on empty tray negatives.
- Individual bread recall stays high.
- Box boundaries remain useful for human review in the labeling app.
- Detector output still works with the existing conservative classifier stage.

Recommended manual review set:

- `E0701.jpg`
- `M0711.jpg`
- At least 5 empty tray images
- At least 10 more real operating images when available

## Non-Goals

- Do not add tray detection as a product feature.
- Do not change the app COCO export format.
- Do not auto-accept detector boxes as final annotations.
- Do not mix evaluation images into training until a separate held-out set exists.

## Implementation Outline

1. Create a tray evaluation dataset from `E0701.jpg` and `M0711.jpg`.
2. Capture or collect empty tray negative images.
3. Extend the synthetic dataset builder to support real tray template backgrounds.
4. Generate a new YOLO dataset version with synthetic tray images and negatives.
5. Train a new one-class bread detector.
6. Evaluate old versus new detector on the held-out tray evaluation set.
7. Promote the new model into `models/` only if it reduces grouped boxes and empty-tray false positives without harming recall.
