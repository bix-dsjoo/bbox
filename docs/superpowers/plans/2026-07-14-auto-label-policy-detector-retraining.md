# Auto-Label Policy and Detector Retraining Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct the classifier policy evaluation, train two leakage-safe real-only detector candidates, select production weights, and emit the manifest consumed by the already-approved worker and Flutter plans.

**Architecture:** Keep catalog, audit, split, trained classifier folds, and detector baseline artifacts from Tasks 1-5. Derive one deployment classifier policy from validation-only fold policies, evaluate that exact policy without a 98% fail-close, then train current-weight and generic-weight detector candidates on disjoint train/validation/test folds. A selection CLI applies the unchanged detector gates, trains final all-data weights only where required, and writes schema-v1 manifest data for the persistent worker.

**Tech Stack:** Python 3.11/3.12, Ultralytics 8.4.91, PyTorch 2.13, OpenCV 5, NumPy, `unittest`, JSON/JSONL, Flutter/Dart handoff through `bread_pipeline_manifest.json`.

## Global Constraints

- Treat `C:\workspace\bixolon_bakery` as read-only; generated datasets, crops, weights, reports, and caches stay under ignored worktree `datasets/`, `outputs/`, or `runtime/` paths.
- Use seed `20260714`, five folds, and the existing assignments `17/17/17/16/16`.
- Classifier policy precision floor is `0.94`; `0.98` is not a product gate.
- Record actual deployment-policy precision and coverage; never change thresholds after inspecting held-out labels.
- Detector candidates are real-only because synthetic generation is disabled with `no_approved_backgrounds`.
- Detector gates remain unchanged: recall `>=.85`, recall gain `>=.05`, precision `>=.97`, precision drop `<=.01`, mAP50-95 non-decreasing, median area ratio `.95..1.05`, median IoU drop `<=.02`, full warm pipeline median `<=1000ms`.
- Product verifier is `none` unless a leakage-safe disjoint bake-off passes the existing benefit and latency gates.
- Every implementation task follows RED -> GREEN, commits separately, and receives an independent read-only review.
- After this plan, execute `2026-07-14-bread-auto-label-worker-runtime.md`, then `2026-07-14-flutter-auto-label-integration.md` without changing their approved UI semantics.

---

### Task 1: Exact classifier calibration and deployable policy

**Files:**
- Modify: `tools/bread_training/metrics.py`
- Modify: `tools/bread_training/train.py`
- Modify: `tools/bread_training/verifier.py`
- Modify: `test/tools/bread_training/test_classifier_policy.py`
- Modify: `test/tools/bread_training/test_verifier.py`

**Interfaces:**
- Consumes: existing `ClassificationPrediction`, five validation-derived `LabelPolicy` values, and held-out OOF predictions.
- Produces: `calibrate_auto_label(predictions, min_precision=.94) -> LabelPolicy`.
- Produces: `derive_deployment_policy(fold_policies) -> LabelPolicy`.
- Produces: `deployment_policy_report(predictions, policy) -> dict[str, Any]`.
- Produces: `evaluate_verifiers(calibration_samples, evaluation_samples, candidates, min_precision=.94) -> VerifierDecision`.
- Renames: `VerifierMetrics.review_reduction_at_98_precision` to `review_reduction_at_policy_precision`; verifier precision drop is measured against `.94`.

- [ ] **Step 1: Add failing exact-calibration and deployment-policy tests**

```python
def test_exact_calibration_does_not_drop_the_optimal_513th_threshold():
    values = [index / 600 for index in range(571)]
    candidates = calibration_threshold_candidates(values)
    self.assertEqual(candidates, tuple(sorted({0.0, *values})))
    self.assertGreater(len(candidates), 512)

def test_deployment_policy_is_derived_without_heldout_predictions():
    policies = tuple(
        LabelPolicy('bread-label-policy-v2', confidence, margin, ())
        for confidence, margin in zip(
            (.70, .80, .75, .90, .85),
            (.10, .20, .15, .25, .18),
        )
    )
    policy = derive_deployment_policy(policies)
    self.assertEqual(policy.confidence, .80)
    self.assertEqual(policy.margin, .18)

def test_report_applies_the_emitted_policy_not_fold_policy_outputs():
    policy = LabelPolicy('bread-label-policy-v2', .80, .20, ())
    predictions = (
        ClassificationPrediction('a', 1, 1, .90, .30),
        ClassificationPrediction('b', 1, 1, .79, .30),
        ClassificationPrediction('c', 2, 2, .90, .19),
    )
    report = deployment_policy_report(predictions, policy)
    self.assertEqual(report['acceptedSampleIds'], ['a'])
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```powershell
& C:\Users\OMEN\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe -m unittest discover -s test/tools/bread_training -p "test_classifier_policy.py" -v
```

Expected: FAIL because the 512-point grid misses the exact optimum and deployment-policy APIs do not exist.

- [ ] **Step 3: Implement exact sweep and validation-only deployment derivation**

```python
def calibration_threshold_candidates(values: Iterable[float]) -> tuple[float, ...]:
    return tuple(sorted({0.0, *(float(value) for value in values)}))

def derive_deployment_policy(fold_policies: Iterable[LabelPolicy]) -> LabelPolicy:
    policies = tuple(fold_policies)
    if len(policies) != 5:
        raise ValueError('exactly five validation-derived policies are required')
    return LabelPolicy(
        version='bread-label-policy-v2',
        confidence=float(statistics.median(item.confidence for item in policies)),
        margin=float(statistics.median(item.margin for item in policies)),
        conservative_classes=tuple(sorted(set().union(*(item.conservative_classes for item in policies)))),
    )

def deployment_policy_report(predictions, policy):
    values = tuple(_classification_prediction(item) for item in predictions)
    accepted = apply_label_policy(values, policy)
    return {
        'precision': classification_precision(accepted),
        'coverage': len(accepted) / len(values) if values else 0.0,
        'redReviewRate': 1.0 - (len(accepted) / len(values) if values else 0.0),
        'acceptedSampleIds': [item.sample_id for item in accepted],
    }
```

Keep the existing incremental margin scan, but iterate every unique confidence and margin. Set public selection defaults to `.94`; remove the `all classes conservative below .98` call from the deployment path. Fold-specific policies remain reporting evidence only.

- [ ] **Step 4: Separate verifier calibration and evaluation samples**

```python
def evaluate_verifiers(calibration_samples, evaluation_samples, candidates, min_precision=.94):
    calibration = tuple(item for item in calibration_samples if item.classifier_ambiguous)
    evaluation = tuple(item for item in evaluation_samples if item.classifier_ambiguous)
    metrics = {'none': _classifier_only_metrics()}
    for candidate in candidates:
        calibration_predictions = tuple(candidate.predict(calibration))
        policy = calibrate_auto_label(
            verifier_policy_predictions(calibration, calibration_predictions),
            min_precision=min_precision,
        )
        evaluation_predictions = tuple(candidate.predict(evaluation))
        metrics[candidate.kind] = verifier_metrics_on_evaluation(
            evaluation, evaluation_predictions, policy, min_precision
        )
    return choose_verifier(metrics)
```

Route each detector/classifier held-out fold to a different verifier calibration fold. Assert sample IDs and image keys are disjoint before prediction. Update `verifier_gate` and all serialized metric keys to use `review_reduction_at_policy_precision`; remove the old `review_reduction_at_98_precision` field so downstream reports cannot imply a 98% target.

- [ ] **Step 5: Regenerate classifier policy artifacts and verify GREEN**

Run:

```powershell
& C:\Users\OMEN\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe -m unittest discover -s test/tools/bread_training -p "test_classifier_policy.py" -v
& C:\Users\OMEN\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe -m unittest discover -s test/tools/bread_training -p "test_verifier.py" -v
@'
from pathlib import Path
from tools.bread_training.train import run_classifier_oof
print(run_classifier_oof(
    catalog_path=Path(r'datasets\bread_catalog_v1.json'),
    split_path=Path(r'datasets\bread_5fold_v1.json'),
    single_root=Path(r'C:\workspace\bixolon_bakery'),
    output_root=Path(r'outputs\model_selection\classifier'),
    reuse_trained_folds=True,
))
'@ | & runtime\python\oof_eval\Scripts\python.exe -
```

Expected: exact calibration tests pass; the regenerated report contains `bread-label-policy-v2`, actual deployment precision/coverage, no 98% fail-close, and no held-out sample used for policy selection.

- [ ] **Step 6: Commit**

```powershell
git add tools/bread_training/metrics.py tools/bread_training/train.py tools/bread_training/verifier.py test/tools/bread_training/test_classifier_policy.py test/tools/bread_training/test_verifier.py
git commit -m "fix: calibrate deployable bread label policy"
```

---

### Task 2: Leakage-safe detector fold datasets

**Files:**
- Create: `tools/bread_training/detector_data.py`
- Create: `test/tools/bread_training/test_detector_data.py`

**Interfaces:**
- Consumes: catalog JSON and `bread_5fold_v1.json` mixed assignments.
- Produces: immutable `DetectorFoldManifest`.
- Produces: `build_detector_fold_dataset(catalog, split, heldout_fold, output_root) -> DetectorFoldManifest`.
- Produces: `build_detector_all_data(catalog, output_root) -> Path`.

- [ ] **Step 1: Write failing split, geometry, and source-manifest tests**

```python
def test_detector_fold_has_disjoint_train_val_test_keys():
    manifest = build_detector_fold_dataset(catalog_fixture(), split_fixture(), 2, self.output)
    self.assertFalse(set(manifest.train_keys) & set(manifest.validation_keys))
    self.assertFalse(set(manifest.train_keys) & set(manifest.test_keys))
    self.assertFalse(set(manifest.validation_keys) & set(manifest.test_keys))

def test_coco_xywh_is_written_as_normalized_one_class_yolo():
    manifest = build_detector_fold_dataset(catalog_fixture(), split_fixture(), 0, self.output)
    label = (manifest.dataset_root / 'labels/train/example.txt').read_text().strip()
    self.assertEqual(label, '0 0.25000000 0.37500000 0.30000000 0.25000000')

def test_each_mixed_image_is_test_once_across_five_manifests():
    manifests = [build_detector_fold_dataset(catalog_fixture_83(), split_fixture_83(), fold, self.output) for fold in range(5)]
    keys = [key for item in manifests for key in item.test_keys]
    self.assertEqual(len(keys), 83)
    self.assertEqual(len(set(keys)), 83)
```

- [ ] **Step 2: Run tests and verify missing-module RED**

Run:

```powershell
& C:\Users\OMEN\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe -m unittest discover -s test/tools/bread_training -p "test_detector_data.py" -v
```

Expected: FAIL because `tools.bread_training.detector_data` does not exist.

- [ ] **Step 3: Implement fold manifests and exact YOLO conversion**

```python
@dataclass(frozen=True)
class DetectorFoldManifest:
    heldout_fold: int
    validation_fold: int
    dataset_root: Path
    dataset_yaml: Path
    train_keys: tuple[str, ...]
    validation_keys: tuple[str, ...]
    test_keys: tuple[str, ...]

def coco_xywh_to_yolo(box, width, height):
    x, y, w, h = (float(value) for value in box)
    return 0, (x + w / 2) / width, (y + h / 2) / height, w / width, h / height
```

Use fold `(heldout + 1) % 5` for validation and the other three folds for train. Hardlink images into ignored dataset folders when possible and copy only when hardlinks are unavailable. Write one-class `names: [bread]`, absolute train/val paths, and `source_manifest.json` containing keys, hashes, source fold, and annotation IDs. Fail if any source set overlaps or bbox is out of bounds.

- [ ] **Step 4: Generate all five real datasets and run audit**

Run:

```powershell
& runtime\python\oof_eval\Scripts\python.exe -m tools.bread_training.detector_data --catalog datasets\bread_catalog_v1.json --split datasets\bread_5fold_v1.json --output datasets\bread_detector_5fold_v1
```

Expected: five dataset roots, held-out sizes `17/17/17/16/16`, 83 unique test keys, 510 unique held-out annotations, and no file below the raw root.

- [ ] **Step 5: Commit**

```powershell
git add tools/bread_training/detector_data.py test/tools/bread_training/test_detector_data.py
git commit -m "feat: build leakage-safe detector folds"
```

---

### Task 3: Train and evaluate two detector candidates

**Files:**
- Modify: `tools/bread_training/train.py`
- Modify: `test/tools/bread_training/test_train.py`
- Create: `test/tools/bread_training/test_detector_candidates.py`

**Interfaces:**
- Consumes: five `DetectorFoldManifest` values and existing detector metrics.
- Produces: `DetectorCandidateConfig` and `DetectorCandidateReport`.
- Produces: `run_detector_candidate_oof(config) -> DetectorCandidateReport`.
- Produces: CLI `detector-candidate-oof`.

- [ ] **Step 1: Add failing configuration, leakage, and artifact tests**

```python
def test_real_only_candidate_matrix_is_exact():
    configs = detector_candidate_matrix(
        current_weights=Path('current.pt'),
        fold_dataset_root=Path('datasets/folds'),
        output_root=Path('outputs/candidates'),
    )
    self.assertEqual([item.name for item in configs], ['current_finetune_real', 'coco_yolov8n_real'])
    self.assertTrue(all(item.synthetic_ratio == 0 for item in configs))

def test_training_adapter_uses_gpu_deterministic_real_only_settings():
    result = train_detector_fold(detector_config_fixture(), yolo_factory=recording_yolo)
    self.assertEqual(recording_yolo.train_kwargs['device'], 0)
    self.assertEqual(recording_yolo.train_kwargs['imgsz'], 640)
    self.assertEqual(recording_yolo.train_kwargs['seed'], 20260714)
    self.assertTrue(recording_yolo.train_kwargs['deterministic'])

def test_candidate_artifact_contains_raw_and_operational_predictions():
    artifact = run_detector_candidate_oof(fake_candidate_config())
    self.assertEqual(len(artifact.fold_predictions), 5)
    self.assertIn('raw_predictions', artifact.fold_predictions[0].images[0])
    self.assertIn('operational_predictions', artifact.fold_predictions[0].images[0])
```

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```powershell
& C:\Users\OMEN\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe -m unittest discover -s test/tools/bread_training -p "test_detector_candidates.py" -v
```

Expected: FAIL because the candidate matrix and OOF runner do not exist.

- [ ] **Step 3: Implement the exact candidate matrix and training adapter**

```python
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

@dataclass(frozen=True)
class DetectorCandidateReport:
    name: str
    fold_artifacts: tuple[dict[str, Any], ...]
    report: DetectorReport
    median_latency_ms: float
    best_epochs: tuple[int, ...]

def detector_candidate_matrix(current_weights, fold_dataset_root, output_root):
    return (
        DetectorCandidateConfig(
            name='current_finetune_real',
            initial_weights=current_weights,
            fold_dataset_root=fold_dataset_root,
            output_root=output_root / 'current_finetune_real',
        ),
        DetectorCandidateConfig(
            name='coco_yolov8n_real',
            initial_weights=Path('yolov8n.pt'),
            fold_dataset_root=fold_dataset_root,
            output_root=output_root / 'coco_yolov8n_real',
        ),
    )
```

The CLI passes the dataset and output roots explicitly. `train_detector_fold` must pass `imgsz=640`, `device=0`, `seed=20260714`, `deterministic=True`, `workers=0`, `batch=16`, `epochs=100`, and `patience=20` to Ultralytics.

- [ ] **Step 4: Implement low-floor held-out inference and paired reports**

For each fold, train on its `train` and `val` directories, choose operational confidence from validation predictions only, freeze it, and infer held-out test images at confidence floor `.001`. Persist raw predictions, operational predictions, GT boxes, full-call latency, model hash, threshold, dataset-manifest hash, and fold metrics. Use the existing maximum-cardinality one-to-one matcher and standard confidence-ranked AP.

- [ ] **Step 5: Run one-epoch probes, then full candidate OOF**

Run:

```powershell
& runtime\python\oof_eval\Scripts\python.exe -m tools.bread_training.train detector-candidate-oof --catalog datasets\bread_catalog_v1.json --split datasets\bread_5fold_v1.json --datasets datasets\bread_detector_5fold_v1 --current models\bread_yolov8n_1class_tray_v0_2.pt --output outputs\model_selection\detector_candidates --probe-epochs 1
& runtime\python\oof_eval\Scripts\python.exe -m tools.bread_training.train detector-candidate-oof --catalog datasets\bread_catalog_v1.json --split datasets\bread_5fold_v1.json --datasets datasets\bread_detector_5fold_v1 --current models\bread_yolov8n_1class_tray_v0_2.pt --output outputs\model_selection\detector_candidates
```

Expected: probe reports timing without entering selection; full run produces ten best weights, ten fold prediction files, two aggregate candidate reports, unique 83-image coverage per candidate, and no synthetic records.

- [ ] **Step 6: Run regression suites and commit**

```powershell
& C:\Users\OMEN\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe -m unittest discover -s test/tools/bread_training -p "test_*.py" -v
git add tools/bread_training/train.py test/tools/bread_training/test_train.py test/tools/bread_training/test_detector_candidates.py
git commit -m "feat: train bread detector candidates"
```

---

### Task 4: Select final models and write pipeline manifest

**Files:**
- Create: `tools/bread_training/run_selection.py`
- Create: `test/tools/bread_training/test_run_selection.py`
- Create: `models/bread_pipeline_manifest.json`
- Modify: `models/README.md`

**Interfaces:**
- Consumes: detector baseline/candidate reports, classifier policy report, catalog labels, model files, and synthetic disabled status.
- Produces: `run_selection(config: SelectionConfig) -> SelectionReport`.
- Produces: `build_manifest(selection: SelectionReport) -> dict[str, Any]`.
- Produces: `audit_manifest_contract(manifest_path: Path) -> dict[str, Any]`.
- Produces: schema-v1 `models/bread_pipeline_manifest.json`.

- [ ] **Step 1: Write failing selection and manifest tests**

```python
def test_classifier_94_percent_floor_can_publish_manifest():
    selection = passing_selection(classifier_precision=.946, classifier_coverage=.618)
    manifest = build_manifest(selection)
    self.assertEqual(manifest['classifier']['oofPrecision'], .946)
    self.assertEqual(manifest['classifier']['oofCoverage'], .618)

def test_failed_new_detectors_keep_current_detector():
    selection = selection_with_failed_detector_candidates()
    manifest = build_manifest(selection)
    self.assertEqual(manifest['detector']['file'], 'bread_yolov8n_1class_tray_v0_2.pt')

def test_manifest_uses_none_verifier_and_ordered_labels():
    manifest = build_manifest(passing_selection())
    self.assertEqual(manifest['verifier'], {'kind': 'none', 'file': None, 'sha256': None, 'scoreThreshold': None, 'marginThreshold': None})
    self.assertEqual([item['id'] for item in manifest['labels']], list(range(1, 21)))
```

- [ ] **Step 2: Run tests and verify missing-module RED**

Run:

```powershell
& C:\Users\OMEN\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe -m unittest discover -s test/tools/bread_training -p "test_run_selection.py" -v
```

Expected: FAIL because `run_selection.py` does not exist.

- [ ] **Step 3: Implement deterministic selection and final-training epochs**

```python
CLASSIFIER_PRECISION_FLOOR = Decimal('0.94')

def choose_detector(baseline, candidates):
    passing = [item for item in candidates if detector_gate(baseline.report, item.report, item.median_latency_ms).accepted]
    if not passing:
        return baseline
    return max(passing, key=lambda item: (item.report.recall, item.report.map50_95, item.report.precision, -item.median_latency_ms, item.name))

def median_best_epoch(folds):
    return int(statistics.median(item.best_epoch for item in folds))
```

If a detector candidate passes, train it once on all 83 mixed images for the median best epoch from its five folds. Train the final classifier on all 3,230 single images plus all 510 mixed GT crops for the median best classifier epoch already recorded by Task 5. These final weights are deployment artifacts; OOF claims remain based only on fold weights.

Define the orchestration values explicitly:

```python
@dataclass(frozen=True)
class SelectionConfig:
    raw_root: Path
    catalog_path: Path
    split_path: Path
    baseline_detector_report: Path
    candidate_root: Path
    classifier_root: Path
    output_root: Path
    manifest_path: Path

@dataclass(frozen=True)
class ModelSelection:
    name: str
    path: Path
    sha256: str
    report: DetectorReport | Mapping[str, Any]
    confidence: float
    iou: float
    median_latency_ms: float

@dataclass(frozen=True)
class SelectionReport:
    catalog: Catalog
    baseline_detector: ModelSelection
    detector: ModelSelection
    detector_gate: GateDecision
    classifier: ModelSelection
    label_policy: LabelPolicy
    classifier_policy_report: Mapping[str, Any]
    verifier: VerifierDecision
    synthetic_disabled_reason: str
```

- [ ] **Step 4: Implement the manifest contract**

```python
def build_manifest(selection):
    if Decimal(str(selection.classifier_policy_report['precision'])) < CLASSIFIER_PRECISION_FLOOR:
        raise SelectionError('classifier deployment precision is below the approved 0.94 floor')
    return {
        'schemaVersion': 1,
        'pipelineVersion': 'bread-pipeline-v1',
        'policyVersion': selection.label_policy.version,
        'detector': detector_manifest(selection.detector),
        'classifier': classifier_manifest(selection.classifier, selection.label_policy, selection.classifier_policy_report),
        'verifier': {'kind': 'none', 'file': None, 'sha256': None, 'scoreThreshold': None, 'marginThreshold': None},
        'quality': {'minBoxSize': 45, 'maxAreaRatio': .38, 'edgeMarginPx': 2, 'duplicateIou': .95},
        'labels': [{'id': category_id, 'name': name} for category_id, name in selection.catalog.labels],
    }
```

Hash every selected file before writing. Refuse missing files, wrong hashes, non-ordered labels, thresholds outside `[0,1]`, or verifier files when `kind=none`. Record synthetic omission as `no_approved_backgrounds` in the selection report, not as a manifest model.

`audit_manifest_contract` reloads the manifest, recomputes detector/classifier hashes, checks ordered IDs 1-20, checks threshold ranges, and returns `{'ok': True, 'pipelineVersion': 'bread-pipeline-v1', 'verifierKind': 'none'}` only when every handoff invariant passes. Add an `audit-handoff` subcommand that writes this result below `outputs/`.

- [ ] **Step 5: Run full selection and validate handoff**

Run:

```powershell
& runtime\python\oof_eval\Scripts\python.exe -m tools.bread_training.run_selection --raw-root C:\workspace\bixolon_bakery --catalog datasets\bread_catalog_v1.json --split datasets\bread_5fold_v1.json --baseline-detector outputs\model_selection\detector_baseline\detector_report.json --candidate-root outputs\model_selection\detector_candidates --classifier-root outputs\model_selection\classifier --output-root outputs\model_selection\2026-07-14 --write-manifest models\bread_pipeline_manifest.json
& C:\Users\OMEN\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe -m unittest discover -s test/tools -p "test_*.py" -v
```

Expected: selection report names the chosen detector, final classifier, actual policy metrics, verifier `none`, and synthetic disabled reason; manifest validates against local file hashes and ordered labels; all Python tool tests pass.

- [ ] **Step 6: Commit**

```powershell
git add tools/bread_training/run_selection.py test/tools/bread_training/test_run_selection.py models/bread_pipeline_manifest.json models/README.md
git commit -m "feat: select bread inference pipeline"
```

---

### Task 5: Verify downstream plan handoff

**Files:**
- Inspect: `docs/superpowers/plans/2026-07-14-bread-auto-label-worker-runtime.md`
- Inspect: `docs/superpowers/plans/2026-07-14-flutter-auto-label-integration.md`
- Create: `outputs/model_selection/2026-07-14/handoff_audit.json` (ignored)

**Interfaces:**
- Consumes: schema-v1 manifest and the two approved downstream plans.
- Produces: a machine-readable handoff audit proving every manifest field used by worker/Flutter exists.

- [ ] **Step 1: Run the manifest/worker contract audit command**

```powershell
& C:\Users\OMEN\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe -m tools.bread_training.run_selection audit-handoff --manifest models\bread_pipeline_manifest.json --output outputs\model_selection\2026-07-14\handoff_audit.json
```

Expected: exit 0 and JSON `ok=true`, `pipelineVersion=bread-pipeline-v1`, `verifierKind=none`, with recomputed detector/classifier hashes matching the manifest.

- [ ] **Step 2: Confirm worker plan semantics**

Verify the worker plan consumes `acceptConfidence`, `acceptMargin`, `conservativeClasses`, returns accepted/review/unavailable states, batches classifier crops, and skips verifier construction for `kind=none`.

- [ ] **Step 3: Confirm Flutter plan semantics**

Verify the Flutter plan requires white accepted boxes, red review suggestions, gray unavailable proposals, category color only on the label-name badge, unchanged `1~0`/`Q~P`, `Enter` acceptance, Undo, persistence, and COCO exclusion for red/gray.

- [ ] **Step 4: Run plan placeholder and consistency scans**

```powershell
rg -n "TBD|TODO|implement later" docs\superpowers\plans\2026-07-14-bread-auto-label-worker-runtime.md docs\superpowers\plans\2026-07-14-flutter-auto-label-integration.md
rg -n "acceptConfidence|acceptMargin|conservativeClasses|suggestedLabelId|Enter|Colors.white|Colors.red|Colors.grey" docs\superpowers\plans\2026-07-14-bread-auto-label-worker-runtime.md docs\superpowers\plans\2026-07-14-flutter-auto-label-integration.md
```

Expected: no placeholders; every required contract term has an implementation task and test.

- [ ] **Step 5: Proceed immediately to downstream execution**

Execute all tasks in `2026-07-14-bread-auto-label-worker-runtime.md` with subagent-driven development and review gates, then all tasks in `2026-07-14-flutter-auto-label-integration.md`, followed by repository-wide verification and Windows release packaging.
