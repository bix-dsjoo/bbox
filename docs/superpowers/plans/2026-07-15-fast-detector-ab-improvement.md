# Fast Detector A/B Improvement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve Candidate A and B quickly, choose one with miss-first validation, train only the winner across five folds, and replace the deprecated runtime detector.

**Architecture:** Extend the existing detector candidate trainer with explicit augmentation profiles and selectable folds. Add a validation-only threshold selector that rejects per-image catastrophic misses, then orchestrate a one-fold screen followed by winner-only five-fold OOF and existing all-data publication.

**Tech Stack:** Python 3.11, Ultralytics YOLOv8, unittest, JSON artifacts, Flutter Windows CMake packaging.

## Global Constraints

- Keep `C:\workspace\bixolon_bakery` read-only.
- Screen on fold `0` for `12` epochs with patience `4`.
- Full-train only the screen winner for up to `60` epochs per fold with patience `10`.
- Use real data only in this improvement cycle.
- Use fixed confidence candidates `(0.25, 0.35, 0.45, 0.55, 0.65)` selected from each fold's validation split only.
- Reject a candidate if any evaluated image misses two or more ground-truth objects.
- Rank valid candidates by total misses, false positives, median matched IoU, then CPU median latency.
- Preserve the four-date uniform five-fold split and fold isolation.
- Do not use the deprecated detector as a relative adoption gate.
- Keep the deprecated detector only as an A2 training seed and provenance artifact until the replacement manifest passes audit.
- Do not change the approved Flutter box colors or shortcuts.

---

### Task 1: Add explicit A2/B2 training profiles and selectable folds

**Files:**
- Modify: `tools/bread_training/train.py`
- Modify: `test/tools/bread_training/test_detector_candidates.py`

**Interfaces:**
- Produces: `DetectorTrainConfig.mosaic`, `.close_mosaic`, `.translate`, `.scale`.
- Produces: `DetectorCandidateConfig.folds: tuple[int, ...]` and the same four augmentation fields.
- Produces: `fast_detector_candidate_matrix(current_weights, fold_dataset_root, output_root)` returning A2 and B2.
- Consumes: existing `train_detector_fold` and five generated detector fold datasets.

- [ ] **Step 1: Write failing profile tests**

```python
def test_fast_candidate_matrix_has_fixed_real_only_profiles(self):
    a2, b2 = fast_detector_candidate_matrix(
        Path("models/current.pt"), Path("datasets/folds"), Path("outputs/fast")
    )
    self.assertEqual((a2.name, b2.name), ("candidate_a2_tight", "candidate_b2_recall"))
    self.assertEqual(a2.initial_weights, Path("models/current.pt"))
    self.assertEqual(b2.initial_weights, Path("yolov8n.pt"))
    self.assertEqual(a2.folds, (0,))
    self.assertEqual(b2.folds, (0,))
    self.assertEqual((a2.epochs, a2.patience), (12, 4))
    self.assertEqual((b2.epochs, b2.patience), (12, 4))
    self.assertEqual((a2.mosaic, a2.close_mosaic, a2.translate, a2.scale), (0.25, 6, 0.05, 0.20))
    self.assertEqual((b2.mosaic, b2.close_mosaic, b2.translate, b2.scale), (0.50, 8, 0.10, 0.30))
    self.assertTrue(all(item.synthetic_ratio == 0.0 for item in (a2, b2)))

def test_candidate_runner_trains_only_requested_folds(self):
    config = replace(self.make_config(), folds=(0, 3))
    report = run_detector_candidate_oof(config, **self.fake_runtime())
    self.assertEqual([item["fold"] for item in report.fold_artifacts], [0, 3])
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```powershell
runtime\python\oof_eval\Scripts\python.exe -m unittest discover `
  -s test/tools/bread_training -p test_detector_candidates.py -v
```

Expected: imports or fields fail because fast profiles and selectable folds do not exist.

- [ ] **Step 3: Implement the profile fields and forward them to Ultralytics**

```python
@dataclass(frozen=True)
class DetectorTrainConfig:
    initial_weights: Path
    dataset_yaml: Path
    seed: int
    output_root: Path
    run_name: str
    epochs: int = 100
    patience: int = 20
    batch: int = 16
    device: int | str = 0
    mosaic: float = 1.0
    close_mosaic: int = 10
    translate: float = 0.1
    scale: float = 0.5

@dataclass(frozen=True)
class DetectorCandidateConfig:
    name: str
    initial_weights: Path
    fold_dataset_root: Path
    output_root: Path
    seed: int = 20260714
    epochs: int = 100
    patience: int = 20
    batch: int = 16
    device: int | str = 0
    synthetic_ratio: float = 0.0
    folds: tuple[int, ...] = (0, 1, 2, 3, 4)
    mosaic: float = 1.0
    close_mosaic: int = 10
    translate: float = 0.1
    scale: float = 0.5

def fast_detector_candidate_matrix(current_weights, fold_dataset_root, output_root):
    common = {"fold_dataset_root": fold_dataset_root, "folds": (0,), "epochs": 12, "patience": 4}
    return (
        DetectorCandidateConfig(
            name="candidate_a2_tight", initial_weights=current_weights,
            output_root=output_root / "candidate_a2_tight",
            mosaic=0.25, close_mosaic=6, translate=0.05, scale=0.20, **common,
        ),
        DetectorCandidateConfig(
            name="candidate_b2_recall", initial_weights=Path("yolov8n.pt"),
            output_root=output_root / "candidate_b2_recall",
            mosaic=0.50, close_mosaic=8, translate=0.10, scale=0.30, **common,
        ),
    )
```

Append these exact keyword arguments to the existing `model.train` call:

```python
mosaic=config.mosaic,
close_mosaic=config.close_mosaic,
translate=config.translate,
scale=config.scale,
```

Add `"folds": list(config.folds)` and the four numeric profile values to `_training_fingerprint`. Reject an empty fold tuple, duplicates, booleans, and values outside `0..4`, then build `fold_manifests` with `for fold in config.folds`.

- [ ] **Step 4: Run detector candidate tests**

Run:

```powershell
runtime\python\oof_eval\Scripts\python.exe -m unittest discover `
  -s test/tools/bread_training -p test_detector_candidates.py -v
```

Expected: all tests pass.

- [ ] **Step 5: Commit Task 1**

```powershell
git add tools/bread_training/train.py test/tools/bread_training/test_detector_candidates.py
git commit -m "feat: add fast detector training profiles"
```

---

### Task 2: Select operational confidence by catastrophic-miss-first ranking

**Files:**
- Modify: `tools/bread_training/train.py`
- Modify: `test/tools/bread_training/test_train.py`

**Interfaces:**
- Produces: `OperationalScore(total_misses, false_positives, max_image_misses, median_iou)`.
- Produces: `select_operational_threshold(ground_truth, raw_predictions, candidates) -> float`.
- Updates: detector fold artifact with `threshold_selection="miss_first_v1"` and per-image `misses`/`false_positives`.

- [ ] **Step 1: Write failing threshold-selection tests**

```python
def test_threshold_prefers_no_catastrophic_image_miss_over_higher_f1(self):
    ground_truth = {
        "dense.jpg": tuple((i * 20.0, 0.0, 10.0, 10.0) for i in range(5)),
        "easy.jpg": ((0.0, 0.0, 10.0, 10.0),),
    }
    raw = {
        "dense.jpg": tuple(
            Prediction((i * 20.0, 0.0, 10.0, 10.0), confidence)
            for i, confidence in enumerate((0.95, 0.90, 0.69, 0.68, 0.59))
        ),
        "easy.jpg": (Prediction((0.0, 0.0, 10.0, 10.0), 0.99),),
    }
    self.assertEqual(
        select_operational_threshold(ground_truth, raw, (0.55, 0.65, 0.75)),
        0.55,
    )

def test_threshold_tie_prefers_fewer_false_positives_then_higher_iou(self):
    # Both thresholds have max_image_misses <= 1; 0.55 retains fewer unmatched boxes.
    self.assertEqual(select_operational_threshold(gt, predictions, (0.45, 0.55)), 0.55)
```

- [ ] **Step 2: Verify RED**

Run:

```powershell
runtime\python\oof_eval\Scripts\python.exe -m unittest discover `
  -s test/tools/bread_training -p test_train.py -v
```

Expected: `select_operational_threshold` is missing.

- [ ] **Step 3: Implement deterministic miss-first scoring**

```python
FAST_THRESHOLD_CANDIDATES = (0.25, 0.35, 0.45, 0.55, 0.65)

@dataclass(frozen=True)
class OperationalScore:
    total_misses: int
    false_positives: int
    max_image_misses: int
    median_iou: float

def select_operational_threshold(ground_truth, raw_predictions, candidates=FAST_THRESHOLD_CANDIDATES):
    ranked = []
    for threshold in sorted(set(float(value) for value in candidates)):
        filtered = _filtered_predictions(raw_predictions, threshold)
        score = operational_score(ground_truth, filtered)
        ranked.append((
            score.max_image_misses <= 1,
            -score.total_misses,
            -score.false_positives,
            score.median_iou,
            threshold,
        ))
    return max(ranked)[-1]
```

Implement `operational_score` with the existing one-to-one matcher:

```python
def operational_score(ground_truth, predictions):
    misses = []
    false_positives = 0
    matched_ious = []
    for key in sorted(set(ground_truth) | set(predictions)):
        result = match_detections(ground_truth.get(key, ()), predictions.get(key, ()))
        misses.append(result.ground_truth_count - result.matches)
        false_positives += result.prediction_count - result.matches
        matched_ious.extend(result.matched_ious)
    return OperationalScore(
        total_misses=sum(misses),
        false_positives=false_positives,
        max_image_misses=max(misses, default=0),
        median_iou=statistics.median(matched_ious) if matched_ious else 0.0,
    )
```

Replace only detector candidate threshold selection; classifier policy calibration remains unchanged.

- [ ] **Step 4: Run OOF and candidate tests**

Run:

```powershell
runtime\python\oof_eval\Scripts\python.exe -m unittest discover `
  -s test/tools/bread_training -p test_train.py -v
runtime\python\oof_eval\Scripts\python.exe -m unittest discover `
  -s test/tools/bread_training -p test_detector_candidates.py -v
```

Expected: all tests pass and artifacts declare `miss_first_v1`.

- [ ] **Step 5: Commit Task 2**

```powershell
git add tools/bread_training/train.py test/tools/bread_training/test_train.py
git commit -m "feat: prioritize detector miss prevention"
```

---

### Task 3: Orchestrate one-fold screening and winner-only five-fold OOF

**Files:**
- Create: `tools/bread_training/fast_detector_ab.py`
- Create: `test/tools/bread_training/test_fast_detector_ab.py`
- Modify: `tools/bread_training/train.py`

**Interfaces:**
- Produces: `CandidateSummary(name, total_misses, false_positives, max_image_misses, median_iou, median_latency_ms)`.
- Produces: `choose_fast_candidate(summaries) -> CandidateSummary`.
- Produces: CLI command `python -m tools.bread_training.train detector-fast-ab ...`.
- Produces: `fast_selection.json` containing screen reports, winner, full OOF report, initial weights, and training profile.

- [ ] **Step 1: Write failing selection and orchestration tests**

```python
def test_choose_fast_candidate_rejects_two_misses_in_one_image(self):
    b = CandidateSummary("b", 3, 0, 2, 0.97, 120.0)
    a = CandidateSummary("a", 4, 1, 1, 0.95, 130.0)
    self.assertEqual(choose_fast_candidate((b, a)).name, "a")

def test_choose_fast_candidate_uses_documented_rank_order(self):
    a = CandidateSummary("a", 1, 2, 1, 0.96, 130.0)
    b = CandidateSummary("b", 1, 1, 1, 0.95, 140.0)
    self.assertEqual(choose_fast_candidate((a, b)).name, "b")

def test_orchestrator_runs_two_screens_but_only_one_full_oof(self):
    result = run_fast_ab(config, candidate_runner=fake_runner)
    self.assertEqual(calls, [
        ("candidate_a2_tight", (0,), 12),
        ("candidate_b2_recall", (0,), 12),
        (result.winner, (0, 1, 2, 3, 4), 60),
    ])
```

- [ ] **Step 2: Verify RED**

Run:

```powershell
runtime\python\oof_eval\Scripts\python.exe -m unittest discover `
  -s test/tools/bread_training -p test_fast_detector_ab.py -v
```

Expected: module import fails.

- [ ] **Step 3: Implement the small orchestration module**

```python
@dataclass(frozen=True)
class CandidateSummary:
    name: str
    total_misses: int
    false_positives: int
    max_image_misses: int
    median_iou: float
    median_latency_ms: float

def choose_fast_candidate(summaries):
    valid = [item for item in summaries if item.max_image_misses <= 1]
    if not valid:
        raise RuntimeError("A2 and B2 both have an image with at least two misses")
    return min(valid, key=lambda item: (
        item.total_misses,
        item.false_positives,
        -item.median_iou,
        item.median_latency_ms,
        item.name,
    ))
```

`run_fast_ab` must call both screen profiles, summarize held-out screen artifacts, choose once, clone only the winner with `folds=(0,1,2,3,4)`, `epochs=60`, `patience=10`, and write `fast_selection.json` atomically after the full OOF report exists.

- [ ] **Step 4: Add the CLI command**

Required arguments:

```text
--catalog PATH --split PATH --datasets PATH --deprecated-seed PATH --output PATH
```

The command validates the existing catalog/split/fold manifests before training and prints screen summaries plus the selected winner.

- [ ] **Step 5: Run orchestration and candidate unit tests**

Run:

```powershell
runtime\python\oof_eval\Scripts\python.exe -m unittest discover `
  -s test/tools/bread_training -p test_fast_detector_ab.py -v
runtime\python\oof_eval\Scripts\python.exe -m unittest discover `
  -s test/tools/bread_training -p test_detector_candidates.py -v
runtime\python\oof_eval\Scripts\python.exe -m unittest discover `
  -s test/tools/bread_training -p test_train.py -v
```

Expected: all tests pass.

- [ ] **Step 6: Commit Task 3**

```powershell
git add tools/bread_training/fast_detector_ab.py tools/bread_training/train.py `
  test/tools/bread_training/test_fast_detector_ab.py
git commit -m "feat: screen detector A B before five fold training"
```

---

### Task 4: Publish the fast-selection winner and deprecate the old runtime detector

**Files:**
- Modify: `tools/bread_training/run_selection.py`
- Modify: `test/tools/bread_training/test_run_selection.py`
- Modify: `lib/detector/bread_worker_client.dart`
- Modify: `lib/detector/auto_box_service.dart`
- Modify: `test/detector/bread_worker_client_test.dart`
- Modify: `test/detector/auto_box_service_test.dart`
- Modify: `models/README.md`
- Modify: `windows/CMakeLists.txt`
- Modify: `tools/packaging/build_windows_installer.ps1`
- Modify: `tools/packaging/verify_release_models.ps1`
- Modify: `test/packaging/installer_script_test.dart`
- Modify: `docs/release-checklist.md`

**Interfaces:**
- Consumes: `fast_selection.json` from Task 3.
- Produces: `SelectionConfig.fast_detector_selection: Path | None`.
- Produces: final all-data detector trained from the selected profile's initial weights and augmentation fields.
- Produces: manifest pointing only at `bread_detector_<winner>_v2.pt` with exact SHA-256.
- Produces: Flutter worker launch through `--pipeline-manifest`, eliminating the hard-coded deprecated detector filename.

- [ ] **Step 1: Write failing publication tests**

```python
def test_fast_selection_bypasses_deprecated_baseline_gate(self):
    config = replace(base_config, fast_detector_selection=fast_selection_path)
    selection = run_selection(config, progress=lambda _: None)
    self.assertEqual(selection.detector.name, "candidate_b2_recall")
    self.assertTrue(selection.detector_gate.accepted)
    self.assertEqual(selection.detector_gate.failed_gates, ())

def test_final_detector_uses_winner_initial_weights_and_profile(self):
    run_selection(config, progress=lambda _: None)
    self.assertEqual(train_call["initial_weights"], Path("yolov8n.pt"))
    self.assertEqual(train_call["mosaic"], 0.50)
    self.assertEqual(train_call["close_mosaic"], 8)

def test_manifest_no_longer_names_deprecated_detector(self):
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    self.assertEqual(manifest["detector"]["file"], "bread_detector_candidate_b2_recall_v2.pt")

test('default service resolves the pipeline manifest instead of a detector filename', () async {
  expect(startedArguments, [
    'bread_box_worker.py',
    '--pipeline-manifest',
    p.join('models', 'bread_pipeline_manifest.json'),
  ]);
});
```

- [ ] **Step 2: Verify RED**

Run:

```powershell
runtime\python\oof_eval\Scripts\python.exe -m unittest discover `
  -s test/tools/bread_training -p test_run_selection.py -v
```

Expected: configuration and fast winner loading are missing.

- [ ] **Step 3: Implement fast winner handoff**

When `fast_detector_selection` is present, validate all referenced files and hashes, require five distinct fold artifacts, require `max_image_misses <= 1`, and create an accepted gate record without calling `choose_detector(baseline, candidates)`. Keep the baseline report only under provenance with `status="deprecated"`.

Use these final training values from the selected artifact rather than hard-coded old weights:

```python
DetectorTrainConfig(
    initial_weights=Path(selection_payload["initial_weights"]),
    dataset_yaml=dataset_yaml,
    seed=20260714,
    output_root=final_root,
    run_name="train",
    epochs=median_best_epoch,
    patience=10,
    batch=16,
    device=0,
    mosaic=float(profile["mosaic"]),
    close_mosaic=int(profile["close_mosaic"]),
    translate=float(profile["translate"]),
    scale=float(profile["scale"]),
)
```

- [ ] **Step 4: Update runtime and packaging references**

Change `BreadWorkerClient` to require `pipelineManifestPath` and launch `bread_box_worker.py --pipeline-manifest <path>`. Change `defaultAutoBoxService` to resolve `BBOX_BREAD_PIPELINE_MANIFEST` with app-local fallback `models/bread_pipeline_manifest.json`; its required assets become Python, worker, and manifest.

Remove every hard-coded detector filename from packaging. In `windows/CMakeLists.txt`, read `models/bread_pipeline_manifest.json`, obtain `detector.file` and `classifier.file` with CMake `string(JSON ...)`, and install the manifest plus those two exact files. In both PowerShell scripts, load the same JSON with `ConvertFrom-Json`, reject path separators in the two filenames, and require only the manifest-named model files. Update packaging tests and `docs/release-checklist.md` to assert this manifest-driven behavior. Mark `bread_yolov8n_1class_tray_v0_2.pt` deprecated in `models/README.md`. Do not delete the old file until manifest audit and packaging tests pass.

- [ ] **Step 5: Run selection and manifest tests**

Run:

```powershell
runtime\python\oof_eval\Scripts\python.exe -m unittest discover `
  -s test/tools/bread_training -p test_run_selection.py -v
runtime\python\oof_eval\Scripts\python.exe -m unittest discover `
  -s test/tools -p test_bread_pipeline_manifest.py -v
flutter test test/detector/bread_worker_client_test.dart test/detector/auto_box_service_test.dart test/packaging/installer_script_test.dart
```

Expected: all tests pass.

- [ ] **Step 6: Commit Task 4**

```powershell
git add tools/bread_training/run_selection.py test/tools/bread_training/test_run_selection.py `
  lib/detector/bread_worker_client.dart lib/detector/auto_box_service.dart `
  test/detector/bread_worker_client_test.dart test/detector/auto_box_service_test.dart `
  models/README.md windows/CMakeLists.txt tools/packaging/build_windows_installer.ps1 `
  tools/packaging/verify_release_models.ps1 test/packaging/installer_script_test.dart `
  docs/release-checklist.md
git commit -m "feat: publish fast detector winner"
```

---

### Task 5: Train, visualize Test_20260714 OOF results, and verify release assets

**Files:**
- Create: `tools/bread_training/visualize_detector_oof.py`
- Create: `test/tools/bread_training/test_visualize_detector_oof.py`
- Create: `outputs/model_selection/fast_detector_ab/**` (ignored generated artifacts)
- Create: `outputs/visualizations/detector_test_20260714_fast/**` (ignored generated artifacts)
- Modify only after successful training: generated final model and manifest hash from Task 4.

**Interfaces:**
- Consumes: Tasks 1-4 commands and the read-only raw dataset.
- Produces: screen result, winner five-fold OOF, final model, contact sheet, audit JSON.

- [ ] **Step 1: Write and run a failing visualization-source test**

```python
def test_collect_source_images_uses_oof_predictions_from_all_folds(self):
    images = collect_source_images(
        selection_path, source_prefix="Test_20260714/"
    )
    self.assertEqual([image.image_key for image in images], [
        "Test_20260714/E0501.jpg",
        "Test_20260714/H0501.jpg",
        "Test_20260714/M0501.jpg",
    ])
    self.assertEqual({image.fold for image in images}, {0, 2, 4})
```

Run:

```powershell
runtime\python\oof_eval\Scripts\python.exe -m unittest discover `
  -s test/tools/bread_training -p test_visualize_detector_oof.py -v
```

Expected: module import fails.

- [ ] **Step 2: Implement the deterministic OOF contact-sheet CLI**

Create `collect_source_images(selection_path: Path, source_prefix: str) -> tuple[OofImage, ...]`. It must load only the winner's five artifact paths recorded in `fast_selection.json`, reject duplicate image keys, require each model hash to match its recorded hash, filter by the exact prefix, and sort by image key. Implement Pillow rendering with yellow dashed ground truth, magenta solid operational predictions, confidence text, and a black title band containing filename, fold, prediction count, ground-truth count, misses, and mean matched IoU.

The CLI arguments are exact:

```text
--selection PATH --image-root PATH --source-prefix Test_20260714/ --output PATH --columns 5
```

It writes `contact_sheet.jpg` and `per_image_metrics.csv` below `--output` and fails unless exactly 30 source images are collected.

- [ ] **Step 3: Run and commit visualization tests**

```powershell
runtime\python\oof_eval\Scripts\python.exe -m unittest discover `
  -s test/tools/bread_training -p test_visualize_detector_oof.py -v
git add tools/bread_training/visualize_detector_oof.py test/tools/bread_training/test_visualize_detector_oof.py
git commit -m "feat: visualize detector OOF results"
```

Expected: all visualization tests pass.

- [ ] **Step 4: Run A2/B2 screen and winner-only five-fold OOF**

```powershell
runtime\python\oof_eval\Scripts\python.exe -m tools.bread_training.train detector-fast-ab `
  --catalog datasets\bread_catalog_v1.json `
  --split datasets\bread_5fold_v1.json `
  --datasets datasets\bread_detector_5fold_v1 `
  --deprecated-seed models\bread_yolov8n_1class_tray_v0_2.pt `
  --output outputs\model_selection\fast_detector_ab
```

Expected: exactly two fold-0 screen runs, then exactly five runs for one winner; `fast_selection.json` reports `max_image_misses <= 1`.

- [ ] **Step 5: Train the final all-data detector and update the manifest**

```powershell
runtime\python\oof_eval\Scripts\python.exe -m tools.bread_training.run_selection `
  --raw-root C:\workspace\bixolon_bakery `
  --catalog datasets\bread_catalog_v1.json `
  --split datasets\bread_5fold_v1.json `
  --baseline-detector outputs\model_selection\detector_baseline\baseline_report.json `
  --candidate-root outputs\model_selection\fast_detector_ab\full_5fold `
  --fast-detector-selection outputs\model_selection\fast_detector_ab\fast_selection.json `
  --classifier-root outputs\model_selection\classifier_oof `
  --output-root outputs\model_selection\final_pipeline_v2 `
  --write-manifest models\bread_pipeline_manifest.json
```

Expected: manifest audit reports `ok=true`; baseline is recorded only as deprecated provenance.

- [ ] **Step 6: Generate the 30-image OOF comparison**

```powershell
runtime\python\oof_eval\Scripts\python.exe -m tools.bread_training.visualize_detector_oof `
  --selection outputs\model_selection\fast_detector_ab\fast_selection.json `
  --image-root C:\workspace\bixolon_bakery `
  --source-prefix Test_20260714/ `
  --output outputs\visualizations\detector_test_20260714_fast `
  --columns 5
```

Expected files:

```text
outputs/visualizations/detector_test_20260714_fast/contact_sheet.jpg
outputs/visualizations/detector_test_20260714_fast/per_image_metrics.csv
```

Expected: all 30 images appear; no image has two or more missed ground-truth objects.

- [ ] **Step 7: Run the focused and full verification suites**

```powershell
runtime\python\oof_eval\Scripts\python.exe -m unittest discover -s test/tools/bread_training -v
runtime\python\oof_eval\Scripts\python.exe -m unittest discover `
  -s test/tools -p test_bread_box_worker.py -v
flutter test
cmake -S windows -B build\windows\x64
```

Expected: all Python and Flutter tests pass; CMake configure finds the new detector asset and does not require the deprecated filename.

- [ ] **Step 8: Audit hashes and commit generated handoff references**

```powershell
runtime\python\oof_eval\Scripts\python.exe -m tools.bread_training.run_selection audit-handoff `
  --manifest models\bread_pipeline_manifest.json `
  --output outputs\model_selection\final_pipeline_v2\manifest_audit.json
git diff --check
git status --short
```

Expected: audit `ok=true`, no whitespace errors, and no raw-data files modified.
