# Tight Bread Box Model Improvement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and run a reproducible training pipeline that reduces bread detections whose boxes fall inside the visible bread boundary on overhead multi-bread scenes.

**Architecture:** Add a focused Python package under `tools/modeling/tight_box/` for immutable input auditing, reviewed COCO handling, foreground extraction, fold-safe synthesis, runtime-equivalent evaluation, and Ultralytics training orchestration. Treat `C:\workspace\bakery_vision\data\raw\bixolon_bakery` as read-only, use the five real mixed scenes only for leave-one-scene-out evidence, and publish every generated artifact under ignored `datasets/` and `outputs/` directories with checksums and lineage.

**Tech Stack:** Python 3.12 from `runtime/python/python.exe`, standard-library `unittest`, OpenCV, NumPy, Pillow, Ultralytics YOLOv8, PyTorch CPU inference, JSON/JSONL/CSV artifacts, existing `tools/detectors/bread_box_worker.py` post-processing.

## Global Constraints

- Detector target is one class: `0: bread`; SKU classification is out of scope.
- Target boxes are tight boxes around visible bread pixels with no fixed or proportional padding.
- The source tree `C:\workspace\bakery_vision\data\raw\bixolon_bakery` is read-only.
- The existing `models/bread_yolov8n_1class_tray_v0_2.pt` file must not be overwritten.
- Current source counts are 2,057 single-product images, 5 mixed scenes, and 25 mixed-scene boxes.
- `mini_bread` has no single-product images and must not be synthesized from another label.
- Mixed-scene annotations must be explicitly reviewed before they can enter training or evaluation.
- Each cross-validation fold holds out exactly one real mixed scene from training, synthesis backgrounds, calibration, early stopping, and model selection.
- Synthetic images are training evidence only; release claims use the combined predictions from five held-out real scenes.
- Runtime-compatible evaluation uses `imgsz=640`, `conf=0.40`, `iou=0.55`, `max_results=50`, `min_box_size=45`, and `max_area_ratio=0.38` unless the checked-in experiment config changes all models equally.
- Adoption requires at least 30% fewer undersized matched boxes, improved median ground-truth coverage and IoU, no additional misses, no more than 0.2 additional false positives per image, and less than 20% median Windows CPU latency regression.
- Generated datasets live under `datasets/`; model runs and reports live under `outputs/`; both remain ignored by Git.
- Use TDD for tooling and run Python commands with `C:\workspace\bbox\runtime\python\python.exe`.
- Model promotion and Flutter/package changes are a separate follow-up after the candidate passes review.

---

## File Structure

- Create `tools/modeling/__init__.py`: package marker.
- Create `tools/modeling/tight_box/__init__.py`: exports the pipeline version.
- Create `tools/modeling/tight_box/contracts.py`: immutable paths, SHA-256, atomic JSON writes, and input-count contracts.
- Create `tools/modeling/tight_box/coco.py`: COCO loading, validation, one-class conversion, review-state enforcement, and overlay rendering.
- Create `tools/modeling/tight_box/foregrounds.py`: foreground-mask extraction, quality metrics, manifest writing, and contact sheets.
- Create `tools/modeling/tight_box/synthesis.py`: deterministic compositing, tight-mask boxes, fold construction, and leakage checks.
- Create `tools/modeling/tight_box/metrics.py`: IoU matching, under-size metrics, aggregate comparisons, and adoption gates.
- Create `tools/modeling/tight_box/evaluate.py`: runtime-equivalent inference, latency collection, overlays, and report writing.
- Create `tools/modeling/tight_box/train.py`: Ultralytics fold/candidate orchestration and run manifests.
- Create `tools/experiments/tight_bread_box_pipeline.py`: thin CLI with `audit`, `render-review`, `extract-foregrounds`, `build-folds`, `evaluate`, `train`, and `compare` subcommands.
- Create `configs/training/tight_bread_box_v0_3.json`: fixed experiment configuration.
- Create `test/tools/tight_box/`: tests mirroring each focused module.
- Create `docs/training/tight-bread-box-workflow.md`: operator commands, review gate, artifact locations, and recovery instructions.
- Generate `datasets/tight_bread_box_v0_3/`: approved foregrounds and five fold datasets.
- Generate `outputs/tight_bread_box_v0_3/`: audits, review sheets, predictions, training runs, comparisons, and the unpromoted final candidate.

---

### Task 1: Immutable Input Audit and Artifact Contracts

**Files:**
- Create: `tools/modeling/__init__.py`
- Create: `tools/modeling/tight_box/__init__.py`
- Create: `tools/modeling/tight_box/contracts.py`
- Create: `tools/experiments/tight_bread_box_pipeline.py`
- Create: `test/tools/tight_box/__init__.py`
- Create: `test/tools/tight_box/test_contracts.py`

**Interfaces:**
- Produces: `PIPELINE_VERSION = "tight-bread-box-v0.3.0"`
- Produces: `sha256_file(path: Path) -> str`
- Produces: `atomic_write_json(path: Path, payload: Mapping[str, object]) -> None`
- Produces: `audit_source(source_root: Path) -> dict[str, object]`
- Consumes: raw source layout from the approved design.

- [ ] **Step 1: Write failing contract tests**

Create `test/tools/tight_box/test_contracts.py` with tests that build a temporary source tree containing `images/a/one.jpg`, five mixed JPEGs, a COCO file with 25 annotations, and `labels.json` with 20 labels. Assert that `audit_source()` reports exact counts, includes SHA-256 values, reports zero errors, and does not change the source checksums. Add separate tests for a missing mixed image and for `mini_bread` having no source image.

```python
class SourceAuditTest(unittest.TestCase):
    def test_audit_reports_contract_counts_without_mutating_source(self):
        source = make_source_tree(single_count=2057, mixed_count=5, box_count=25)
        before = tree_hashes(source)
        report = contracts.audit_source(source)
        self.assertEqual(report["counts"], {
            "single_images": 2057,
            "mixed_images": 5,
            "mixed_boxes": 25,
            "labels": 20,
        })
        self.assertEqual(report["errors"], [])
        self.assertEqual(tree_hashes(source), before)
```

- [ ] **Step 2: Run the tests and confirm the missing module failure**

Run:

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.tight_box.test_contracts -v
```

Expected: import failure for `tools.modeling.tight_box.contracts`.

- [ ] **Step 3: Implement focused audit contracts**

Implement `contracts.py` with safe relative-path resolution, streaming SHA-256, JPEG signature/decode checks, COCO reference checks, label-registry checks, and atomic JSON output. The public audit result must have this stable shape:

```python
{
    "schema_version": "source-audit-v1",
    "pipeline_version": PIPELINE_VERSION,
    "source_root": str(source_root.resolve()),
    "counts": {
        "single_images": int,
        "mixed_images": int,
        "mixed_boxes": int,
        "labels": int,
    },
    "source_files": [{"path": str, "sha256": str, "bytes": int}],
    "warnings": [{"code": str, "message": str}],
    "errors": [{"code": str, "message": str}],
}
```

Reject absolute and parent-traversal paths in metadata. Report the expected empty `mini_bread` directory as warning code `missing_single_product_coverage`, not as an invented sample or fatal error.

- [ ] **Step 4: Run contract tests and the real read-only audit**

Run:

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.tight_box.test_contracts -v
& C:\workspace\bbox\runtime\python\python.exe tools\experiments\tight_bread_box_pipeline.py audit `
  --source C:\workspace\bakery_vision\data\raw\bixolon_bakery `
  --output outputs\tight_bread_box_v0_3\audit\source_audit.json
```

Expected: tests pass; the real report contains 2,057 single images, 5 mixed images, 25 boxes, 20 labels, no fatal errors, and a `mini_bread` coverage warning.

- [ ] **Step 5: Commit the contract slice**

```powershell
git add tools/modeling tools/experiments/tight_bread_box_pipeline.py test/tools/tight_box
git commit -m "feat: audit tight box training inputs"
```

---

### Task 2: Reviewed COCO Gate and Tight-Box Review Assets

**Files:**
- Create: `tools/modeling/tight_box/coco.py`
- Create: `test/tools/tight_box/test_coco.py`
- Modify: `tools/experiments/tight_bread_box_pipeline.py`

**Interfaces:**
- Consumes: `audit_source()` output and the raw mixed-scene COCO file.
- Produces: `load_reviewed_coco(path: Path, image_root: Path) -> CocoDataset`
- Produces: `to_one_class(dataset: CocoDataset) -> CocoDataset`
- Produces: `render_review_sheets(dataset: CocoDataset, image_root: Path, output: Path) -> list[Path]`
- Produces: `write_one_class_coco(dataset: CocoDataset, output: Path) -> None`
- `CocoDataset` contains immutable `images`, `annotations`, and `categories` records with pixel `xywh` boxes.

- [ ] **Step 1: Write failing COCO validation tests**

Add tests for image-boundary validation, zero-area rejection, missing-image rejection, all-category collapse to category `1: bread`, and review-state enforcement.

```python
def test_load_reviewed_coco_rejects_unreviewed_annotations(self):
    coco_path, image_root = write_coco_fixture(review_status="unreviewed")
    with self.assertRaisesRegex(ValueError, "annotation 1 is not reviewed"):
        coco.load_reviewed_coco(coco_path, image_root)

def test_one_class_conversion_preserves_geometry(self):
    dataset = coco.load_reviewed_coco(*write_coco_fixture(review_status="reviewed"))
    converted = coco.to_one_class(dataset)
    self.assertEqual(converted.categories, ({"id": 1, "name": "bread"},))
    self.assertEqual(converted.annotations[0].bbox, dataset.annotations[0].bbox)
    self.assertEqual(converted.annotations[0].category_id, 1)
```

- [ ] **Step 2: Verify the tests fail before implementation**

Run:

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.tight_box.test_coco -v
```

Expected: import or missing-symbol failures.

- [ ] **Step 3: Implement COCO parsing and review enforcement**

Use frozen dataclasses for image and annotation records. A reviewed file is accepted only when `info.review_status == "reviewed"` and every annotation has `attributes.review_status == "reviewed"`. Preserve `source_annotation_id`, clamp nothing silently, and reject invalid coordinates with the image and annotation IDs in the exception.

Render one full-resolution overlay per scene plus a contact sheet. Use green 2-pixel boxes for reviewed annotations, red for invalid candidates, and draw annotation ID plus integer `x,y,w,h`. Do not write corrected coordinates automatically.

- [ ] **Step 4: Add and run the review CLI checkpoint**

Add `render-review` arguments `--source-coco`, `--image-root`, and `--output`. Run it against the raw COCO:

```powershell
& C:\workspace\bbox\runtime\python\python.exe tools\experiments\tight_bread_box_pipeline.py render-review `
  --source-coco C:\workspace\bakery_vision\data\raw\bixolon_bakery\annotations\mixed_scene_instances.json `
  --image-root C:\workspace\bakery_vision\data\raw\bixolon_bakery\mixed_scenes `
  --output outputs\tight_bread_box_v0_3\review\raw
```

Expected: five overlays and one contact sheet. Use the bbox app to create `outputs\tight_bread_box_v0_3\review\mixed_scene_instances_reviewed_v0.3.0.json`, set the top-level and per-annotation review states to `reviewed`, and rerun `load_reviewed_coco`. This is a hard gate: do not start Task 3 until all 25 boxes have been visually checked against the tight-box policy.

- [ ] **Step 5: Run tests and verify the reviewed artifact**

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.tight_box.test_coco -v
& C:\workspace\bbox\runtime\python\python.exe tools\experiments\tight_bread_box_pipeline.py render-review `
  --source-coco outputs\tight_bread_box_v0_3\review\mixed_scene_instances_reviewed_v0.3.0.json `
  --image-root C:\workspace\bakery_vision\data\raw\bixolon_bakery\mixed_scenes `
  --output outputs\tight_bread_box_v0_3\review\reviewed
```

Expected: tests pass; reviewed overlays contain exactly 25 valid boxes and the CLI exits zero.

- [ ] **Step 6: Commit the reviewed-COCO tooling**

```powershell
git add tools/modeling/tight_box/coco.py tools/experiments/tight_bread_box_pipeline.py test/tools/tight_box/test_coco.py
git commit -m "feat: enforce reviewed tight box annotations"
```

Do not add generated review images or reviewed data under `outputs/` to Git.

---

### Task 3: Foreground Extraction, Quality Manifest, and Contact Sheets

**Files:**
- Create: `tools/modeling/tight_box/foregrounds.py`
- Create: `test/tools/tight_box/test_foregrounds.py`
- Modify: `tools/experiments/tight_bread_box_pipeline.py`

**Interfaces:**
- Consumes: single-product image paths from the raw manifest.
- Produces: `extract_foreground(image: np.ndarray) -> ForegroundResult`
- Produces: `mask_tight_box(mask: np.ndarray) -> tuple[int, int, int, int]`
- Produces: `assess_foreground(image: np.ndarray, mask: np.ndarray) -> ForegroundQuality`
- Produces: `extract_manifest(source_root: Path, output_root: Path, config: Mapping[str, object]) -> dict[str, object]`
- `ForegroundResult` contains BGR crop, uint8 mask, source-space box, and quality signals.

- [ ] **Step 1: Write failing mask and quality tests**

Use generated ellipse fixtures with a dark rim, disconnected warm noise, and a border-touching object. Assert the tight box equals the nonzero mask bounds, detached noise is removed, GrabCut can expand beyond a warm-color seed to the dark rim, and border-touching or empty masks are rejected.

```python
def test_mask_tight_box_has_no_padding(self):
    mask = np.zeros((80, 100), dtype=np.uint8)
    mask[12:61, 20:76] = 255
    self.assertEqual(foregrounds.mask_tight_box(mask), (20, 12, 56, 49))

def test_quality_rejects_border_touching_mask(self):
    mask = np.zeros((80, 100), dtype=np.uint8)
    mask[0:50, 20:76] = 255
    quality = foregrounds.assess_foreground(np.zeros((80, 100, 3), np.uint8), mask)
    self.assertFalse(quality.approved)
    self.assertIn("touches_image_border", quality.reasons)
```

- [ ] **Step 2: Verify the foreground tests fail**

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.tight_box.test_foregrounds -v
```

Expected: missing module or symbol failures.

- [ ] **Step 3: Implement deterministic foreground extraction**

Seed OpenCV GrabCut from the existing warm-bread mask, mark an 8-pixel image border as definite background, mark eroded warm pixels as definite foreground, run five iterations, close only gaps smaller than the configured kernel, and keep the largest connected component. Calculate coverage, border contact, component count before cleanup, hole ratio, and warm-pixel ratio. Store explicit rejection reasons; never turn a rejected asset into an approved one automatically.

Write each approved asset as lossless PNG crop plus single-channel PNG mask. Write `foregrounds.jsonl` records with this shape:

```json
{"schema_version":"foreground-v1","source_relative_path":"images/bagel/example.jpg","source_sha256":"0000000000000000000000000000000000000000000000000000000000000000","label_id":"bagel","crop_path":"crops/000001.png","mask_path":"masks/000001.png","mask_sha256":"1111111111111111111111111111111111111111111111111111111111111111","tight_box_xywh":[12,8,420,315],"quality_status":"approved","reasons":[]}
```

- [ ] **Step 4: Run extraction on a sample and inspect the contact sheet**

```powershell
& C:\workspace\bbox\runtime\python\python.exe tools\experiments\tight_bread_box_pipeline.py extract-foregrounds `
  --source C:\workspace\bakery_vision\data\raw\bixolon_bakery `
  --output datasets\tight_bread_box_v0_3\foregrounds_smoke `
  --limit 100 `
  --seed 7132026
```

Expected: a JSONL manifest, crop/mask PNGs, a quality summary, and a contact sheet with the mask outline and tight box. Visually reject systematic rim clipping before processing all images.

- [ ] **Step 5: Run the full extraction and verify lineage**

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.tight_box.test_foregrounds -v
& C:\workspace\bbox\runtime\python\python.exe tools\experiments\tight_bread_box_pipeline.py extract-foregrounds `
  --source C:\workspace\bakery_vision\data\raw\bixolon_bakery `
  --output datasets\tight_bread_box_v0_3\foregrounds `
  --seed 7132026
```

Expected: tests pass; summary totals equal 2,057 input images; approved plus rejected equals 2,057; every approved crop and mask checksum verifies; `mini_bread` produces zero assets.

- [ ] **Step 6: Commit the foreground tooling**

```powershell
git add tools/modeling/tight_box/foregrounds.py tools/experiments/tight_bread_box_pipeline.py test/tools/tight_box/test_foregrounds.py
git commit -m "feat: extract reviewed bread foregrounds"
```

---

### Task 4: Deterministic Fold-Safe Synthetic Datasets

**Files:**
- Create: `tools/modeling/tight_box/synthesis.py`
- Create: `test/tools/tight_box/test_synthesis.py`
- Create: `configs/training/tight_bread_box_v0_3.json`
- Modify: `tools/experiments/tight_bread_box_pipeline.py`

**Interfaces:**
- Consumes: reviewed one-class COCO, approved foreground JSONL, background manifest, and experiment config.
- Produces: `transform_foreground(asset: ForegroundAsset, angle_degrees: float, scale: float, brightness_gain: float, perspective: float) -> TransformedForeground`
- Produces: `compose_scene(background: np.ndarray, assets: Sequence[ForegroundAsset], config: ExperimentConfig, rng: random.Random) -> SyntheticScene`
- Produces: `build_folds(inputs: FoldInputs, config: ExperimentConfig, output: Path) -> dict[str, object]`
- Produces: five Ultralytics dataset YAML files with synthetic internal validation sets and five separate held-out real-scene manifests.

- [ ] **Step 1: Write failing deterministic synthesis and leakage tests**

Test that the box equals transformed mask bounds without padding, the same seed produces identical image and label hashes, overlap beyond the configured threshold is rejected, and a held-out scene ID cannot appear in train images or background lineage.

```python
def test_transformed_mask_box_is_exact_nonzero_bounds(self):
    transformed = synthesis.transform_foreground(fixture_foreground(), angle=17, scale=0.7)
    ys, xs = np.where(transformed.mask > 0)
    self.assertEqual(transformed.box_xywh, (
        int(xs.min()), int(ys.min()),
        int(xs.max() - xs.min() + 1),
        int(ys.max() - ys.min() + 1),
    ))

def test_fold_rejects_held_out_background_lineage(self):
    inputs = fold_inputs(background_source_scene_id="scene-3")
    with self.assertRaisesRegex(ValueError, "held-out scene scene-3 leaked"):
        synthesis.build_fold(inputs, held_out_scene_id="scene-3", output=self.output)
```

- [ ] **Step 2: Run synthesis tests and confirm failure**

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.tight_box.test_synthesis -v
```

Expected: missing module or function failures.

- [ ] **Step 3: Implement config and fold builder**

Create `configs/training/tight_bread_box_v0_3.json` with fixed values:

```json
{
  "schema_version": "tight-box-experiment-v1",
  "seed": 7132026,
  "canvas_size": 640,
  "synthetic_train_per_fold": 1200,
  "synthetic_val_per_fold": 200,
  "objects_per_scene": [2, 7],
  "scale_range": [0.18, 0.48],
  "rotation_degrees": [-180, 180],
  "brightness_gain": [0.82, 1.18],
  "perspective_max": 0.04,
  "max_overlap_ratio": 0.18,
  "placement_attempts": 60,
  "mosaic": 0.15,
  "close_mosaic_epochs": 10,
  "imgsz": 640,
  "confidence": 0.4,
  "nms_iou": 0.55,
  "epochs": 60,
  "patience": 12,
  "batch": 8,
  "device": "cpu"
}
```

Use procedural tray/paper backgrounds and only separately registered empty-tray templates. Every background record must contain `source_scene_id`; use `null` for independent empty-tray captures. Do not inpaint or reuse held-out mixed-scene pixels. Each fold must contain four real train scenes and 1,200 synthetic train scenes, plus 200 separately seeded synthetic internal-validation scenes. The held-out real scene is recorded in `heldout.json` and is not referenced by the Ultralytics dataset YAML, early stopping, or checkpoint selection.

- [ ] **Step 4: Build and verify a two-scene smoke fold fixture**

Run the unit fixture CLI mode with 10 synthetic scenes and verify every normalized YOLO coordinate lies in `(0, 1]`, width and height are positive, image/label stems match, and checksums reproduce on a second build.

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.tight_box.test_synthesis -v
```

Expected: all synthesis and leakage tests pass.

- [ ] **Step 5: Build the five real folds**

```powershell
& C:\workspace\bbox\runtime\python\python.exe tools\experiments\tight_bread_box_pipeline.py build-folds `
  --config configs\training\tight_bread_box_v0_3.json `
  --reviewed-coco outputs\tight_bread_box_v0_3\review\mixed_scene_instances_reviewed_v0.3.0.json `
  --mixed-images C:\workspace\bakery_vision\data\raw\bixolon_bakery\mixed_scenes `
  --foregrounds datasets\tight_bread_box_v0_3\foregrounds\foregrounds.jsonl `
  --background-manifest datasets\bread_tray_templates_v0_1\backgrounds.jsonl `
  --output datasets\tight_bread_box_v0_3\folds
```

Expected: five fold directories, five distinct held-out scene IDs, zero leakage errors, 1,200 synthetic plus four real train images per fold, 200 synthetic internal-validation images per fold, one separate real held-out manifest per fold, and a reproducible fold summary.

- [ ] **Step 6: Commit the fold builder**

```powershell
git add tools/modeling/tight_box/synthesis.py tools/experiments/tight_bread_box_pipeline.py test/tools/tight_box/test_synthesis.py configs/training/tight_bread_box_v0_3.json
git commit -m "feat: build leak-free tight box folds"
```

---

### Task 5: Runtime-Equivalent Metrics and Baseline Evaluation

**Files:**
- Create: `tools/modeling/tight_box/metrics.py`
- Create: `tools/modeling/tight_box/evaluate.py`
- Create: `test/tools/tight_box/test_metrics.py`
- Create: `test/tools/tight_box/test_evaluate.py`
- Modify: `tools/experiments/tight_bread_box_pipeline.py`

**Interfaces:**
- Produces: `match_predictions(ground_truth, predictions, min_iou=0.50) -> MatchResult`
- Produces: `box_metrics(gt: Box, prediction: Box) -> dict[str, float | bool]`
- Produces: `aggregate_scene_reports(reports: Sequence[SceneReport]) -> dict[str, object]`
- Produces: `evaluate_model(model_path: Path, dataset: CocoDataset, image_root: Path, output: Path, config: RuntimeConfig) -> dict[str, object]`
- Consumes: `BreadBoxEngine` behavior from `tools/detectors/bread_box_worker.py`.

- [ ] **Step 1: Write failing paired-metric tests**

Test exact matches, an inward box with ratios below 0.95, an oversized box with full coverage but lower IoU, a miss, a false positive, and deterministic greedy one-to-one matching sorted by IoU then confidence.

```python
def test_inward_box_is_counted_as_undersized(self):
    result = metrics.box_metrics(Box(10, 10, 100, 80), Box(15, 14, 88, 69))
    self.assertAlmostEqual(result["width_ratio"], 0.88)
    self.assertAlmostEqual(result["height_ratio"], 0.8625)
    self.assertTrue(result["undersized"])
    self.assertLess(result["ground_truth_coverage"], 1.0)

def test_aggregate_counts_misses_and_false_positives(self):
    aggregate = metrics.aggregate_scene_reports([fixture_scene(matches=1, misses=1, false_positives=2)])
    self.assertEqual(aggregate["matched"], 1)
    self.assertEqual(aggregate["misses"], 1)
    self.assertEqual(aggregate["false_positives"], 2)
```

- [ ] **Step 2: Verify metric tests fail**

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.tight_box.test_metrics test.tools.tight_box.test_evaluate -v
```

Expected: missing module or symbol failures.

- [ ] **Step 3: Implement metrics and runtime inference adapter**

Match boxes at IoU 0.50. For each match record width, height, and area ratios; ground-truth coverage; IoU; confidence; and `undersized = width_ratio < 0.95 or height_ratio < 0.95`. Report per-scene raw observations and medians; never discard misses when calculating adoption gates.

Instantiate one `BreadBoxEngine` per model evaluation, pass original JPEG bytes through `detect_bytes`, collect `time.perf_counter_ns()` latency after one untimed warm-up image, and use the worker's existing post-processing unchanged. Render ground truth in green, baseline/candidate predictions in distinct colors, and label each matched prediction with IoU and width/height ratios.

- [ ] **Step 4: Run metric tests**

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.tight_box.test_metrics test.tools.tight_box.test_evaluate -v
```

Expected: all pure metric and fake-engine evaluation tests pass without loading Ultralytics weights.

- [ ] **Step 5: Produce and freeze the baseline report**

```powershell
& C:\workspace\bbox\runtime\python\python.exe tools\experiments\tight_bread_box_pipeline.py evaluate `
  --model models\bread_yolov8n_1class_tray_v0_2.pt `
  --reviewed-coco outputs\tight_bread_box_v0_3\review\mixed_scene_instances_reviewed_v0.3.0.json `
  --image-root C:\workspace\bakery_vision\data\raw\bixolon_bakery\mixed_scenes `
  --config configs\training\tight_bread_box_v0_3.json `
  --output outputs\tight_bread_box_v0_3\evaluation\baseline
```

Expected: `report.json`, five prediction JSON files, five overlays, a contact sheet, model checksum, reviewed COCO checksum, exactly 25 ground-truth boxes, and seven timed CPU samples after warm-up. Do not change thresholds after this report is frozen.

- [ ] **Step 6: Commit evaluation tooling**

```powershell
git add tools/modeling/tight_box/metrics.py tools/modeling/tight_box/evaluate.py tools/experiments/tight_bread_box_pipeline.py test/tools/tight_box/test_metrics.py test/tools/tight_box/test_evaluate.py
git commit -m "feat: evaluate tight bread box bias"
```

---

### Task 6: Candidate A/B Cross-Validation Training Orchestrator

**Files:**
- Create: `tools/modeling/tight_box/train.py`
- Create: `test/tools/tight_box/test_train.py`
- Modify: `tools/experiments/tight_bread_box_pipeline.py`

**Interfaces:**
- Consumes: five fold YAML files, fixed experiment config, candidate name, and initial weight path.
- Produces: `build_train_args(config: ExperimentConfig, fold_index: int, dataset_yaml: Path, output: Path) -> dict[str, object]`
- Produces: `train_candidate(candidate: CandidateConfig, folds_root: Path, output: Path) -> dict[str, object]`
- Candidate A starts from `models/bread_yolov8n_1class_tray_v0_2.pt`.
- Candidate B starts from repository `yolov8n.pt`.

- [ ] **Step 1: Write failing orchestration tests**

Use a fake YOLO factory to assert five independent models are constructed, each fold gets its own dataset YAML and output directory, fixed `imgsz`, seed, augmentation, and device values are passed, and a failed fold prevents a complete run manifest.

```python
def test_candidate_trains_all_five_folds_with_fixed_arguments(self):
    factory = FakeYoloFactory()
    result = train.train_candidate(candidate_a(), self.folds, self.output, yolo_factory=factory)
    self.assertEqual(len(factory.models), 5)
    self.assertEqual([call["imgsz"] for call in factory.train_calls], [640] * 5)
    self.assertEqual(result["status"], "complete")

def test_failed_fold_does_not_publish_complete_manifest(self):
    factory = FakeYoloFactory(fail_fold=3)
    with self.assertRaisesRegex(RuntimeError, "fold-3"):
        train.train_candidate(candidate_a(), self.folds, self.output, yolo_factory=factory)
    self.assertFalse((self.output / "run_manifest.json").exists())
```

- [ ] **Step 2: Verify orchestration tests fail**

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.tight_box.test_train -v
```

Expected: missing module or function failures.

- [ ] **Step 3: Implement training orchestration**

For every fold instantiate a fresh YOLO object, set seed to `config.seed + fold_index`, and pass these fixed train arguments: `imgsz=640`, `epochs=60`, `patience=12`, `batch=8`, `device="cpu"`, `mosaic=0.15`, `close_mosaic=10`, `degrees=8`, `translate=0.05`, `scale=0.20`, `perspective=0.0004`, `fliplr=0.5`, `flipud=0.0`, and no crop augmentation. Store the exact Ultralytics version, initial weight checksum, fold dataset checksum, arguments, best-weight path, and results CSV checksum.

- [ ] **Step 4: Run tests and one-epoch smoke training**

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.tight_box.test_train -v
& C:\workspace\bbox\runtime\python\python.exe tools\experiments\tight_bread_box_pipeline.py train `
  --candidate current-finetune `
  --initial models\bread_yolov8n_1class_tray_v0_2.pt `
  --folds datasets\tight_bread_box_v0_3\folds `
  --config configs\training\tight_bread_box_v0_3.json `
  --output outputs\tight_bread_box_v0_3\training_smoke\current-finetune `
  --epochs 1 `
  --fold-limit 1
```

Expected: unit tests pass; one fold completes one epoch, writes `best.pt`, and emits a run manifest marked `smoke` rather than `release_candidate`.

- [ ] **Step 5: Run five-fold Candidate A and Candidate B training**

```powershell
& C:\workspace\bbox\runtime\python\python.exe tools\experiments\tight_bread_box_pipeline.py train `
  --candidate current-finetune `
  --initial models\bread_yolov8n_1class_tray_v0_2.pt `
  --folds datasets\tight_bread_box_v0_3\folds `
  --config configs\training\tight_bread_box_v0_3.json `
  --output outputs\tight_bread_box_v0_3\training\current-finetune

& C:\workspace\bbox\runtime\python\python.exe tools\experiments\tight_bread_box_pipeline.py train `
  --candidate coco-finetune `
  --initial yolov8n.pt `
  --folds datasets\tight_bread_box_v0_3\folds `
  --config configs\training\tight_bread_box_v0_3.json `
  --output outputs\tight_bread_box_v0_3\training\coco-finetune
```

Expected: ten fold `best.pt` files and two complete run manifests. If CPU time is excessive, stop cleanly and record the incomplete run; do not silently reduce folds, epochs, or data volume.

- [ ] **Step 6: Commit the training orchestrator**

```powershell
git add tools/modeling/tight_box/train.py tools/experiments/tight_bread_box_pipeline.py test/tools/tight_box/test_train.py
git commit -m "feat: orchestrate tight box candidate training"
```

---

### Task 7: Fold Evaluation, Adoption Gates, and Final Candidate

**Files:**
- Modify: `tools/modeling/tight_box/metrics.py`
- Modify: `tools/modeling/tight_box/evaluate.py`
- Modify: `tools/modeling/tight_box/train.py`
- Modify: `tools/experiments/tight_bread_box_pipeline.py`
- Create: `test/tools/tight_box/test_compare.py`

**Interfaces:**
- Produces: `compare_candidate(baseline: Report, candidate: Report) -> AdoptionDecision`
- Produces: `evaluate_cross_validation(run_manifest: Path, folds_root: Path, output: Path) -> dict[str, object]`
- Produces: `select_candidate(decisions: Sequence[AdoptionDecision], output: Path) -> dict[str, object]`
- Produces: `train_final_candidate(selected: CandidateConfig, all_real_dataset: Path, output: Path) -> Path`
- `AdoptionDecision` contains individual booleans and measured deltas for all six gates.

- [ ] **Step 1: Write failing adoption-gate tests**

Create paired fixture reports and verify all gates use explicit inequalities. Include failures for exactly unchanged coverage, one extra miss, `+0.21` false positives per image, and exactly `+20%` latency.

```python
def test_adoption_requires_all_gates(self):
    decision = metrics.compare_candidate(improved_baseline(), passing_candidate())
    self.assertTrue(decision.adopt)
    self.assertTrue(all(decision.gates.values()))

def test_one_additional_miss_blocks_adoption(self):
    candidate = passing_candidate(misses=improved_baseline().misses + 1)
    decision = metrics.compare_candidate(improved_baseline(), candidate)
    self.assertFalse(decision.adopt)
    self.assertFalse(decision.gates["no_additional_misses"])
```

- [ ] **Step 2: Verify comparison tests fail**

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.tight_box.test_compare -v
```

Expected: missing comparison interface failure.

- [ ] **Step 3: Implement fold aggregation and adoption decisions**

For each candidate, evaluate fold `n`'s `best.pt` only on fold `n`'s single held-out scene. Concatenate raw matched-box observations across folds before calculating medians. Compare against the frozen baseline predictions for the same scene IDs. Write `decision.json` with measured baseline value, candidate value, delta, threshold, pass/fail, and a final `adopt` boolean.

- [ ] **Step 4: Evaluate both candidates and select by gates**

```powershell
& C:\workspace\bbox\runtime\python\python.exe tools\experiments\tight_bread_box_pipeline.py compare `
  --baseline outputs\tight_bread_box_v0_3\evaluation\baseline\report.json `
  --run outputs\tight_bread_box_v0_3\training\current-finetune\run_manifest.json `
  --folds datasets\tight_bread_box_v0_3\folds `
  --output outputs\tight_bread_box_v0_3\comparison\current-finetune

& C:\workspace\bbox\runtime\python\python.exe tools\experiments\tight_bread_box_pipeline.py compare `
  --baseline outputs\tight_bread_box_v0_3\evaluation\baseline\report.json `
  --run outputs\tight_bread_box_v0_3\training\coco-finetune\run_manifest.json `
  --folds datasets\tight_bread_box_v0_3\folds `
  --output outputs\tight_bread_box_v0_3\comparison\coco-finetune
```

Expected: each candidate has five scene reports, one combined report, paired overlays, and one adoption decision. Select a candidate only if `adopt=true`; if both pass, choose the one with fewer undersized boxes, then higher median IoU, then lower latency.

Write the deterministic selection artifact:

```powershell
& C:\workspace\bbox\runtime\python\python.exe tools\experiments\tight_bread_box_pipeline.py select `
  --decision outputs\tight_bread_box_v0_3\comparison\current-finetune\decision.json `
  --decision outputs\tight_bread_box_v0_3\comparison\coco-finetune\decision.json `
  --output outputs\tight_bread_box_v0_3\comparison\selection.json
```

Expected: `selection.json` contains `selected_candidate`, `selected_initial_weight`, `selected_run_manifest`, the tie-break observations, and `adopt=true`. The command exits nonzero and writes a `no_candidate_passed.json` report when neither candidate passes.

- [ ] **Step 5: Train the selected configuration on all five real scenes**

Build a final dataset containing all five reviewed real scenes plus the approved synthetic training set. Train from the selected initial weight family using the unchanged configuration and write the result to a new versioned path:

```powershell
& C:\workspace\bbox\runtime\python\python.exe tools\experiments\tight_bread_box_pipeline.py train-final `
  --selection outputs\tight_bread_box_v0_3\comparison\selection.json `
  --reviewed-coco outputs\tight_bread_box_v0_3\review\mixed_scene_instances_reviewed_v0.3.0.json `
  --folds datasets\tight_bread_box_v0_3\folds `
  --config configs\training\tight_bread_box_v0_3.json `
  --output outputs\tight_bread_box_v0_3\final\bread_yolov8n_1class_tight_v0_3
```

Expected: `best.pt`, `model_card.json`, training results, exact input hashes, and a statement that release evidence comes from cross-validation rather than this all-data run. If `selection.json` does not exist because neither candidate passed, skip this step and retain the existing runtime model.

- [ ] **Step 6: Run comparison tests and commit gate logic**

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.tight_box.test_compare -v
git add tools/modeling/tight_box/metrics.py tools/modeling/tight_box/evaluate.py tools/modeling/tight_box/train.py tools/experiments/tight_bread_box_pipeline.py test/tools/tight_box/test_compare.py
git commit -m "feat: gate tight box model candidates"
```

---

### Task 8: Workflow Documentation and End-to-End Verification

**Files:**
- Create: `docs/training/tight-bread-box-workflow.md`
- Modify: `models/README.md`
- Test: all Python tooling and existing detector worker tests.

**Interfaces:**
- Consumes: completed audit, reviewed COCO, foreground manifest, fold manifests, baseline report, candidate reports, and optional final candidate.
- Produces: a reproducible operator workflow and a final verification record.

- [ ] **Step 1: Write the operator workflow**

Document the exact commands from Tasks 1–7, the tight-box review policy, the hard review checkpoint, generated artifact tree, restart behavior, CPU-time expectation, failure recovery, and the rule that the final candidate remains under `outputs/` until a separate promotion change.

- [ ] **Step 2: Document the unpromoted candidate naming rule**

Add to `models/README.md` that experimental candidates such as `bread_yolov8n_1class_tight_v0_3.pt` are not runtime assets until cross-validation gates pass and packaging is updated in a separate change. Keep `bread_yolov8n_1class_tray_v0_2.pt` as the only named product runtime model in this plan.

- [ ] **Step 3: Run the focused Python suite**

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest discover -s test\tools -p "test_*.py" -v
```

Expected: all existing worker/synthesis tests and all new tight-box tests pass.

- [ ] **Step 4: Run static and source-integrity checks**

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m compileall tools\modeling tools\experiments\tight_bread_box_pipeline.py
git diff --check
& C:\workspace\bbox\runtime\python\python.exe tools\experiments\tight_bread_box_pipeline.py audit `
  --source C:\workspace\bakery_vision\data\raw\bixolon_bakery `
  --output outputs\tight_bread_box_v0_3\audit\source_audit_after.json
```

Expected: compilation and diff checks pass; before/after source-file checksum maps are identical.

- [ ] **Step 5: Verify final evidence or documented non-adoption**

If a candidate passed, verify that its decision report satisfies every gate, all five held-out scenes appear exactly once, the final candidate checksum is recorded, and the old model checksum is unchanged. If no candidate passed, verify that both decision reports identify the failed gates and that no final candidate was promoted.

- [ ] **Step 6: Commit documentation**

```powershell
git add docs/training/tight-bread-box-workflow.md models/README.md
git commit -m "docs: record tight box model workflow"
```

---

## Execution Checkpoints

1. Stop after Task 2 until all 25 real boxes are visibly reviewed and the reviewed COCO passes the hard gate.
2. Stop after the 100-image foreground smoke extraction if the contact sheet shows systematic bread-rim clipping.
3. Freeze the baseline report before training and never tune thresholds against candidate results.
4. Do not continue to final all-data training unless at least one candidate passes every adoption gate.
5. Do not copy the final candidate into `models/` in this plan.

## Completion Evidence

- Git-tracked tooling, tests, config, and workflow documentation.
- Read-only source audit reports with identical before/after hashes.
- Reviewed 25-box COCO artifact and overlays under `outputs/`.
- Approved/rejected foreground manifest totaling 2,057 inputs.
- Five deterministic, leak-free fold manifests.
- Frozen baseline report and two cross-validation candidate reports.
- Explicit adoption decision for every candidate.
- Optional unpromoted final candidate plus model card when a candidate passes.
- Passing focused Python suite, compile check, and `git diff --check`.
