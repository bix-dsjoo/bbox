# Bread Model Data and Evaluation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reproducible read-only catalog, leakage-safe 5-fold dataset, optional synthetic augmentation, detector/classifier/verifier evaluation, and a release pipeline manifest for the 20-label bread workflow.

**Architecture:** A focused `tools/bread_training` Python package reads `C:\workspace\bixolon_bakery` without modifying it, writes derived artifacts under ignored `datasets/` and `outputs/`, and evaluates only real held-out mixed scenes. A single model-selection CLI emits OOF reports and `models/bread_pipeline_manifest.json` only when deterministic detector, classifier, verifier, and latency gates pass.

**Tech Stack:** Python 3.12, `unittest`, OpenCV, NumPy, PyTorch CPU, torchvision, Ultralytics YOLO, JSON/COCO.

## Global Constraints

- Treat `C:\workspace\bixolon_bakery` as read-only; never modify source images, `labels.txt`, or `Test_*.json`.
- Canonical category IDs are 1 through 20 from `labels.txt`; normalize `Grain  Campagne` to `Grain Campagne` only in derived data.
- Use all 83 mixed images in date-balanced, multilabel-aware folds sized `17/17/17/16/16`; every mixed image is OOF exactly once.
- Derived crops, augmentations, synthetic scenes, and backgrounds from a held-out mixed image must remain outside that fold's training inputs.
- Synthetic samples may occupy at most 50% of a training batch and never participate in validation, threshold calibration, or reported OOF performance.
- Keep the current runtime detector until every adoption gate passes.
- Detector gates: recall at least 0.85 and +5 percentage points, precision at least 0.97 and no more than -1 percentage point, non-decreasing mAP50-95, median area ratio 0.95–1.05, median IoU no more than 0.02 below baseline.
- Automatic white-label precision must be at least 0.98 OOF overall; classes with at least 20 OOF boxes also require precision at least 0.95.
- Embedding is optional and must improve ambiguous accuracy by 3 percentage points or reduce red-review rate by 15% at the same 0.98 precision, with at most 0.5 percentage-point precision loss.
- Final claims use real-image OOF results, not training metrics or the final model retrained on all 83 scenes.

---

## File Structure

- `tools/bread_training/catalog.py`: raw layout parsing, category normalization, checksum and canonical manifest records.
- `tools/bread_training/split.py`: deterministic date-balanced multilabel 5-fold assignment and leakage checks.
- `tools/bread_training/audit.py`: COCO geometry, duplicate, category, decode, and provenance audit.
- `tools/bread_training/synthetic.py`: training-only copy-paste records and 50% sampling cap.
- `tools/bread_training/metrics.py`: matching, detector metrics, classification calibration, and adoption gates.
- `tools/bread_training/train.py`: Ultralytics detector/classifier fold training adapters.
- `tools/bread_training/verifier.py`: YOLO-classifier feature and MobileNetV3-small prototype bake-off.
- `tools/bread_training/run_selection.py`: full catalog-to-manifest orchestration.
- `test/tools/bread_training/`: isolated unit and small integration tests for every module.
- `models/bread_pipeline_manifest.json`: selected filenames, hashes, thresholds, labels, and policy version; model weights remain ignored.

### Task 1: Canonical read-only catalog

**Files:**
- Create: `tools/bread_training/__init__.py`
- Create: `tools/bread_training/catalog.py`
- Create: `test/tools/bread_training/test_catalog.py`

**Interfaces:**
- Produces: `build_catalog(raw_root: Path) -> Catalog`
- Produces: `Catalog.to_json() -> dict` and `write_catalog(catalog: Catalog, path: Path) -> None`
- Produces: immutable `CatalogImage`, `CatalogAnnotation`, and `Catalog` dataclasses used by every later task.

- [ ] **Step 1: Write failing catalog tests**

```python
def test_normalizes_grain_campagne_alias():
    self.assertEqual(normalize_category_name("Grain  Campagne"), "Grain Campagne")

def test_mixed_key_includes_date_directory(self):
    catalog = build_catalog(self.fixture_root)
    keys = {image.key for image in catalog.images if image.source_kind == "mixed_scene"}
    self.assertIn("Test_20260714/E0501.jpg", keys)

def test_catalog_never_writes_under_raw_root(self):
    catalog = build_catalog(self.fixture_root)
    output = self.temp_root / "derived" / "catalog.json"
    write_catalog(catalog, output)
    self.assertTrue(output.is_file())
    self.assertEqual(sorted(p.name for p in self.fixture_root.iterdir()), self.original_names)
```

- [ ] **Step 2: Run tests and verify the missing module failure**

Run: `python -m unittest discover -s test/tools/bread_training -p "test_catalog.py" -v`

Expected: FAIL because `tools.bread_training.catalog` does not exist.

- [ ] **Step 3: Implement the catalog types and parser**

```python
@dataclass(frozen=True)
class CatalogImage:
    key: str
    absolute_path: str
    sha256: str
    width: int
    height: int
    source_kind: str
    source_group: str

@dataclass(frozen=True)
class CatalogAnnotation:
    annotation_id: str
    image_key: str
    category_id: int
    category_name: str
    bbox: tuple[float, float, float, float]

@dataclass(frozen=True)
class Catalog:
    labels: tuple[tuple[int, str], ...]
    images: tuple[CatalogImage, ...]
    annotations: tuple[CatalogAnnotation, ...]

def normalize_category_name(value: str) -> str:
    return " ".join(value.strip().split())

def mixed_coco_path(raw_root: Path, directory: Path) -> Path:
    return directory / f"{directory.name}.json"

def canonical_image_key(raw_root: Path, path: Path) -> str:
    return path.relative_to(raw_root).as_posix()
```

Implement `build_catalog` to enumerate `Bread01`–`Bread20`, the four exact `Test_20260706/08/10/14` directories, decode dimensions with `cv2.imdecode(np.fromfile(...))`, calculate SHA-256 in 1 MiB chunks, parse each directory's matching JSON, and reject category IDs or names outside the canonical registry.

Map `Bread01` through `Bread20` to category IDs 1 through 20 from the numeric folder suffix. Reject a missing folder, a suffix outside 1–20, or a `labels.txt` registry whose ordered names do not match the canonical normalized COCO categories.

- [ ] **Step 4: Run catalog tests and the real-root smoke command**

Run: `python -m unittest discover -s test/tools/bread_training -p "test_catalog.py" -v`

Expected: PASS.

Run: `python -m tools.bread_training.catalog --raw-root C:\workspace\bixolon_bakery --output datasets\bread_catalog_v1.json`

Expected: summary reports 3,230 single images, 83 mixed images, and 510 annotations without writing under the raw root.

- [ ] **Step 5: Commit**

```powershell
git add tools/bread_training/__init__.py tools/bread_training/catalog.py test/tools/bread_training/test_catalog.py
git commit -m "feat: catalog bread training data"
```

### Task 2: Data audit and deterministic 5-fold split

**Files:**
- Create: `tools/bread_training/audit.py`
- Create: `tools/bread_training/split.py`
- Create: `test/tools/bread_training/test_audit.py`
- Create: `test/tools/bread_training/test_split.py`

**Interfaces:**
- Consumes: `Catalog` from Task 1.
- Produces: `audit_catalog(catalog: Catalog) -> AuditReport`.
- Produces: `assign_folds(catalog: Catalog, folds: int, seed: int) -> dict[str, int]`.
- Produces: `assert_no_mixed_scene_leakage(assignments, derived_records) -> None`.

- [ ] **Step 1: Write failing audit and split tests**

```python
def test_audit_flags_out_of_bounds_and_exact_duplicates():
    report = audit_catalog(catalog_with_invalid_and_duplicate_boxes())
    self.assertEqual({issue.code for issue in report.issues}, {"bbox_out_of_bounds", "duplicate_bbox"})

def test_fold_sizes_and_unique_oof_assignment():
    assignments = assign_folds(catalog_with_83_mixed_images(), folds=5, seed=20260714)
    counts = sorted(Counter(assignments.values()).values(), reverse=True)
    self.assertEqual(counts, [17, 17, 17, 16, 16])
    self.assertEqual(len(assignments), 83)

def test_held_out_image_cannot_appear_as_synthetic_source():
    with self.assertRaises(LeakageError):
        assert_no_mixed_scene_leakage({"Test_20260714/E0501.jpg": 2}, [DerivedRecord("x", "Test_20260714/E0501.jpg", 2)])
```

- [ ] **Step 2: Run focused tests and verify failure**

Run: `python -m unittest test.tools.bread_training.test_audit test.tools.bread_training.test_split -v`

Expected: FAIL because the audit and split functions do not exist.

- [ ] **Step 3: Implement fail-closed audit and greedy stratification**

```python
FOLD_SIZES = (17, 17, 17, 16, 16)

def annotation_labels(catalog: Catalog, image_key: str) -> frozenset[int]:
    return frozenset(a.category_id for a in catalog.annotations if a.image_key == image_key)

def assignment_cost(fold, image, target_dates, target_labels):
    date_cost = abs((fold.date_counts[image.source_group] + 1) - target_dates[image.source_group])
    label_cost = sum(abs((fold.label_counts[label] + 1) - target_labels[label]) for label in image.labels)
    return (fold.size >= fold.capacity, label_cost, date_cost, fold.size, fold.index)

def assign_folds(catalog: Catalog, folds: int = 5, seed: int = 20260714) -> dict[str, int]:
    mixed = build_multilabel_items(catalog)
    ordered = sorted(mixed, key=lambda item: (-len(item.labels), stable_seed_key(item.key, seed)))
    states = make_fold_states(FOLD_SIZES)
    result = {}
    for item in ordered:
        chosen = min(states, key=lambda state: assignment_cost(state, item, target_dates(mixed), target_labels(mixed)))
        chosen.add(item)
        result[item.key] = chosen.index
    validate_fold_assignment(result, mixed)
    return result
```

The audit must reject non-positive dimensions, non-finite values, missing category IDs, and image/annotation references that do not resolve. Near-duplicate single-product images are grouped by folder plus perceptual-hash distance no greater than 4; a group receives one auxiliary fold assignment.

- [ ] **Step 4: Run tests and write derived reports**

Run: `python -m unittest test.tools.bread_training.test_audit test.tools.bread_training.test_split -v`

Expected: PASS.

Run: `python -m tools.bread_training.split --catalog datasets\bread_catalog_v1.json --audit-output outputs\model_selection\audit.json --split-output datasets\bread_5fold_v1.json --seed 20260714`

Expected: five folds sized 17/17/17/16/16 and an explicit per-date/per-label distribution table.

- [ ] **Step 5: Commit**

```powershell
git add tools/bread_training/audit.py tools/bread_training/split.py test/tools/bread_training/test_audit.py test/tools/bread_training/test_split.py
git commit -m "feat: audit and split bread dataset"
```

### Task 3: Leakage-safe synthetic augmentation

**Files:**
- Create: `tools/bread_training/synthetic.py`
- Create: `test/tools/bread_training/test_synthetic.py`
- Modify: `tools/experiments/build_bread_yolo_synth.py`
- Modify: `test/tools/test_build_bread_yolo_synth.py`

**Interfaces:**
- Consumes: catalog and fold assignment from Tasks 1–2.
- Produces: `SyntheticRecord` with scene seed, source IDs, transforms, mask checksum, and bbox.
- Produces: `build_synthetic_fold(catalog, assignments, fold, output, count, seed) -> list[SyntheticRecord]`.

Approved backgrounds are training-side single-product images with accepted foreground masks removed or separately audited training-only tray backgrounds. If none exist, `build_synthetic_fold` returns no scenes and records `disabled_reason=no_approved_backgrounds`; it never substitutes a held-out mixed scene.

- [ ] **Step 1: Write failing synthetic policy tests**

```python
def test_rejects_held_out_mixed_background():
    with self.assertRaises(LeakageError):
        choose_background(records, held_out_fold=3, candidate_key="Test_20260710/E0501.jpg")

def test_sampler_caps_synthetic_at_half_batch():
    kinds = balanced_batch_kinds(real_count=7, synthetic_count=50, batch_size=8)
    self.assertLessEqual(kinds.count("synthetic"), 4)

def test_bbox_is_mask_extent_without_padding():
    mask = np.zeros((20, 30), np.uint8)
    mask[4:15, 7:22] = 255
    self.assertEqual(mask_bbox(mask), (7, 4, 15, 11))
```

- [ ] **Step 2: Run focused tests and verify failure**

Run: `python -m unittest test.tools.bread_training.test_synthetic test.tools.test_build_bread_yolo_synth -v`

Expected: FAIL on the missing leakage and batch-cap APIs.

- [ ] **Step 3: Implement deterministic records and quality rejection**

```python
@dataclass(frozen=True)
class SyntheticRecord:
    output_key: str
    fold: int
    seed: int
    background_key: str
    source_keys: tuple[str, ...]
    mask_sha256: str
    boxes_xywh: tuple[tuple[int, int, int, int], ...]

def balanced_batch_kinds(real_count: int, synthetic_count: int, batch_size: int) -> list[str]:
    synthetic_slots = min(synthetic_count, batch_size // 2)
    real_slots = min(real_count, batch_size - synthetic_slots)
    if real_slots < batch_size - synthetic_slots:
        synthetic_slots = min(synthetic_slots, batch_size - real_slots)
    return ["real"] * real_slots + ["synthetic"] * synthetic_slots

def mask_bbox(mask: np.ndarray) -> tuple[int, int, int, int]:
    ys, xs = np.where(mask > 0)
    if len(xs) == 0:
        raise SyntheticQualityError("empty_mask")
    return int(xs.min()), int(ys.min()), int(xs.max() - xs.min() + 1), int(ys.max() - ys.min() + 1)
```

Reject masks with multiple large components, clipped foreground coverage below 0.98, visible halo score above the test fixture threshold, object area outside the real training-fold 1st–99th percentile, or overlap above 0.25 of the smaller object.

- [ ] **Step 4: Run tests and generate one smoke fold**

Run: `python -m unittest test.tools.bread_training.test_synthetic test.tools.test_build_bread_yolo_synth -v`

Expected: PASS.

Run: `python -m tools.bread_training.synthetic --catalog datasets\bread_catalog_v1.json --split datasets\bread_5fold_v1.json --fold 0 --count 20 --output datasets\bread_synth_smoke --seed 20260714`

Expected: 20 images, YOLO labels, and `lineage.jsonl`; no source record from fold 0 mixed scenes.

- [ ] **Step 5: Commit**

```powershell
git add tools/bread_training/synthetic.py test/tools/bread_training/test_synthetic.py tools/experiments/build_bread_yolo_synth.py test/tools/test_build_bread_yolo_synth.py
git commit -m "feat: add leakage-safe synthetic bread data"
```

### Task 4: Detector OOF evaluation and adoption gates

**Files:**
- Create: `tools/bread_training/metrics.py`
- Create: `tools/bread_training/train.py`
- Create: `test/tools/bread_training/test_metrics.py`
- Create: `test/tools/bread_training/test_train.py`

**Interfaces:**
- Produces: `match_detections(gt, predictions, iou_threshold=0.5) -> MatchResult`.
- Produces: `detector_report(folds) -> DetectorReport`.
- Produces: `detector_gate(baseline, candidate, median_latency_ms) -> GateDecision`.
- Produces: `train_detector_fold(config: DetectorTrainConfig) -> Path`.

- [ ] **Step 1: Write failing paired metric and gate tests**

```python
def test_detector_gate_rejects_loose_high_recall_candidate():
    baseline = DetectorReport(recall=.73, precision=.982, map50_95=.70, median_iou=.99, median_area_ratio=1.00)
    candidate = DetectorReport(recall=.91, precision=.98, map50_95=.72, median_iou=.93, median_area_ratio=1.08)
    decision = detector_gate(baseline, candidate, median_latency_ms=700)
    self.assertFalse(decision.accepted)
    self.assertIn("median_area_ratio", decision.failed_gates)

def test_one_prediction_matches_only_one_ground_truth():
    result = match_detections(two_overlapping_gt(), one_prediction(), iou_threshold=.5)
    self.assertEqual(result.matches, 1)
    self.assertEqual(result.misses, 1)
```

- [ ] **Step 2: Run tests and verify failure**

Run: `python -m unittest test.tools.bread_training.test_metrics test.tools.bread_training.test_train -v`

Expected: FAIL because the metric and trainer adapters do not exist.

- [ ] **Step 3: Implement exact gate logic and Ultralytics adapters**

```python
def detector_gate(baseline, candidate, median_latency_ms):
    checks = {
        "recall_absolute": candidate.recall >= .85,
        "recall_gain": candidate.recall - baseline.recall >= .05,
        "precision_absolute": candidate.precision >= .97,
        "precision_drop": candidate.precision >= baseline.precision - .01,
        "map50_95": candidate.map50_95 >= baseline.map50_95,
        "median_area_ratio": .95 <= candidate.median_area_ratio <= 1.05,
        "median_iou": candidate.median_iou >= baseline.median_iou - .02,
        "latency": median_latency_ms <= 1000,
    }
    return GateDecision(all(checks.values()), tuple(k for k, passed in checks.items() if not passed), checks)

def train_detector_fold(config):
    model = YOLO(str(config.initial_weights))
    result = model.train(data=str(config.dataset_yaml), imgsz=640, device="cpu", seed=config.seed, deterministic=True, project=str(config.output_root), name=config.run_name)
    return Path(result.save_dir) / "weights" / "best.pt"
```

Use confidence thresholds selected only on training-side validation predictions, then freeze them before held-out inference. Write per-image predictions so paired overlays can be regenerated.

- [ ] **Step 4: Run tests and the baseline-only OOF evaluation**

Run: `python -m unittest test.tools.bread_training.test_metrics test.tools.bread_training.test_train -v`

Expected: PASS.

Run: `python -m tools.bread_training.train detector-oof --catalog datasets\bread_catalog_v1.json --split datasets\bread_5fold_v1.json --baseline models\bread_yolov8n_1class_tray_v0_2.pt --output outputs\model_selection\detector_baseline`

Expected: five fold prediction files and `detector_report.json` containing all required metrics.

- [ ] **Step 5: Commit**

```powershell
git add tools/bread_training/metrics.py tools/bread_training/train.py test/tools/bread_training/test_metrics.py test/tools/bread_training/test_train.py
git commit -m "feat: evaluate bread detector candidates"
```

### Task 5: Classifier calibration and conditional verifier bake-off

**Files:**
- Create: `tools/bread_training/verifier.py`
- Create: `test/tools/bread_training/test_classifier_policy.py`
- Create: `test/tools/bread_training/test_verifier.py`
- Modify: `tools/bread_training/metrics.py`
- Modify: `tools/bread_training/train.py`

**Interfaces:**
- Produces: `calibrate_auto_label(predictions, min_precision=.98) -> LabelPolicy`.
- Produces: `is_ambiguous(confidence, margin, policy) -> bool`.
- Produces: `evaluate_verifiers(ambiguous_samples, candidates) -> VerifierDecision`.
- Produces: `train_classifier_fold(config: ClassifierTrainConfig) -> Path`.

- [ ] **Step 1: Write failing calibration and verifier tests**

```python
def test_calibration_chooses_highest_coverage_at_required_precision():
    policy = calibrate_auto_label(calibration_predictions(), min_precision=.98)
    accepted = apply_label_policy(calibration_predictions(), policy)
    self.assertGreaterEqual(precision(accepted), .98)
    self.assertEqual(policy.version, "bread-label-policy-v1")

def test_sparse_class_stays_review_required():
    policy = calibrate_auto_label(predictions_for_class(11, support=8), min_precision=.98)
    self.assertIn(11, policy.conservative_classes)

def test_verifier_must_meet_accuracy_or_review_reduction_and_latency():
    metrics = VerifierMetrics(kind="mobilenet_v3_small", ambiguous_accuracy_gain=.031, review_reduction_at_98_precision=.10, auto_precision_drop=.002, p50_ms=880, p95_ms=1700, supported_class_precision={1: .98, 2: .97})
    decision = choose_verifier({"none": classifier_only_metrics(), "mobilenet_v3_small": metrics})
    self.assertEqual(decision.kind, "mobilenet_v3_small")
```

- [ ] **Step 2: Run tests and verify failure**

Run: `python -m unittest test.tools.bread_training.test_classifier_policy test.tools.bread_training.test_verifier -v`

Expected: FAIL because calibration and verifier selection are missing.

- [ ] **Step 3: Implement policy and two concrete verifier candidates**

```python
@dataclass(frozen=True)
class LabelPolicy:
    version: str
    confidence: float
    margin: float
    conservative_classes: tuple[int, ...]

def is_ambiguous(confidence: float, margin: float, policy: LabelPolicy) -> bool:
    return confidence < policy.confidence or margin < policy.margin

def verifier_gate(metrics):
    benefit = metrics.ambiguous_accuracy_gain >= .03 or metrics.review_reduction_at_98_precision >= .15
    safe = metrics.auto_precision_drop <= .005 and metrics.p50_ms <= 1000 and metrics.p95_ms <= 2000
    return benefit and safe and all(value >= .95 for value in metrics.supported_class_precision.values())

def choose_verifier(metrics_by_kind):
    passing = [metrics for kind, metrics in metrics_by_kind.items() if kind != "none" and verifier_gate(metrics)]
    if not passing:
        return VerifierDecision(kind="none", metrics=metrics_by_kind["none"])
    selected = max(passing, key=lambda item: (item.review_reduction_at_98_precision, item.ambiguous_accuracy_gain, -item.p50_ms, item.kind))
    return VerifierDecision(kind=selected.kind, metrics=selected)
```

Implement `YoloPenultimateVerifier` by registering a forward hook on the classifier's penultimate pooling output and `MobileNetV3SmallVerifier` using `torchvision.models.mobilenet_v3_small(weights=MobileNet_V3_Small_Weights.DEFAULT)` with the classifier head removed. Normalize vectors, average training-side class prototypes, and use cosine similarity. Invoke either candidate only for classifier-ambiguous OOF crops.

- [ ] **Step 4: Run tests and execute classifier/verifier OOF**

Run: `python -m unittest test.tools.bread_training.test_classifier_policy test.tools.bread_training.test_verifier -v`

Expected: PASS.

Run: `python -m tools.bread_training.train classifier-oof --catalog datasets\bread_catalog_v1.json --split datasets\bread_5fold_v1.json --single-root C:\workspace\bixolon_bakery --output outputs\model_selection\classifier`

Expected: top-1, macro F1, top-3, calibration, per-class support, white coverage, and red-review reports.

Run: `python -m tools.bread_training.verifier --predictions outputs\model_selection\classifier\oof_predictions.jsonl --output outputs\model_selection\verifier_bakeoff.json`

Expected: deterministic `none`, `yolo_penultimate`, or `mobilenet_v3_small` decision with p50/p95 latency.

- [ ] **Step 5: Commit**

```powershell
git add tools/bread_training/verifier.py tools/bread_training/metrics.py tools/bread_training/train.py test/tools/bread_training/test_classifier_policy.py test/tools/bread_training/test_verifier.py
git commit -m "feat: calibrate automatic bread labels"
```

### Task 6: End-to-end selection CLI and pipeline manifest

**Files:**
- Create: `tools/bread_training/run_selection.py`
- Create: `test/tools/bread_training/test_run_selection.py`
- Create: `models/bread_pipeline_manifest.json`
- Modify: `models/README.md`

**Interfaces:**
- Consumes: all Tasks 1–5 artifacts.
- Produces: `run_selection(config: SelectionConfig) -> SelectionReport`.
- Produces: manifest schema version 1 consumed by the worker runtime plan.

- [ ] **Step 1: Write failing manifest tests**

```python
def test_manifest_contains_stable_labels_hashes_and_thresholds():
    manifest = build_manifest(passing_selection_fixture())
    self.assertEqual(manifest["schemaVersion"], 1)
    self.assertEqual([item["id"] for item in manifest["labels"]], list(range(1, 21)))
    self.assertRegex(manifest["detector"]["sha256"], r"^[0-9a-f]{64}$")
    self.assertIn(manifest["verifier"]["kind"], {"none", "yolo_penultimate", "mobilenet_v3_small"})

def test_failed_detector_gate_preserves_current_runtime_filename():
    manifest = build_manifest(selection_with_failed_detector_gate())
    self.assertEqual(manifest["detector"]["file"], "bread_yolov8n_1class_tray_v0_2.pt")
```

- [ ] **Step 2: Run tests and verify failure**

Run: `python -m unittest test.tools.bread_training.test_run_selection -v`

Expected: FAIL because the orchestrator and manifest builder do not exist.

- [ ] **Step 3: Implement the exact manifest contract**

```python
def build_manifest(selection):
    if not selection.classifier_gate.accepted:
        raise SelectionError("classifier gate failed")
    detector = selection.detector if selection.detector_gate.accepted else selection.baseline_detector
    verifier = selection.verifier
    return {
        "schemaVersion": 1,
        "pipelineVersion": "bread-pipeline-v1",
        "policyVersion": selection.label_policy.version,
        "detector": {"file": detector.path.name, "sha256": sha256_file(detector.path), "imgsz": 640, "confidence": detector.confidence, "iou": detector.iou},
        "classifier": {"file": selection.classifier.path.name, "sha256": sha256_file(selection.classifier.path), "imgsz": 224, "acceptConfidence": selection.label_policy.confidence, "acceptMargin": selection.label_policy.margin, "conservativeClasses": list(selection.label_policy.conservative_classes)},
        "verifier": verifier_manifest(verifier),
        "quality": {"minBoxSize": 45, "maxAreaRatio": .38, "edgeMarginPx": 2, "duplicateIou": .95},
        "labels": [{"id": category_id, "name": name} for category_id, name in selection.catalog.labels],
    }
```

`verifier_manifest` returns `{ "kind": "none", "file": None, "sha256": None, "scoreThreshold": None, "marginThreshold": None }` for classifier-only selection. Otherwise it writes a local `.pt` bundle containing the selected backbone state and class prototypes, hashes that bundle, and writes its calibrated score and margin thresholds. Runtime never downloads pretrained verifier weights. The builder refuses to write if a selected file is absent.

- [ ] **Step 4: Run unit tests and the full model-selection command**

Run: `python -m unittest discover -s test/tools/bread_training -p "test_*.py" -v`

Expected: PASS.

Run: `python -m tools.bread_training.run_selection --raw-root C:\workspace\bixolon_bakery --output-root outputs\model_selection\2026-07-14 --seed 20260714 --folds 5 --synthetic-max-ratio 0.5 --write-manifest models\bread_pipeline_manifest.json`

Expected: catalog, audit, split, detector OOF runs for current baseline, current-weight fine-tune real-only, current-weight fine-tune real+synthetic, COCO-pretrained YOLOv8n real-only, and COCO-pretrained YOLOv8n real+synthetic; classifier OOF runs for the preserved research weight and a newly trained YOLOv8n-cls candidate; verifier bake-off; gate decisions; final all-training-data weights; and a schema-valid manifest. A synthetic candidate is omitted with a recorded reason when no approved background exists.

- [ ] **Step 5: Verify repository-wide Python tests and commit**

Run: `python -m unittest discover -s test/tools -p "test_*.py" -v`

Expected: PASS with zero failures and zero errors.

```powershell
git add tools/bread_training test/tools/bread_training models/bread_pipeline_manifest.json models/README.md
git commit -m "feat: select bread inference pipeline"
```
