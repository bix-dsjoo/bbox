# Bread Inference Pipeline and Model Improvement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retrain and publish a leakage-safe bread detector/classifier pipeline from `C:\workspace\bixolon_bakery` that reduces missed boxes, reaches the approved detector/classifier gates, and applies one fixed app-wide auto-label policy.

**Architecture:** Keep the source dataset read-only and create every catalog, split, crop, weight, prediction, and report under `outputs/model_improvement/bread_pipeline_v2_20260715`. Extend the existing Python training package with capture-group folds, detector/classifier candidate evaluation, a deterministic domain-balanced classifier loader, and atomic model publication; then upgrade the manifest/worker contract without adding UI settings. The Flutter protocol remains v2 and only receives accepted, review, or unavailable results from the validated persistent worker.

**Tech Stack:** Python 3.11, PyTorch CUDA, Ultralytics 8.3.40, OpenCV, NumPy, `unittest`, Flutter/Dart, CMake, PowerShell, JSON/JSONL artifacts.

## Global Constraints

- Treat `C:\workspace\bixolon_bakery` as read-only; never edit, rename, move, or delete a source file.
- Use `outputs/model_improvement/bread_pipeline_v2_20260715` as the only generated-artifact root until the final audited publication into `models`.
- Preserve all pre-existing dirty worktree changes and `outputs/quick_rebuild`; execute implementation in a worktree created with `superpowers:using-git-worktrees`.
- Use seed `20260715`, exactly five capture-group folds, detector image size `640`, classifier image size `224`, and CPU deployment inference.
- A detector is publishable only when maximum misses per image are at most `1`, precision is at least `0.98`, median IoU is at least `0.90`, full-pipeline warm CPU median latency is at most `1000 ms`, and total OOF misses are lower than the current baseline.
- A classifier is publishable only when OOF detector-crop top-1 accuracy is at least `0.90` and macro recall is at least `0.85`.
- The fixed global auto-label policy must have accepted precision at least `0.98`; maximize coverage, then macro accepted recall, then margin threshold.
- White means accepted auto/user label, red means review with a valid suggestion, gray means classifier unavailable or no suggestion; automatic inference never confirms an image.
- Keep worker protocol version `2`; do not expose confidence, margin, color, or unlabeled thresholds as user/project settings.
- Preserve existing annotations on detector request failure; return gray proposals on classifier failure; disable automatic inference on manifest/hash/class-map failure while keeping manual labeling usable.
- Publish only content-addressed detector/classifier weights after catalog, split, OOF, policy, prospective-worker, Flutter, release-asset, and installer checks pass.

---

## File Structure

- `tools/bread_training/split.py`: capture-group derivation, deterministic grouped five-fold assignment, and leakage assertions.
- `tools/bread_training/classifier_data.py`: bbox padding/jitter, dynamic mixed-scene crops, balanced sampling, and Ultralytics dataloader adapter.
- `tools/bread_training/metrics.py`: detector operational evidence, classifier domain metrics, policy curve, gates, and deterministic ranking.
- `tools/bread_training/train.py`: detector/classifier candidate execution and OOF prediction provenance.
- `tools/bread_training/run_improvement.py`: one guarded CLI that snapshots inputs, runs stages, selects winners, retrains on all data, and atomically stages publication.
- `tools/detectors/bread_pipeline_manifest.py`: strict schema-v2 parsing, content hashes, class map, and loaded-model contract checks.
- `tools/detectors/bread_box_worker.py`: one NMS, confidence top-K before spatial sort, manifest padding, batch classification, and fallback behavior.
- `models/bread_pipeline_manifest.json`: fixed app-wide schema-v2 runtime policy.
- `models/bread_pipeline_report.json`: sidecar evidence and provenance; no runtime tuning values are read from it.
- `windows/CMakeLists.txt`, `tools/packaging/build_windows_installer.ps1`, `tools/packaging/verify_release_models.ps1`: manifest-driven release assets and isolated-worker validation.

### Task 1: Capture-group catalog split and immutable source snapshot

**Files:**
- Modify: `tools/bread_training/split.py:39-616`
- Modify: `test/tools/bread_training/test_split.py`
- Modify: `tools/bread_training/run_improvement.py` (create)
- Create: `test/tools/bread_training/test_run_improvement.py`

**Interfaces:**
- Consumes: `Catalog`, `CatalogImage`, `CatalogAnnotation`, and `audit_catalog()` from the existing catalog/audit modules.
- Produces: `capture_group_key(catalog: Catalog, image_key: str) -> str`, `build_capture_groups(catalog: Catalog) -> tuple[CaptureGroup, ...]`, `assign_grouped_folds(catalog: Catalog, folds: int = 5, seed: int = 20260715) -> dict[str, int]`, and canonical `catalog.json`, `audit.json`, `source_inventory.json`, `split.json` artifacts.

- [ ] **Step 1: Write failing capture-group and immutability tests**

Add these focused cases to `test/tools/bread_training/test_split.py`:

```python
def capture_catalog():
    labels = ((1, "one"), (4, "four"))
    singles = (
        CatalogImage("Bread01/E0701 (1).jpg", "C:/raw/1.jpg", "1" * 64, 100, 80, "single_bread", "Bread01", 1, "one"),
        CatalogImage("Bread01/E0701 (24).jpg", "C:/raw/2.jpg", "2" * 64, 100, 80, "single_bread", "Bread01", 1, "one"),
        CatalogImage("Bread01/E0702 (1).jpg", "C:/raw/3.jpg", "3" * 64, 100, 80, "single_bread", "Bread01", 1, "one"),
    )
    mixed = tuple(
        CatalogImage(key, f"C:/raw/{key}", str(index) * 64, 100, 80, "mixed_scene", "Test_20260714")
        for index, key in enumerate((
            "Test_20260714/E0501.jpg", "Test_20260714/H0501.jpg", "Test_20260714/M0501.jpg"
        ), 4)
    )
    category_rows = {
        mixed[0].key: (1, 1, 4), mixed[1].key: (4, 1, 1), mixed[2].key: (1, 4),
    }
    annotations = tuple(
        CatalogAnnotation(f"{key}:{offset}", key, category_id, dict(labels)[category_id], (1, 1, 10, 10))
        for key, categories in category_rows.items()
        for offset, category_id in enumerate(categories)
    )
    return Catalog(labels, singles + mixed, annotations, "C:/raw")

def test_single_frames_share_filename_series_capture_group(self):
    catalog = capture_catalog()
    groups = {group.key: group.image_keys for group in build_capture_groups(catalog)}
    self.assertIn(
        ("Bread01/E0701 (1).jpg", "Bread01/E0701 (24).jpg"), groups.values()
    )
    self.assertNotEqual(
        capture_group_key(catalog, "Bread01/E0701 (1).jpg"),
        capture_group_key(catalog, "Bread01/E0702 (1).jpg"),
    )

def test_same_date_and_category_multiset_share_mixed_capture_group(self):
    catalog = capture_catalog()
    self.assertEqual(
        capture_group_key(catalog, "Test_20260714/E0501.jpg"),
        capture_group_key(catalog, "Test_20260714/H0501.jpg"),
    )
    self.assertNotEqual(
        capture_group_key(catalog, "Test_20260714/E0501.jpg"),
        capture_group_key(catalog, "Test_20260714/M0501.jpg"),
    )

def test_grouped_split_is_byte_stable_and_never_crosses_folds(self):
    catalog = catalog_with_83_mixed_images()
    first = build_split_payload(catalog, folds=5, seed=20260715)
    second = build_split_payload(catalog, folds=5, seed=20260715)
    self.assertEqual(canonical_json_bytes(first), canonical_json_bytes(second))
    for group in first["capture_groups"]:
        self.assertEqual(
            {first["assignments"][key] for key in group["image_keys"]},
            {group["fold"]},
        )
```

Create `test/tools/bread_training/test_run_improvement.py` with a source-change guard:

```python
class SourceInventoryTest(unittest.TestCase):
    def test_source_inventory_rejects_any_changed_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            raw_root = Path(temporary) / "raw"
            source = raw_root / "Bread01" / "a.jpg"
            source.parent.mkdir(parents=True)
            source.write_bytes(b"before")
            inventory = source_inventory(raw_root)
            source.write_bytes(b"after")
            with self.assertRaisesRegex(ImprovementError, "source inventory changed"):
                assert_source_inventory_unchanged(raw_root, inventory)
```

- [ ] **Step 2: Run the tests and verify the new contract is absent**

Run:

```powershell
runtime\python\python.exe -m unittest test.tools.bread_training.test_split test.tools.bread_training.test_run_improvement -v
```

Expected: FAIL because `CaptureGroup`, `build_capture_groups`, `capture_group_key`, and `run_improvement` do not exist.

- [ ] **Step 3: Implement capture groups and grouped fold assignment**

In `tools/bread_training/split.py`, replace pHash-based single grouping and per-image mixed assignment with these public types and keys; retain the existing stable hash tie-breaker and balance candidate folds by group image count plus per-category annotation count:

```python
CAPTURE_GROUP_SCHEMA_VERSION = 2
DEFAULT_SEED = 20260715
_FRAME_SUFFIX = re.compile(r"\s*\((\d+)\)\s*$")

@dataclass(frozen=True)
class CaptureGroup:
    key: str
    source_kind: str
    source_group: str
    image_keys: tuple[str, ...]
    label_counts: tuple[tuple[int, int], ...]

def capture_group_key(catalog: Catalog, image_key: str) -> str:
    image = next(item for item in catalog.images if item.key == image_key)
    if image.source_kind == "single_bread":
        series = _FRAME_SUFFIX.sub("", Path(image.key).stem).strip()
        return f"single:{image.source_group}:{series}"
    counts = Counter(
        annotation.category_id
        for annotation in catalog.annotations
        if annotation.image_key == image_key
    )
    multiset = ",".join(
        str(category_id)
        for category_id in sorted(counts)
        for _ in range(counts[category_id])
    )
    return f"mixed:{image.source_group}:{multiset}"

def build_capture_groups(catalog: Catalog) -> tuple[CaptureGroup, ...]:
    images_by_group: dict[str, list[CatalogImage]] = defaultdict(list)
    for image in catalog.images:
        images_by_group[capture_group_key(catalog, image.key)].append(image)
    result = []
    for key, images in sorted(images_by_group.items()):
        members = tuple(sorted(image.key for image in images))
        counts = Counter(
            annotation.category_id
            for annotation in catalog.annotations
            if annotation.image_key in set(members)
        )
        result.append(
            CaptureGroup(
                key=key,
                source_kind=images[0].source_kind,
                source_group=images[0].source_group,
                image_keys=members,
                label_counts=tuple(sorted(counts.items())),
            )
        )
    return tuple(result)
```

Implement `assign_grouped_folds` by sorting groups by descending annotation count, descending member count, then `stable_seed_key(group.key, seed)`. For each group, evaluate all five folds with this exact score and choose the lexicographically smallest score:

```python
score = (
    sum((fold_label_counts[fold][label] + count - label_targets[label]) ** 2
        for label, count in group.label_counts),
    (fold_image_counts[fold] + len(group.image_keys) - image_target) ** 2,
    fold_group_counts[fold],
    stable_seed_key(f"{group.key}:{fold}", seed),
    fold,
)
```

Write `capture_groups`, `assignments`, `mixed_assignments`, `single_product_assignments`, the catalog SHA-256, seed, and schema version to the split payload. Make `assert_no_mixed_scene_leakage` compare capture-group folds, including every derived crop/augmentation `source_keys` entry.

- [ ] **Step 4: Add the guarded stage CLI and canonical JSON writes**

Create `tools/bread_training/run_improvement.py` with guarded paths and inventory functions:

```python
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = REPOSITORY_ROOT / "outputs/model_improvement/bread_pipeline_v2_20260715"

class ImprovementError(RuntimeError):
    pass

def canonical_json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")

def source_inventory(raw_root: Path) -> dict[str, str]:
    root = raw_root.resolve(strict=True)
    return {
        path.relative_to(root).as_posix(): sha256_file(path)
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }

def assert_source_inventory_unchanged(raw_root: Path, expected: Mapping[str, str]) -> None:
    if source_inventory(raw_root) != dict(expected):
        raise ImprovementError("source inventory changed during model improvement")

def guarded_output(path: Path) -> Path:
    root = (REPOSITORY_ROOT / "outputs/model_improvement").resolve()
    resolved = path.resolve()
    if root not in resolved.parents:
        raise ImprovementError(f"output must stay under {root}")
    return resolved
```

The `prepare-data` command must build the catalog, require `3313` images, `3230` singles, `83` mixed images, and `510` annotations, require `audit.ok`, write through a sibling `.tmp` file followed by `Path.replace`, and recheck the source inventory before returning success.

- [ ] **Step 5: Run data tests and the real read-only audit**

Run:

```powershell
runtime\python\python.exe -m unittest test.tools.bread_training.test_catalog test.tools.bread_training.test_audit test.tools.bread_training.test_split test.tools.bread_training.test_run_improvement -v
runtime\python\python.exe -m tools.bread_training.run_improvement prepare-data --raw-root C:\workspace\bixolon_bakery --output outputs\model_improvement\bread_pipeline_v2_20260715 --seed 20260715
```

Expected: all tests PASS; CLI prints `images=3313 singles=3230 mixed=83 annotations=510 issues=0 folds=5 source_unchanged=true` and creates canonical inventory/catalog/audit/split JSON files.

- [ ] **Step 6: Commit the data-contract implementation**

```powershell
git add tools/bread_training/split.py tools/bread_training/run_improvement.py test/tools/bread_training/test_split.py test/tools/bread_training/test_run_improvement.py
git commit -m "feat: add capture-group model improvement split"
```

### Task 2: Detector evidence, gates, and candidate matrix

**Files:**
- Modify: `tools/bread_training/metrics.py:17-459`
- Modify: `tools/bread_training/train.py:43-151,259-284`
- Modify: `tools/bread_training/run_improvement.py`
- Modify: `test/tools/bread_training/test_metrics.py`
- Modify: `test/tools/bread_training/test_detector_candidates.py`

**Interfaces:**
- Consumes: grouped fold datasets from `build_detector_fold_dataset()` and current baseline `models/bread_detector_tight_fold4_rebuilt.pt`.
- Produces: `DetectorOperationalReport`, `detector_operational_report(records)`, `detector_adoption_gate(baseline, candidate)`, candidate IDs `baseline`, `d1_current_real`, `d2_yolov8n_real`, `d3_yolov8s_real`, and fold prediction JSON containing model hash, selected validation threshold, per-image misses/FPs, matches, and latency.

- [ ] **Step 1: Write failing operational-metric and ranking tests**

Add to `test/tools/bread_training/test_metrics.py`:

```python
def operational(**changes):
    values = dict(
        candidate_id="candidate", predictions=150, matches=144, misses=6,
        false_positives=2, max_image_misses=1, precision=.986, recall=.96,
        median_iou=.91, p10_iou=.80, undersized_boxes=0,
        detector_cpu_median_ms=250, detector_cpu_p95_ms=300,
        pipeline_warm_median_ms=900, pipeline_warm_p95_ms=1100,
    )
    values.update(changes)
    return DetectorOperationalReport(**values)

def ranked_candidate(candidate_id, latency):
    return operational(
        candidate_id=candidate_id, misses=4, false_positives=1,
        median_iou=.92, p10_iou=.84, pipeline_warm_median_ms=latency,
    )

def test_detector_gate_uses_misses_precision_iou_and_pipeline_latency(self):
    baseline = operational(misses=6, false_positives=2, precision=.986, median_iou=.91)
    candidate = operational(
        misses=4, false_positives=1, precision=.99, median_iou=.92,
        p10_iou=.84, max_image_misses=1, pipeline_warm_median_ms=880,
    )
    decision = detector_adoption_gate(baseline, candidate)
    self.assertTrue(decision.accepted)
    self.assertEqual(decision.failed_gates, ())

def test_detector_gate_rejects_equal_misses_and_two_misses_in_one_image(self):
    baseline = operational(misses=6)
    candidate = operational(misses=6, max_image_misses=2)
    decision = detector_adoption_gate(baseline, candidate)
    self.assertEqual(decision.failed_gates, ("miss_reduction", "max_image_misses"))

def test_detector_rank_is_miss_fp_median_p10_latency_order(self):
    winner = min((ranked_candidate("slow", 900), ranked_candidate("tight", 700)), key=detector_rank_key)
    self.assertEqual(winner.candidate_id, "tight")
```

Add to `test/tools/bread_training/test_detector_candidates.py`:

```python
def test_improvement_candidate_matrix_has_baseline_d1_d2_d3(self):
    current = Path("models/current.pt")
    configs = detector_improvement_candidate_matrix(current, Path("folds"), Path("out"))
    self.assertEqual([item.candidate_id for item in configs], [
        "baseline", "d1_current_real", "d2_yolov8n_real", "d3_yolov8s_real",
    ])
    self.assertTrue(configs[0].evaluation_only)
    self.assertEqual(configs[1].initial_weights, current)
    self.assertEqual(configs[2].initial_weights, Path("yolov8n.pt"))
    self.assertEqual(configs[3].initial_weights, Path("yolov8s.pt"))
    for config in configs:
        self.assertEqual(config.imgsz, 640)
        self.assertTrue(config.real_only)
        self.assertEqual(config.folds, (0, 1, 2, 3, 4))
```

- [ ] **Step 2: Run tests and verify the stricter evidence is missing**

```powershell
runtime\python\python.exe -m unittest test.tools.bread_training.test_metrics test.tools.bread_training.test_detector_candidates -v
```

Expected: FAIL on missing `DetectorOperationalReport`, `detector_adoption_gate`, and D3.

- [ ] **Step 3: Implement the detector report and gate**

Add this immutable report and exact gate/rank rules to `metrics.py`:

```python
@dataclass(frozen=True)
class DetectorOperationalReport:
    candidate_id: str
    predictions: int
    matches: int
    misses: int
    false_positives: int
    max_image_misses: int
    precision: float
    recall: float
    median_iou: float
    p10_iou: float
    undersized_boxes: int
    detector_cpu_median_ms: float
    detector_cpu_p95_ms: float
    pipeline_warm_median_ms: float
    pipeline_warm_p95_ms: float

def detector_adoption_gate(
    baseline: DetectorOperationalReport,
    candidate: DetectorOperationalReport,
) -> GateDecision:
    checks = {
        "miss_reduction": candidate.misses < baseline.misses,
        "max_image_misses": candidate.max_image_misses <= 1,
        "precision": Decimal(str(candidate.precision)) >= Decimal("0.98"),
        "median_iou": Decimal(str(candidate.median_iou)) >= Decimal("0.90"),
        "pipeline_warm_median": candidate.pipeline_warm_median_ms <= 1000.0,
    }
    failed = tuple(name for name, passed in checks.items() if not passed)
    return GateDecision(not failed, failed, checks)

def detector_rank_key(report: DetectorOperationalReport) -> tuple[float, ...]:
    return (
        report.misses,
        report.false_positives,
        -report.median_iou,
        -report.p10_iou,
        report.pipeline_warm_median_ms,
    )
```

Compute `p10_iou` with a deterministic linear percentile over all matched IoUs, not a mean of fold percentiles. Aggregate raw counts across all 83 OOF images; retain per-fold rows separately rather than averaging fold ratios.

- [ ] **Step 4: Implement all detector candidates and leakage-safe threshold selection**

Change `DetectorCandidateConfig` to this exact interface and return these configs:

```python
@dataclass(frozen=True)
class DetectorCandidateConfig:
    candidate_id: str
    initial_weights: Path
    fold_dataset_root: Path
    output_root: Path
    evaluation_only: bool
    real_only: bool = True
    imgsz: int = 640
    epochs: int = 60
    close_mosaic: int = 15
    folds: tuple[int, ...] = (0, 1, 2, 3, 4)

(
    DetectorCandidateConfig("baseline", current, folds, output / "baseline", True, epochs=0, close_mosaic=0),
    DetectorCandidateConfig("d1_current_real", current, folds, output / "d1_current_real", False, epochs=25, close_mosaic=10),
    DetectorCandidateConfig("d2_yolov8n_real", Path("yolov8n.pt"), folds, output / "d2_yolov8n_real", False),
    DetectorCandidateConfig("d3_yolov8s_real", Path("yolov8s.pt"), folds, output / "d3_yolov8s_real", False),
)
```

For each fold, select detector confidence only from that fold's validation predictions using candidates `0.05` through `0.80` in `0.05` steps, minimizing `(misses, false_positives, -median_iou, threshold)`. Apply the selected threshold once to the held-out capture groups. Persist `fold`, weight SHA-256, validation keys, held-out keys, threshold, raw predictions, and per-image match evidence; call `assert_no_mixed_scene_leakage` before writing the fold completion marker.

- [ ] **Step 5: Add detector smoke and full commands to the orchestrator**

Implement commands with these semantics:

```powershell
python -m tools.bread_training.run_improvement detector-smoke --output outputs\model_improvement\bread_pipeline_v2_20260715 --fold 0 --epochs 1
python -m tools.bread_training.run_improvement detector-oof --output outputs\model_improvement\bread_pipeline_v2_20260715
```

`detector-smoke` runs D1/D2/D3 on fold 0 for one epoch and requires a loadable `best.pt` plus prediction JSON. `detector-oof` evaluates baseline, runs all trainable candidates on all five folds, writes `detector/selection.json`, and exits nonzero without final training when no candidate passes.

- [ ] **Step 6: Verify and commit detector infrastructure**

```powershell
runtime\python\python.exe -m unittest test.tools.bread_training.test_metrics test.tools.bread_training.test_detector_data test.tools.bread_training.test_detector_candidates test.tools.bread_training.test_train -v
git add tools/bread_training/metrics.py tools/bread_training/train.py tools/bread_training/run_improvement.py test/tools/bread_training/test_metrics.py test/tools/bread_training/test_detector_candidates.py
git commit -m "feat: evaluate bread detector adoption gates"
```

Expected: all listed tests PASS.

### Task 3: Dynamic classifier crops and domain-balanced sampling

**Files:**
- Create: `tools/bread_training/classifier_data.py`
- Create: `test/tools/bread_training/test_classifier_data.py`
- Modify: `tools/bread_training/train.py:152-239,596-748`

**Interfaces:**
- Consumes: catalog/split capture groups and training-fold mixed annotations.
- Produces: `CropSource`, `clamp_padded_bbox`, `jittered_bbox`, `assert_training_sources_disjoint`, `DomainBalancedSampler`, `BreadCropDataset`, and `BalancedClassificationTrainer`; each epoch is exactly 50% single and 50% mixed, category-balanced, then capture-group-balanced.

- [ ] **Step 1: Write failing geometry and sampler tests**

Create `test/tools/bread_training/test_classifier_data.py`:

```python
class ClassifierDataTest(unittest.TestCase):
    def test_padding_and_jitter_are_clamped_to_original_pixels(self):
        self.assertEqual(clamp_padded_bbox((0, 0, 20, 10), (100, 80), .05), (0, 0, 21, 11))
        first = jittered_bbox((10, 10, 20, 20), (40, 40), seed=7, padding_max=.05)
        second = jittered_bbox((10, 10, 20, 20), (40, 40), seed=7, padding_max=.05)
        self.assertEqual(first, second)
        self.assertGreater(first[2], 0)
        self.assertGreater(first[3], 0)

    def test_sampler_is_half_each_domain_then_category_and_group_balanced(self):
        sources = tuple(
            CropSource(
                source_key=f"{domain}-{category_id}-{group}",
                image_path=Path(f"{domain}-{category_id}-{group}.jpg"),
                domain=domain,
                category_id=category_id,
                capture_group=f"{domain}-group-{category_id}-{group}",
                bbox=None if domain == "single" else (1, 1, 10, 10),
            )
            for domain in ("single", "mixed")
            for category_id in (1, 2)
            for group in (1, 2)
        )
        sampler = DomainBalancedSampler(sources, samples_per_epoch=80, seed=20260715)
        sampler.set_epoch(3)
        selected = [sources[index] for index in sampler]
        self.assertEqual(Counter(item.domain for item in selected), {"single": 40, "mixed": 40})
        self.assertEqual(Counter(item.category_id for item in selected), {1: 40, 2: 40})
        counts = Counter(item.capture_group for item in selected)
        self.assertLessEqual(max(counts.values()) - min(counts.values()), 1)
        self.assertEqual(list(sampler), list(sampler))

    def test_heldout_key_cannot_enter_train_dataset(self):
        source = CropSource(
            "mixed-held", Path("held.jpg"), "mixed", 1, "held-group", (1, 1, 10, 10)
        )
        with self.assertRaisesRegex(LeakageError, "held-out"):
            assert_training_sources_disjoint((source,), {"mixed-held"})
```

- [ ] **Step 2: Run the test and verify the module is absent**

```powershell
runtime\python\python.exe -m unittest test.tools.bread_training.test_classifier_data -v
```

Expected: FAIL importing `tools.bread_training.classifier_data`.

- [ ] **Step 3: Implement source records, crop geometry, and balanced index generation**

Create `classifier_data.py` with these public contracts:

```python
@dataclass(frozen=True)
class CropSource:
    source_key: str
    image_path: Path
    domain: Literal["single", "mixed"]
    category_id: int
    capture_group: str
    bbox: tuple[float, float, float, float] | None

def clamp_padded_bbox(bbox, image_size, padding_ratio):
    x, y, width, height = map(float, bbox)
    image_width, image_height = image_size
    pad_x, pad_y = width * padding_ratio, height * padding_ratio
    left, top = max(0, math.floor(x - pad_x)), max(0, math.floor(y - pad_y))
    right = min(image_width, math.ceil(x + width + pad_x))
    bottom = min(image_height, math.ceil(y + height + pad_y))
    return left, top, right - left, bottom - top

class DomainBalancedSampler(torch.utils.data.Sampler[int]):
    def __init__(self, sources, samples_per_epoch, seed):
        self.sources = tuple(sources)
        self.samples_per_epoch = samples_per_epoch
        self.seed = seed
        self.epoch = 0
        self.index = build_domain_category_group_index(self.sources)

    def set_epoch(self, epoch):
        self.epoch = int(epoch)

    def __len__(self):
        return self.samples_per_epoch

    def __iter__(self):
        rng = random.Random(f"{self.seed}:{self.epoch}")
        selected = []
        for domain in ("single", "mixed"):
            count = self.samples_per_epoch // 2
            categories = sorted(self.index[domain])
            rng.shuffle(categories)
            groups = {category: sorted(self.index[domain][category]) for category in categories}
            for category_groups in groups.values():
                rng.shuffle(category_groups)
            for ordinal in range(count):
                category = categories[ordinal % len(categories)]
                category_groups = groups[category]
                group = category_groups[(ordinal // len(categories)) % len(category_groups)]
                selected.append(rng.choice(self.index[domain][category][group]))
        rng.shuffle(selected)
        self.last_epoch_source_keys = tuple(self.sources[index].source_key for index in selected)
        return iter(selected)

def assert_training_sources_disjoint(sources, heldout_keys):
    overlap = sorted({source.source_key for source in sources} & set(heldout_keys))
    if overlap:
        raise LeakageError(f"held-out sources entered classifier training: {overlap}")
```

The constructor must require an even `samples_per_epoch` and non-empty single/mixed indexes. The nested cycles make category and group counts differ by at most one within each domain, while the final shuffle prevents domain-blocked batches. Store sampler seed, epoch, and `last_epoch_source_keys` as JSONL from the training callback.

- [ ] **Step 4: Implement dynamic crops and the Ultralytics 8.3.40 loader**

`BreadCropDataset.__getitem__` must decode the source on demand. Singles use the entire image; mixed items call `jittered_bbox` only in train mode with seed derived from `seed:epoch:index`, using 0-5% context and at most 4% translation/scale jitter. Validation and held-out mode use the original GT bbox without augmentation. Return `{"img": tensor, "cls": category_id - 1}` after `classify_augmentations(size=224, erasing=0.0)` for training or `classify_transforms(size=224, crop_fraction=1.0)` for evaluation.

Subclass `ClassificationTrainer.get_dataloader` and use the custom sampler only for training:

```python
class BalancedClassificationTrainer(ClassificationTrainer):
    def __init__(self, cfg=DEFAULT_CFG, overrides=None, _callbacks=None):
        custom = dict(overrides or {})
        self.bread_sources_by_mode = custom.pop("bread_sources_by_mode")
        self.bread_samples_per_epoch = int(custom.pop("bread_samples_per_epoch"))
        super().__init__(cfg, custom, _callbacks)

    def build_dataset(self, dataset_path, mode="train", batch=None):
        return BreadCropDataset(
            self.bread_sources_by_mode[mode], mode=mode,
            seed=self.args.seed, imgsz=self.args.imgsz,
        )

    def get_dataloader(self, dataset_path, batch_size=16, rank=0, mode="train"):
        dataset = self.build_dataset(dataset_path, mode)
        sampler = None
        if mode == "train":
            sampler = DomainBalancedSampler(
                dataset.sources, samples_per_epoch=self.bread_samples_per_epoch,
                seed=self.args.seed,
            )
        return DataLoader(
            dataset,
            batch_size=batch_size,
            sampler=sampler,
            shuffle=False,
            num_workers=self.args.workers,
            pin_memory=True,
            collate_fn=dataset.collate_fn,
        )
```

Define `BreadCropDataset.collate_fn` as `{"img": torch.stack([row["img"] for row in batch]), "cls": torch.tensor([row["cls"] for row in batch])}`. After creating a validation loader, assign its `torch_transforms` to `self.model.transforms`, matching the existing Ultralytics classification trainer behavior.

Add an `on_train_epoch_start` callback that sets both dataset and sampler epoch and an `on_train_epoch_end` callback that appends the exact source-key sequence to `sampling_log.jsonl`. Reject distributed training because the approved run uses one RTX 5080 and one deterministic sampler.

- [ ] **Step 5: Verify crop/sampler behavior and commit**

```powershell
runtime\python\python.exe -m unittest test.tools.bread_training.test_classifier_data test.tools.bread_training.test_classifier_policy test.tools.bread_training.test_train -v
git add tools/bread_training/classifier_data.py tools/bread_training/train.py test/tools/bread_training/test_classifier_data.py
git commit -m "feat: add balanced mixed bread classifier data"
```

Expected: all tests PASS, including repeatable epoch index sequences.

### Task 4: Classifier candidate OOF evaluation and gates

**Files:**
- Modify: `tools/bread_training/train.py:751-1020`
- Modify: `tools/bread_training/metrics.py:54-324`
- Modify: `tools/bread_training/run_improvement.py`
- Modify: `test/tools/bread_training/test_classifier_policy.py`
- Modify: `test/tools/bread_training/test_train.py`

**Interfaces:**
- Consumes: C1 `yolov8n-cls.pt`, C2 `yolov8s-cls.pt`, balanced fold data, original held-out GT crops, and held-out boxes from the corresponding detector OOF weight.
- Produces: raw GT/detector crop JSONL, confusion matrix, per-class recall, top-1/top-3, macro recall, NLL, ECE, CPU batch latency, `validate_classifier_oof_records`, and deterministic C1/C2 selection.

- [ ] **Step 1: Write failing domain-metric and gate tests**

```python
def classifier_report(**changes):
    values = dict(
        candidate_id="c1", gt_crop_top1=.97, detector_crop_top1=.91,
        detector_crop_top3=.98, detector_crop_macro_recall=.86,
        negative_log_likelihood=.2, expected_calibration_error=.04,
        cpu_batch_median_ms=45, cpu_batch_p95_ms=60,
    )
    values.update(changes)
    return ClassifierCandidateReport(**values)

def test_classifier_gate_is_based_on_detector_crops(self):
    report = classifier_report()
    self.assertTrue(classifier_adoption_gate(report).accepted)
    failed = replace(report, detector_crop_top1=.899)
    self.assertEqual(classifier_adoption_gate(failed).failed_gates, ("detector_crop_top1",))

def test_classifier_rank_uses_top1_macro_recall_ece_latency(self):
    reports = (
        classifier_report(candidate_id="c1", detector_crop_top1=.91, detector_crop_macro_recall=.87, expected_calibration_error=.03, cpu_batch_median_ms=30),
        classifier_report(candidate_id="c2", detector_crop_top1=.92, detector_crop_macro_recall=.86, expected_calibration_error=.02, cpu_batch_median_ms=50),
    )
    self.assertEqual(min(reports, key=classifier_rank_key).candidate_id, "c2")

def test_each_heldout_mixed_annotation_has_gt_and_detector_crop_evidence(self):
    records = [
        {"annotation_id": annotation_id, "evaluation_domain": domain}
        for annotation_id in ("a-1", "a-2")
        for domain in ("gt", "detector")
    ]
    validate_classifier_oof_records(records, expected_annotation_ids={"a-1", "a-2"})
    duplicate = [*records, records[-1]]
    with self.assertRaisesRegex(ValueError, "exactly once"):
        validate_classifier_oof_records(duplicate, expected_annotation_ids={"a-1", "a-2"})
```

- [ ] **Step 2: Run tests and observe missing detector-domain gates**

```powershell
runtime\python\python.exe -m unittest test.tools.bread_training.test_classifier_policy test.tools.bread_training.test_train -v
```

Expected: FAIL because the report has no detector-domain metrics or candidate rank.

- [ ] **Step 3: Implement classifier reports and selection**

Change `ClassificationPrediction.predicted_class` to `int | None`; `apply_label_policy` must never accept a `None` prediction, regardless of zero thresholds. Add this gate/rank contract to `metrics.py`:

```python
@dataclass(frozen=True)
class ClassifierCandidateReport:
    candidate_id: str
    gt_crop_top1: float
    detector_crop_top1: float
    detector_crop_top3: float
    detector_crop_macro_recall: float
    negative_log_likelihood: float
    expected_calibration_error: float
    cpu_batch_median_ms: float
    cpu_batch_p95_ms: float

def classifier_adoption_gate(report):
    checks = {
        "detector_crop_top1": Decimal(str(report.detector_crop_top1)) >= Decimal("0.90"),
        "detector_crop_macro_recall": Decimal(str(report.detector_crop_macro_recall)) >= Decimal("0.85"),
    }
    failed = tuple(name for name, passed in checks.items() if not passed)
    return GateDecision(not failed, failed, checks)

def classifier_rank_key(report):
    return (
        -report.detector_crop_top1,
        -report.detector_crop_macro_recall,
        report.expected_calibration_error,
        report.cpu_batch_median_ms,
    )

def validate_classifier_oof_records(records, expected_annotation_ids):
    counts = Counter((row["annotation_id"], row["evaluation_domain"]) for row in records)
    expected = {
        (annotation_id, domain)
        for annotation_id in expected_annotation_ids
        for domain in ("gt", "detector")
    }
    if set(counts) != expected or any(count != 1 for count in counts.values()):
        raise ValueError("every held-out annotation must occur exactly once in each evaluation domain")
```

For each fold, select a shared crop padding from `0.00`, `0.025`, and `0.05` using validation detector crops, ranked by top-1, macro recall, then smaller padding; apply it once to that fold's held-out GT and detector crops. Match held-out detector boxes to GT one-to-one at IoU `0.50`; evaluate only the matched crop for a GT annotation, and record unmatched GT as an incorrect detector-domain prediction with `predicted_class=null`, confidence `0`, and margin `0`. This makes detector misses visible to end-to-end classifier metrics rather than silently dropping them. The deployment padding is the median of the five selected fold paddings.

- [ ] **Step 4: Add C1/C2 smoke and five-fold commands**

Use these exact candidate settings: C1 `yolov8n-cls.pt`, C2 `yolov8s-cls.pt`, batch `64`, workers `0`, 40 epochs, patience `8`, deterministic mode, single GPU `0`, and `samples_per_epoch=6460` (one balanced epoch equals twice the single-image count). Smoke uses fold `0`, one epoch, and `samples_per_epoch=200`.

```powershell
python -m tools.bread_training.run_improvement classifier-smoke --output outputs\model_improvement\bread_pipeline_v2_20260715 --fold 0 --epochs 1
python -m tools.bread_training.run_improvement classifier-oof --output outputs\model_improvement\bread_pipeline_v2_20260715
```

Each fold completion marker must include catalog/split hashes, candidate config, weight hash, sampling-log hash, train/validation/held-out group lists, detector weight hash, and prediction hash. Reuse is allowed only when every fingerprint field and output hash matches.

- [ ] **Step 5: Verify and commit classifier candidate evaluation**

```powershell
runtime\python\python.exe -m unittest test.tools.bread_training.test_classifier_data test.tools.bread_training.test_classifier_policy test.tools.bread_training.test_train -v
git add tools/bread_training/train.py tools/bread_training/metrics.py tools/bread_training/run_improvement.py test/tools/bread_training/test_classifier_policy.py test/tools/bread_training/test_train.py
git commit -m "feat: evaluate bread classifier on detector crops"
```

Expected: all tests PASS.

### Task 5: Global policy curve, winner selection, and atomic final training

**Files:**
- Modify: `tools/bread_training/metrics.py`
- Modify: `tools/bread_training/run_improvement.py`
- Create: `test/tools/bread_training/test_policy_curve.py`
- Modify: `test/tools/bread_training/test_run_improvement.py`

**Interfaces:**
- Consumes: winning detector/classifier OOF records only.
- Produces: `policy_curve.json`, `selection_report.json`, `final_training/completion.json`, prospective staging directory, and no `models` mutations until every gate passes.

- [ ] **Step 1: Write failing policy tie-break and publication-rollback tests**

```python
def curve_row(confidence, margin, precision, coverage, macro):
    return PolicyCurveRow(
        confidence=confidence, margin=margin, conservative_classes=(),
        accepted_count=50, correct_count=49,
        accepted_precision=precision, coverage=coverage,
        macro_accepted_recall=macro, red_review_rate=1.0 - coverage,
        unavailable_rate=0.0,
    )

def test_policy_curve_maximizes_coverage_then_macro_recall_then_margin():
    rows = (
        curve_row(.70, .20, .99, .50, .60),
        curve_row(.75, .10, .99, .50, .70),
        curve_row(.80, .30, .99, .50, .70),
        curve_row(.60, .05, 1.0, .40, .80),
    )
    selected = select_policy_row(rows, min_precision=.98)
    self.assertEqual((selected.confidence, selected.margin), (.80, .30))

def test_no_policy_at_98_precision_prevents_selection(self):
    with self.assertRaisesRegex(ImprovementError, "accepted precision"):
        select_policy_row((curve_row(.9, .5, .979, .1, .1),), min_precision=.98)

def test_incomplete_or_tampered_final_marker_is_never_reused(self):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        weight = root / "best.pt"
        weight.write_bytes(b"original")
        fingerprint = {"catalogSha256": "a" * 64, "epochs": 20}
        marker = root / "completion.json"
        atomic_write_json(marker, {
            "schemaVersion": 2, "trainingFingerprint": fingerprint,
            "weight": str(weight.resolve()), "weightSha256": sha256_file(weight),
            "finished": True,
        })
        weight.write_bytes(b"tampered")
        self.assertIsNone(reusable_completion(marker, fingerprint))
```

- [ ] **Step 2: Run tests and verify exact policy selection is missing**

```powershell
runtime\python\python.exe -m unittest test.tools.bread_training.test_policy_curve test.tools.bread_training.test_run_improvement -v
```

Expected: FAIL importing `select_global_policy`.

- [ ] **Step 3: Implement the complete confidence/margin curve**

Evaluate the Cartesian product of `{0.0} ∪ observed top-1 confidences` and `{0.0} ∪ observed margins`. Apply conservative classes before computing accepted metrics. Use this exact rank among rows meeting precision `>= 0.98`:

```python
@dataclass(frozen=True)
class PolicyCurveRow:
    confidence: float
    margin: float
    conservative_classes: tuple[int, ...]
    accepted_count: int
    correct_count: int
    accepted_precision: float
    coverage: float
    macro_accepted_recall: float
    red_review_rate: float
    unavailable_rate: float

def policy_rank_key(row: PolicyCurveRow):
    return (
        -row.coverage,
        -row.macro_accepted_recall,
        -row.margin,
        -row.confidence,
    )

def select_policy_row(rows, min_precision):
    eligible = [
        row for row in rows
        if row.accepted_count > 0 and row.accepted_precision >= min_precision
    ]
    if not eligible:
        raise ImprovementError("no policy reaches required accepted precision")
    return min(eligible, key=policy_rank_key)
```

Emit the selected policy as `LabelPolicy("bread-label-policy-v3", confidence, margin, conservative_classes)`. A row with `predicted_class is None` is counted as unavailable and is excluded from accepted/red-review counts.

If no row accepts at least one sample at precision `>=0.98`, raise `ImprovementError`. Store accepted count, correct count, precision, coverage, macro accepted recall, red-review rate, unavailable rate, confidence, margin, and conservative classes for every curve row.

- [ ] **Step 4: Implement final all-data training and transaction markers**

Use the median best epoch from the winner's five OOF folds. Train the detector on all 83 real mixed images and the classifier on all 3,230 singles plus all 510 mixed annotations with the same balanced sampler. Write a completion marker only after the final weight opens successfully and its SHA-256 is recorded:

```python
completion = {
    "schemaVersion": 2,
    "trainingFingerprint": fingerprint,
    "weight": str(weight.resolve()),
    "weightSha256": sha256_file(weight),
    "finished": True,
}
atomic_write_json(final_root / "completion.json", completion)
```

The fingerprint includes catalog hash, split hash, candidate ID/config, initial-weight hash, epoch count, sampler contract/version, and training library versions. A missing `finished: true`, mismatched fingerprint, missing weight, or mismatched weight hash forces retraining.

- [ ] **Step 5: Verify and commit selection/final-training logic**

```powershell
runtime\python\python.exe -m unittest test.tools.bread_training.test_policy_curve test.tools.bread_training.test_run_improvement test.tools.bread_training.test_run_selection -v
git add tools/bread_training/metrics.py tools/bread_training/run_improvement.py test/tools/bread_training/test_policy_curve.py test/tools/bread_training/test_run_improvement.py
git commit -m "feat: select fixed bread deployment policy"
```

Expected: all tests PASS and injected failures leave the existing `models` bytes unchanged.

### Task 6: Strict manifest schema v2 and model contract validation

**Files:**
- Modify: `tools/detectors/bread_pipeline_manifest.py:1-389`
- Modify: `test/tools/test_bread_pipeline_manifest.py`
- Modify: `tools/bread_training/run_improvement.py`
- Modify: `models/README.md`

**Interfaces:**
- Consumes: audited final detector/classifier weights and selected policy.
- Produces: schema-v2 `PipelineManifest` with `cropPaddingRatio` and explicit `classMap`, and `ResolvedModels(detector_path: Path, classifier_path: Path, report_path: Path)` with content hashes and loaded-model validation.

- [ ] **Step 1: Rewrite manifest tests around schema v2**

In test setup, write detector bytes to `bread_detector_v2_<detector hash>.pt`, classifier bytes to `bread_classifier_v2_<classifier hash>.pt`, and `b"report"` to `bread_pipeline_report.json`. Update `valid_payload()` in `test/tools/test_bread_pipeline_manifest.py` to this shape:

```python
detector_name = f"bread_detector_v2_{self.detector_hash}.pt"
classifier_name = f"bread_classifier_v2_{self.classifier_hash}.pt"
report_hash = sha256_bytes(b"report")
return {
    "schemaVersion": 2,
    "pipelineVersion": "bread-pipeline-v2",
    "policyVersion": "bread-label-policy-v3",
    "detector": {"file": detector_name, "sha256": detector_hash, "imgsz": 640, "confidence": .25, "iou": .55},
    "classifier": {
        "file": classifier_name, "sha256": classifier_hash, "imgsz": 224,
        "cropPaddingRatio": .05, "classMap": list(range(1, 21)),
        "acceptConfidence": .80, "acceptMargin": .20,
        "conservativeClasses": [],
    },
    "quality": {"minBoxSize": 45, "maxAreaRatio": .38, "edgeMarginPx": 2, "duplicateIou": .95},
    "reports": {"file": "bread_pipeline_report.json", "sha256": report_hash},
    "labels": [{"id": index, "name": name} for index, name in enumerate(CANONICAL_LABELS, 1)],
}
```

Replace the old optional-classifier-path test with `with self.assertRaisesRegex(ManifestError, "classifier model does not exist")`; schema v2 requires both models at startup. Replace `test_current_product_manifest_and_models_are_valid` with the same assertions against the temporary schema-v2 fixture in this test class; Task 9 restores a real-product manifest test only after audited weights exist. Add failures for classifier `task != classify`, 19 classes, duplicate/missing class-map IDs, model names that do not match the map, detector `task != detect`, detector class count not `1`, report hash mismatch, and non-content-addressed detector/classifier filenames.

- [ ] **Step 2: Run manifest tests and verify schema v1 rejects the new payload**

```powershell
runtime\python\python.exe -m unittest test.tools.test_bread_pipeline_manifest -v
```

Expected: FAIL because schema v2 fields are rejected.

- [ ] **Step 3: Implement schema-v2 parsing and static validation**

Set `SCHEMA_VERSION=2`, `PIPELINE_VERSION="bread-pipeline-v2"`, and `POLICY_VERSION="bread-label-policy-v3"`. Remove verifier and OOF metrics from runtime manifest. Require exact top-level/section keys. Require `cropPaddingRatio` from `0.0` through `0.05`, `classMap` exactly 20 unique canonical IDs, and both model filenames in the form `bread_detector_v2_<sha256>.pt` and `bread_classifier_v2_<sha256>.pt`. Resolve and hash detector, classifier, and report as required sibling files. Any schema/path/hash/class-map failure is fatal to automatic-worker startup; Flutter then keeps manual labeling available. Only an exception during classifier inference after successful startup uses the gray-proposal fallback.

- [ ] **Step 4: Validate loaded Ultralytics model semantics before ready**

Add:

```python
def validate_loaded_models(manifest, detector, classifier):
    if getattr(detector, "task", None) != "detect" or len(detector.names) != 1:
        raise ManifestError("detector must be a one-class detect model")
    if getattr(classifier, "task", None) != "classify" or len(classifier.names) != 20:
        raise ManifestError("classifier must be a 20-class classify model")
    normalized = tuple(_normalized_class_name(classifier.names[index]) for index in range(20))
    expected = tuple(_normalized_class_name(manifest.labels[label_id - 1].name) for label_id in manifest.classifier["classMap"])
    if normalized != expected:
        raise ManifestError("classifier names do not match manifest classMap")
```

Call this immediately after constructing both models and before emitting worker `ready`. Map the score at model index `i` through `classMap[i]`; do not assume `i + 1`.

- [ ] **Step 5: Verify and commit manifest v2**

```powershell
runtime\python\python.exe -m unittest test.tools.test_bread_pipeline_manifest test.tools.test_bread_label_policy -v
git add tools/detectors/bread_pipeline_manifest.py tools/bread_training/run_improvement.py test/tools/test_bread_pipeline_manifest.py models/README.md
git commit -m "feat: validate bread pipeline manifest v2"
```

Expected: all tests PASS.

### Task 7: Worker ordering, padding, class map, and fallback

**Files:**
- Modify: `tools/detectors/bread_box_worker.py:186-338,519-872`
- Modify: `tools/detectors/bread_label_policy.py:172-257`
- Modify: `test/tools/test_bread_box_worker.py`
- Modify: `test/tools/test_bread_label_policy.py`

**Interfaces:**
- Consumes: validated schema-v2 manifest and loaded models.
- Produces: detector inference with one NMS, confidence top-K before spatial order, 0-5% manifest crop padding, 20-class mapped scores, batch classification, duplicate review reasons, and protocol-v2 accepted/review/unavailable boxes; schema v2 has no verifier stage.

- [ ] **Step 1: Add failing ordering, padding, mapping, and fallback tests**

First extend the existing `pipeline_manifest` test helper with keyword arguments `crop_padding=0.0` and `class_map=None`, and add `"cropPaddingRatio": crop_padding` plus `"classMap": class_map or [1, 2, 3]` to its classifier dictionary. Then add:

```python
def test_max_proposals_keeps_highest_confidence_before_spatial_sort(self):
    detector = PipelineDetector([
        (5, 5, 20, 20, .10), (50, 50, 70, 70, .99), (1, 60, 20, 79, .80)
    ])
    classifier = BatchClassifier([(0.95, .03, .02), (0.95, .03, .02)])
    result = pipeline_engine(detector, classifier).detect_bytes(
        pipeline_png_bytes(), max_proposals=2
    )
    self.assertEqual([row["confidence"] for row in result["boxes"]], [.99, .80])

def test_manifest_padding_expands_classifier_crop_and_clamps_edges(self):
    classifier = BatchClassifier([(0.95, .03, .02)])
    manifest = pipeline_manifest(crop_padding=.05)
    engine = pipeline_engine(PipelineDetector([(0, 0, 20, 20, .9)]), classifier, manifest=manifest)
    engine.detect_bytes(pipeline_png_bytes(width=100, height=80))
    crops, _ = classifier.calls[0]
    self.assertEqual([crop.shape for crop in crops], [(21, 21, 3)])

def test_classifier_index_uses_manifest_class_map(self):
    manifest = pipeline_manifest(class_map=[3, 1, 2])
    result = pipeline_engine(
        PipelineDetector([(2, 3, 20, 20, .9)]),
        BatchClassifier([(0.95, .03, .02)]), manifest=manifest,
    ).detect_bytes(pipeline_png_bytes())
    self.assertEqual(result["boxes"][0]["label"]["labelId"], 3)

def test_classifier_exception_returns_gray_proposals_for_every_detector_box(self):
    detector = PipelineDetector([(2, 3, 20, 20, .9), (30, 3, 50, 20, .8)])
    result = pipeline_engine(detector, FailingClassifier()).detect_bytes(pipeline_png_bytes())
    self.assertEqual([row["label"]["state"] for row in result["boxes"]], ["unavailable", "unavailable"])
    self.assertEqual(result["stageErrors"][0]["stage"], "classifier")
```

- [ ] **Step 2: Run worker tests and verify current top-K order fails**

```powershell
runtime\python\python.exe -m unittest test.tools.test_bread_box_worker test.tools.test_bread_label_policy -v
```

Expected: FAIL because current code spatially sorts before truncation and crops without manifest padding.

- [ ] **Step 3: Implement the exact detector/post-processing order**

Replace the current post-detection block with:

```python
boxes, detector_errors = _pipeline_detection_boxes(detection, image_width=image_width, image_height=image_height)
boxes = _nms(boxes, iou_threshold=float(self.manifest.detector["iou"]))
if max_proposals is not None:
    limit = max(0, int(max_proposals))
    boxes = sorted(boxes, key=lambda item: (-item["confidence"], -_area(item)))[:limit]
boxes.sort(key=lambda item: (item["xyxy"][1], item["xyxy"][0]))
```

Do not invoke `_nms` inside `_pipeline_detection_boxes`; exactly one worker NMS remains. Do not remove suspected duplicates after NMS; `_apply_duplicate_review` adds `possible_duplicate` to both survivors.

- [ ] **Step 4: Implement padded batch crops and mapped scores**

Change `_crop_box` to accept the image and padding ratio, expand each side by `width * ratio` and `height * ratio`, floor left/top, ceil right/bottom, and clamp to image bounds. Build all crops first and call classifier once with `batch=min(16, len(crops))`. Change `normalized_scores` to accept `class_map` and return canonical ID scores:

```python
scores = normalized_scores(
    raw_scores,
    self.manifest.labels,
    class_map=self.manifest.classifier["classMap"],
)
```

Keep accepted as `labelId`, review as `suggestedLabelId` plus non-empty reasons, and unavailable with neither ID. Preserve protocol version `2`, pipeline/policy versions, image SHA-256, and stage errors.

Remove `verifier`, `verifier_error`, and `verifier_factory` from schema-v2 engine construction. Delete the old verifier-only worker tests and replace them with this ambiguity assertion:

```python
def test_ambiguous_classifier_result_stays_review_without_verifier(self):
    engine = pipeline_engine(
        PipelineDetector([(2, 3, 30, 32, .9)]),
        BatchClassifier([(.55, .40, .05)]),
    )
    result = engine.detect_bytes(pipeline_png_bytes())
    label = result["boxes"][0]["label"]
    self.assertEqual(label["state"], "review")
    self.assertEqual(label["suggestedLabelId"], 1)
    self.assertIn("classifier_ambiguous", label["reviewReasons"])
```

- [ ] **Step 5: Verify and commit worker behavior**

```powershell
runtime\python\python.exe -m unittest test.tools.test_bread_box_worker test.tools.test_bread_label_policy test.tools.test_bread_pipeline_manifest -v
git add tools/detectors/bread_box_worker.py tools/detectors/bread_label_policy.py test/tools/test_bread_box_worker.py test/tools/test_bread_label_policy.py
git commit -m "feat: apply bread pipeline v2 runtime ordering"
```

Expected: all tests PASS.

### Task 8: Flutter contract regression and manifest-driven Windows packaging

**Files:**
- Modify only if tests expose a contract gap: `lib/detector/auto_box_service.dart:584-659`
- Modify only if tests expose a contract gap: `lib/ui/app_controller.dart:704-984`
- Modify: `test/detector/auto_box_service_test.dart`
- Modify: `test/ui/app_controller_test.dart`
- Modify: `test/ui/workbench/canvas_overlay_test.dart`
- Modify: `test/ui/workbench/inspector_panel_test.dart`
- Modify: `windows/CMakeLists.txt:114-177`
- Modify: `tools/packaging/build_windows_installer.ps1:1-110`
- Modify: `tools/packaging/verify_release_models.ps1`
- Modify: `test/packaging/installer_script_test.dart`

**Interfaces:**
- Consumes: unchanged protocol-v2 worker states and schema-v2 manifest files.
- Produces: atomic result application, white/red/gray UI regression coverage, manual fallback after startup failure, and a release containing only the active manifest/report/weights plus required worker modules.

- [ ] **Step 1: Add Flutter state-contract tests**

Add cases asserting: accepted becomes a labeled auto box; review remains a proposal with suggestion/reasons; unavailable remains a gray proposal; no state auto-confirms an image; detector request error leaves the previous boxes byte-equivalent; classifier stage error still applies detector boxes; manifest startup failure reports automation unavailable while manual box creation/labeling still works. Keep the existing red-outline and label-color badge widget assertions.

- [ ] **Step 2: Run focused Flutter tests**

```powershell
flutter test test/detector/auto_box_service_test.dart test/ui/app_controller_test.dart test/ui/workbench/canvas_overlay_test.dart test/ui/workbench/inspector_panel_test.dart
```

Expected before any Dart change: tests either PASS (confirming protocol compatibility) or fail only at the exact newly asserted fallback boundary. If they pass, do not change `lib` files.

- [ ] **Step 3: Make the minimal Dart correction only when a new regression test fails**

The permitted correction is limited to preserving these mappings in `_parsePipelineBox`: `accepted -> BoxStatus.labeled + labelId + LabelSource.auto`, `review -> BoxStatus.proposal + suggestedLabelId + reasons`, and `unavailable -> BoxStatus.proposal` with no label/suggestion. In `AppController`, apply a successful worker response atomically; on request/startup exception retain the current image boxes and expose the existing error state without disabling manual annotation.

- [ ] **Step 4: Make packaging read and verify schema-v2 assets**

Read detector, classifier, and `reports.file` from the manifest. Require safe sibling filenames, require their files before build and in Release, and hash all three against the manifest. Update CMake install to include only:

```text
models/bread_pipeline_manifest.json
models/<manifest.detector.file>
models/<manifest.classifier.file>
models/<manifest.reports.file>
tools/detectors/bread_box_worker.py
tools/detectors/bread_label_policy.py
tools/detectors/bread_pipeline_manifest.py
runtime/python/**
```

The release verifier must run `runtime\python\python.exe tools\detectors\bread_pipeline_manifest.py models\bread_pipeline_manifest.json`, start the isolated worker, require a protocol-v2 `ready` frame, and reject legacy model files or development folders.

- [ ] **Step 5: Verify and commit app/packaging integration**

```powershell
flutter test test/detector/auto_box_service_test.dart test/ui/app_controller_test.dart test/ui/workbench/canvas_overlay_test.dart test/ui/workbench/inspector_panel_test.dart test/packaging/installer_script_test.dart
runtime\python\python.exe -m unittest test.tools.test_bread_box_worker test.tools.test_bread_pipeline_manifest -v
git add lib/detector/auto_box_service.dart lib/ui/app_controller.dart test/detector/auto_box_service_test.dart test/ui/app_controller_test.dart test/ui/workbench/canvas_overlay_test.dart test/ui/workbench/inspector_panel_test.dart windows/CMakeLists.txt tools/packaging/build_windows_installer.ps1 tools/packaging/verify_release_models.ps1 test/packaging/installer_script_test.dart
git commit -m "test: lock bread pipeline deployment contract"
```

If neither Dart file changed, omit it from `git add`. Expected: all tests PASS.

### Task 9: Execute training, prospective audit, and publish the winner

**Files:**
- Generated but not committed: `outputs/model_improvement/bread_pipeline_v2_20260715/**`
- Create from audited staging: `models/bread_detector_v2_<sha256>.pt`
- Create from audited staging: `models/bread_classifier_v2_<sha256>.pt`
- Create: `models/bread_pipeline_report.json`
- Modify: `models/bread_pipeline_manifest.json`

**Interfaces:**
- Consumes: Tasks 1-8, source inventory, RTX 5080, system Python 3.11 CUDA environment, and CPU release runtime.
- Produces: selected OOF reports, final weights, contact/error sheets, prospective worker evidence for all 83 mixed images, content-addressed publication, release audit, and installer.

- [ ] **Step 1: Create the pinned training environment and record it**

```powershell
$Root = 'outputs\model_improvement\bread_pipeline_v2_20260715'
python -m venv --system-site-packages "$Root\.venv-train"
& "$Root\.venv-train\Scripts\python.exe" -m pip install --no-deps ultralytics==8.3.40
& "$Root\.venv-train\Scripts\python.exe" -c "import torch, ultralytics; assert torch.cuda.is_available(); assert ultralytics.__version__ == '8.3.40'; print(torch.__version__, torch.cuda.get_device_name(0), ultralytics.__version__)"
```

Expected: prints a CUDA-enabled Torch version, `NVIDIA GeForce RTX 5080`, and `8.3.40`. Save the full package/version/device output into `$Root\environment.json` through the orchestrator.

- [ ] **Step 2: Rebuild and verify the immutable data contract**

```powershell
& "$Root\.venv-train\Scripts\python.exe" -m tools.bread_training.run_improvement prepare-data --raw-root C:\workspace\bixolon_bakery --output $Root --seed 20260715
```

Expected: `3313/3230/83/510`, zero audit issues, five grouped folds, and `source_unchanged=true`.

- [ ] **Step 3: Run smoke training for every trainable candidate**

```powershell
& "$Root\.venv-train\Scripts\python.exe" -m tools.bread_training.run_improvement detector-smoke --output $Root --fold 0 --epochs 1
& "$Root\.venv-train\Scripts\python.exe" -m tools.bread_training.run_improvement classifier-smoke --output $Root --fold 0 --epochs 1
```

Expected: D1/D2/D3 and C1/C2 each produce a loadable `best.pt`, prediction artifact, completion marker, and no held-out source in training/sampling logs.

- [ ] **Step 4: Run detector OOF and stop if its gate fails**

```powershell
& "$Root\.venv-train\Scripts\python.exe" -m tools.bread_training.run_improvement detector-oof --output $Root
```

Expected winner: fewer than baseline's 6 total misses, max one miss per image, precision `>=0.98`, median IoU `>=0.90`, and provisional CPU detector evidence. If no candidate passes, retain reports, do not train/publish later stages, and report the failed gates to the user.

- [ ] **Step 5: Run classifier OOF and stop if its gate fails**

```powershell
& "$Root\.venv-train\Scripts\python.exe" -m tools.bread_training.run_improvement classifier-oof --output $Root
```

Expected winner: detector-crop top-1 `>=0.90`, macro recall `>=0.85`, all 510 held-out annotations represented once per evaluation domain, and five fold weight/prediction hashes.

- [ ] **Step 6: Select global policy and train final models**

```powershell
& "$Root\.venv-train\Scripts\python.exe" -m tools.bread_training.run_improvement select-and-train --output $Root
```

Expected: policy precision `>=0.98`; policy curve and selection report written; final detector/classifier trained for median OOF best epochs; completion hashes validated; source inventory unchanged.

- [ ] **Step 7: Run prospective worker evaluation before publication**

```powershell
runtime\python\python.exe -m tools.bread_training.run_improvement prospective-audit --raw-root C:\workspace\bixolon_bakery --output $Root --cpu-python runtime\python\python.exe
```

Expected: all 83 mixed images pass through bytes -> detector -> padded batch classifier -> policy; report includes detector misses/FPs/IoUs, label errors, accepted precision/coverage, gray/red counts, cold latency, warm median/p95; warm median `<=1000 ms`; contact sheet and miss/FP/classification-error sheets are generated.

- [ ] **Step 8: Atomically publish content-addressed files**

```powershell
& "$Root\.venv-train\Scripts\python.exe" -m tools.bread_training.run_improvement publish --output $Root --models models
runtime\python\python.exe tools\detectors\bread_pipeline_manifest.py models\bread_pipeline_manifest.json
```

Expected: publication copies to temporary siblings, verifies hashes and loaded-model contracts, then replaces manifest last. The manifest is schema 2, uses class map 1-20, crop padding selected from OOF in the allowed 0-5% range, contains the fixed 0.98-precision policy, and points only to existing content-addressed files and the sidecar report.

Restore this repository-level test in `test/tools/test_bread_pipeline_manifest.py` after publication:

```python
def test_current_product_manifest_and_models_are_valid(self):
    path = REPOSITORY_ROOT / "models" / "bread_pipeline_manifest.json"
    manifest = load_pipeline_manifest(path)
    resolved = resolve_model_paths(path, manifest)
    self.assertEqual(manifest.schema_version, 2)
    self.assertEqual(manifest.classifier["classMap"], list(range(1, 21)))
    self.assertTrue(resolved.detector_path.is_file())
    self.assertTrue(resolved.classifier_path.is_file())
    self.assertTrue(resolved.report_path.is_file())
```

- [ ] **Step 9: Run complete tests, release audit, and installer smoke**

```powershell
runtime\python\python.exe -m unittest discover -s test/tools/bread_training -p "test_*.py" -v
runtime\python\python.exe -m unittest discover -s test/tools -p "test_bread_*.py" -v
flutter test
flutter build windows --release
powershell -ExecutionPolicy Bypass -File tools\packaging\verify_release_models.ps1 -ReleaseRoot build\windows\x64\runner\Release
powershell -ExecutionPolicy Bypass -File tools\packaging\build_windows_installer.ps1 -SkipFlutterBuild
```

Expected: every Python/Flutter test PASS; release manifest validation and isolated worker ready smoke pass; release contains only active model/runtime assets; installer completes.

- [ ] **Step 10: Recheck source bytes and commit only audited deployment assets**

```powershell
& "$Root\.venv-train\Scripts\python.exe" -m tools.bread_training.run_improvement verify-source --raw-root C:\workspace\bixolon_bakery --inventory "$Root\source_inventory.json"
git status --short
git add models/bread_pipeline_manifest.json models/bread_pipeline_report.json models/bread_detector_v2_*.pt models/bread_classifier_v2_*.pt test/tools/test_bread_pipeline_manifest.py
git commit -m "feat: publish improved bread inference models"
```

Expected: `source_unchanged=true`; generated `outputs` remain uncommitted/ignored; no pre-existing unrelated dirty file is staged.

### Task 10: Final evidence review and handoff

**Files:**
- Modify: `models/README.md`
- Generated but not committed: `outputs/model_improvement/bread_pipeline_v2_20260715/final_handoff.json`

**Interfaces:**
- Consumes: final manifest/report, release audit, test logs, and source inventory comparison.
- Produces: a concise handoff that states actual achieved metrics and any remaining review-heavy classes without changing the approved global policy.

- [ ] **Step 1: Generate the final handoff report**

```powershell
runtime\python\python.exe -m tools.bread_training.run_improvement handoff --output outputs\model_improvement\bread_pipeline_v2_20260715 --manifest models\bread_pipeline_manifest.json
```

Expected: `final_handoff.json` records source counts/hash, fold schema/seed, winner IDs, baseline vs winner detector evidence, GT vs detector-crop classifier metrics, policy precision/coverage, conservative classes, CPU latency, model/report hashes, test/release/installer results, and rollback manifest/model filenames.

- [ ] **Step 2: Update model documentation with immutable facts**

Add the schema version, content-addressed filenames, canonical class-map rule, fixed global policy rule, report filename, validation command, and rollback procedure to `models/README.md`. Copy actual metric values from `final_handoff.json`; do not claim a gate that the report does not show.

- [ ] **Step 3: Run final verification and commit documentation**

```powershell
runtime\python\python.exe tools\detectors\bread_pipeline_manifest.py models\bread_pipeline_manifest.json
runtime\python\python.exe -m unittest discover -s test/tools -p "test_bread_*.py" -v
flutter test
git add models/README.md
git commit -m "docs: record bread pipeline v2 evidence"
```

Expected: manifest validation succeeds, all tests PASS, and the commit contains only `models/README.md`.

---

## Completion Evidence

Implementation is complete only when `final_handoff.json` proves all of the following: zero catalog issues; unchanged source inventory; no capture-group leakage; fewer detector misses than the six-miss baseline; max one detector miss per image; detector precision `>=0.98`; detector median IoU `>=0.90`; detector-crop classifier top-1 `>=0.90`; detector-crop macro recall `>=0.85`; accepted precision `>=0.98`; full-pipeline warm CPU median `<=1000 ms`; exact model/report hashes; all 83 prospective worker cases executed; Python/Flutter tests passed; release assets audited; installer smoke passed; and no unrelated dirty changes or `outputs/quick_rebuild` artifacts were overwritten.
