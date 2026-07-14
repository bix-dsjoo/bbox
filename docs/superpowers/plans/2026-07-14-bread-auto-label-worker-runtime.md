# Bread Auto-Label Worker Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the persistent Python worker to run the selected detector, batch classifier, and optional ambiguity-only verifier, returning accepted labels or review-required suggestions through a versioned binary protocol.

**Architecture:** The worker consumes `models/bread_pipeline_manifest.json`, validates model hashes, and keeps every selected model loaded for the process lifetime. Detection and classification are separate engine stages so classifier failure can preserve gray detector boxes, while verifier failure converts only ambiguous boxes to red review results.

**Tech Stack:** Python 3.12, OpenCV, NumPy, PyTorch CPU, torchvision, Ultralytics YOLO, Dart worker protocol fixtures, PowerShell release packaging.

## Global Constraints

- Consume manifest schema version 1 from `2026-07-14-bread-model-data-evaluation.md`; do not hard-code category order or calibration thresholds in worker code.
- Keep the detector and classifier loaded once per persistent worker process. Construct and load a verifier only when manifest `verifier.kind` is not `none`; `kind=none` must leave both the verifier path and runtime verifier object unset.
- Run classifier inference as one crop batch per image; invoke the verifier only for classifier-ambiguous crops.
- Return original-image pixel coordinates; reject non-finite values, clamp finite coordinates to image bounds, and discard a box when clamping leaves non-positive width or height.
- A confident result with no quality reason returns an accepted label; any quality warning prevents automatic acceptance even when classification confidence is high.
- Classifier failure returns detector boxes with unavailable label metadata; verifier failure returns ambiguous red-review metadata.
- Preserve one automatic worker restart on transport/protocol/inference failure.
- Warm p50 must be at most 1,000 ms, warm p95 at most 2,000 ms, and cold ready time at most 15,000 ms on the target Windows CPU.
- Release packaging must include exactly the manifest, selected detector, selected classifier, and a verifier weight only when manifest `verifier.kind` is not `none`.

---

## File Structure

- `tools/detectors/bread_pipeline_manifest.py`: schema, label registry, path resolution, and SHA-256 validation.
- `tools/detectors/bread_label_policy.py`: immutable candidates/results, ambiguity policy, quality reasons, and verifier decision.
- `tools/detectors/bread_box_worker.py`: model lifecycle, byte decode, detect/classify request dispatch, and framed protocol.
- `tools/detectors/benchmark_bread_pipeline.py`: cold/warm latency report on real images.
- `test/tools/test_bread_pipeline_manifest.py`: manifest validation tests.
- `test/tools/test_bread_label_policy.py`: acceptance/review/fallback tests.
- `test/tools/test_bread_box_worker.py`: protocol and integrated engine tests.
- `test/tools/test_bread_pipeline_benchmark.py`: percentile and gate report tests.
- `tools/packaging/verify_release_models.ps1`: exact manifest-driven release asset allow-list.
- `models/README.md`: product runtime model contract.

### Task 1: Manifest loader and hash validation

**Files:**
- Create: `tools/detectors/bread_pipeline_manifest.py`
- Create: `test/tools/test_bread_pipeline_manifest.py`

**Interfaces:**
- Consumes: `models/bread_pipeline_manifest.json` from the model-selection plan.
- Produces: `load_pipeline_manifest(path: Path) -> PipelineManifest`.
- Produces: `resolve_model_paths(manifest_path: Path, manifest: PipelineManifest) -> ResolvedModels`.

- [ ] **Step 1: Write failing manifest tests**

```python
def test_loads_twenty_stable_labels_and_resolves_sibling_weights(self):
    manifest = load_pipeline_manifest(self.write_valid_manifest())
    self.assertEqual(tuple(label.id for label in manifest.labels), tuple(range(1, 21)))
    self.assertEqual(manifest.labels[15].name, "Grain Campagne")

def test_detector_hash_mismatch_is_fatal():
    path = self.write_valid_manifest(detector_sha256="0" * 64)
    with self.assertRaisesRegex(ManifestError, "detector sha256 mismatch"):
        resolve_model_paths(path, load_pipeline_manifest(path))

def test_classifier_hash_failure_is_reported_as_optional_stage_error():
    path = self.write_valid_manifest(classifier_file="missing.pt")
    resolved = resolve_model_paths(path, load_pipeline_manifest(path))
    self.assertIsNotNone(resolved.classifier_error)
    self.assertIsNone(resolved.classifier_path)

def test_none_verifier_resolves_without_a_model_path_or_error():
    path = self.write_valid_manifest(verifier={"kind": "none", "file": None, "sha256": None, "scoreThreshold": None, "marginThreshold": None})
    resolved = resolve_model_paths(path, load_pipeline_manifest(path))
    self.assertIsNone(resolved.verifier_path)
    self.assertIsNone(resolved.verifier_error)
```

- [ ] **Step 2: Run tests and verify failure**

Run: `python -m unittest test.tools.test_bread_pipeline_manifest -v`

Expected: FAIL because the loader module does not exist.

- [ ] **Step 3: Implement typed schema and staged validation**

```python
@dataclass(frozen=True)
class LabelSpec:
    id: int
    name: str

@dataclass(frozen=True)
class PipelineManifest:
    schema_version: int
    pipeline_version: str
    policy_version: str
    detector: dict
    classifier: dict
    verifier: dict
    quality: dict
    labels: tuple[LabelSpec, ...]

def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def validate_labels(labels):
    if [item.id for item in labels] != list(range(1, 21)):
        raise ManifestError("labels must contain ordered IDs 1 through 20")
    if labels[15].name != "Grain Campagne":
        raise ManifestError("category 16 must be Grain Campagne")
```

Detector path/hash errors raise `ManifestError`. Classifier and verifier path/hash errors populate `ResolvedModels.classifier_error` or `verifier_error` so detection can remain available in degraded mode.
For manifest `verifier.kind == "none"`, do not resolve, hash, import, or construct any verifier implementation; return `verifier_path=None` and `verifier_error=None` as the intentional disabled state.

- [ ] **Step 4: Run tests and real manifest validation**

Run: `python -m unittest test.tools.test_bread_pipeline_manifest -v`

Expected: PASS.

Run: `python -m tools.detectors.bread_pipeline_manifest models\bread_pipeline_manifest.json`

Expected: detector is valid, label IDs are 1–20, and optional-stage availability is printed as JSON.

- [ ] **Step 5: Commit**

```powershell
git add tools/detectors/bread_pipeline_manifest.py test/tools/test_bread_pipeline_manifest.py
git commit -m "feat: validate bread pipeline manifest"
```

### Task 2: Automatic-label policy and quality reasons

**Files:**
- Create: `tools/detectors/bread_label_policy.py`
- Create: `test/tools/test_bread_label_policy.py`

**Interfaces:**
- Consumes: manifest thresholds and ordered labels.
- Produces: `classify_policy(classifier_scores, det_box, image_size, manifest, verifier=None) -> LabelDecision`.
- Produces JSON-compatible `LabelDecision.to_json()` used unchanged by the worker response.

- [ ] **Step 1: Write failing policy tests**

```python
def test_confident_prediction_is_accepted():
    decision = classify_policy(scores(top1=3, confidence=.995, margin=.60), normal_box(), (1920, 1080), manifest())
    self.assertEqual(decision.state, "accepted")
    self.assertEqual(decision.label_id, 3)
    self.assertEqual(decision.review_reasons, ())

def test_quality_warning_forces_review_even_when_confident():
    decision = classify_policy(scores(top1=3, confidence=.995, margin=.60), edge_box(), (1920, 1080), manifest())
    self.assertEqual(decision.state, "review")
    self.assertIsNone(decision.label_id)
    self.assertEqual(decision.suggested_label_id, 3)
    self.assertIn("edge_clipped", decision.review_reasons)

def test_ambiguous_verifier_failure_stays_review():
    decision = classify_policy(scores(top1=4, confidence=.70, margin=.02), normal_box(), (1920, 1080), manifest(), verifier=FailingVerifier())
    self.assertEqual(decision.state, "review")
    self.assertIn("verifier_failed", decision.review_reasons)
```

- [ ] **Step 2: Run tests and verify failure**

Run: `python -m unittest test.tools.test_bread_label_policy -v`

Expected: FAIL because the policy module does not exist.

- [ ] **Step 3: Implement deterministic decision states**

```python
@dataclass(frozen=True)
class LabelCandidate:
    label_id: int
    score: float

@dataclass(frozen=True)
class LabelDecision:
    state: str
    label_id: int | None
    suggested_label_id: int | None
    candidates: tuple[LabelCandidate, ...]
    review_reasons: tuple[str, ...]
    embedding_used: bool

def quality_reasons(box, image_size, quality):
    width, height = image_size
    reasons = []
    if box.width < quality["minBoxSize"] or box.height < quality["minBoxSize"]:
        reasons.append("too_small")
    if min(box.x, box.y, width - box.right, height - box.bottom) <= quality["edgeMarginPx"]:
        reasons.append("edge_clipped")
    if box.area / (width * height) > quality["maxAreaRatio"]:
        reasons.append("area_outlier")
    return tuple(reasons)
```

Sort candidates by descending score and ascending label ID, keep exactly three when available, and define ambiguity as top-1 confidence below `acceptConfidence`, margin below `acceptMargin`, or top-1 category in `conservativeClasses`. Only verifier agreement that passes both verifier thresholds may remove the classifier ambiguity reason; quality reasons always remain blocking.

- [ ] **Step 4: Run policy tests**

Run: `python -m unittest test.tools.test_bread_label_policy -v`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add tools/detectors/bread_label_policy.py test/tools/test_bread_label_policy.py
git commit -m "feat: decide automatic bread labels"
```

### Task 3: Batch classifier and conditional verifier engine

**Files:**
- Modify: `tools/detectors/bread_box_worker.py`
- Modify: `test/tools/test_bread_box_worker.py`

**Interfaces:**
- Consumes: `PipelineManifest`, `ResolvedModels`, and `classify_policy`.
- Produces: `BreadInferenceEngine.detect_bytes(payload, max_proposals=None) -> dict`.
- Produces: `BreadInferenceEngine.classify_bytes(payload, boxes) -> dict` for edited/manual boxes.

- [ ] **Step 1: Add failing engine tests with fake detector/classifier/verifier**

```python
def test_classifier_receives_one_crop_batch_and_verifier_only_ambiguous_crop():
    engine = pipeline_engine(two_box_detector(), batch_classifier(one_confident_one_ambiguous()), recording_verifier())
    result = engine.detect_bytes(png_bytes())
    self.assertEqual(engine.classifier.calls[0].batch_size, 2)
    self.assertEqual(engine.verifier.crop_count, 1)
    self.assertEqual([item["label"]["state"] for item in result["boxes"]], ["accepted", "review"])

def test_none_verifier_manifest_skips_verifier_construction():
    factory = RecordingVerifierFactory()
    engine = pipeline_engine_from_manifest(manifest(verifier_kind="none"), verifier_factory=factory)
    result = engine.detect_bytes(png_bytes())
    self.assertEqual(factory.calls, [])
    self.assertIsNone(engine.verifier)
    self.assertEqual(result["boxes"][1]["label"]["state"], "review")

def test_classifier_failure_preserves_gray_boxes():
    engine = pipeline_engine(two_box_detector(), failing_classifier(), None)
    result = engine.detect_bytes(png_bytes())
    self.assertEqual(len(result["boxes"]), 2)
    self.assertTrue(all(item["label"]["state"] == "unavailable" for item in result["boxes"]))
    self.assertEqual(result["stageErrors"][0]["stage"], "classifier")

def test_classify_request_uses_supplied_original_pixel_boxes():
    result = engine().classify_bytes(png_bytes(), [{"id": "manual-1", "x": 2, "y": 3, "width": 10, "height": 11}])
    self.assertEqual(result["boxes"][0]["id"], "manual-1")
    self.assertEqual(result["boxes"][0]["x"], 2)

def test_finite_boundary_overrun_is_clamped_and_marked_for_review():
    result = pipeline_engine(detector_box(-.2, 2, 20, 20), confident_classifier(), None).detect_bytes(png_bytes())
    self.assertEqual(result["boxes"][0]["x"], 0)
    self.assertIn("edge_clipped", result["boxes"][0]["label"]["reviewReasons"])
```

- [ ] **Step 2: Run worker tests and verify failure**

Run: `python -m unittest test.tools.test_bread_box_worker -v`

Expected: FAIL on the missing pipeline engine and classify path.

- [ ] **Step 3: Refactor the worker engine without changing framing**

```python
def classify_crops(self, image, boxes):
    crops = [crop_box(image, item["xyxy"]) for item in boxes]
    if self.classifier is None:
        return [unavailable_label(self.classifier_error) for _ in boxes], [stage_error("classifier", self.classifier_error)]
    results = self.classifier.predict(crops, imgsz=self.manifest.classifier["imgsz"], batch=min(16, len(crops)), verbose=False, device="cpu")
    decisions = []
    for box, crop, result in zip(boxes, crops, results):
        scores = normalized_scores(result.probs.data, self.manifest.labels)
        verifier = self.verifier if is_ambiguous_scores(scores, self.manifest) else None
        decisions.append(classify_policy(scores, box, self.image_size, self.manifest, verifier=verifier))
    return decisions, []
```

The engine factory must branch on the validated manifest before any verifier import or construction. When `verifier.kind == "none"`, assign `self.verifier = None`, do not call `verifier_factory`, and leave classifier-ambiguous decisions in `review`. Only non-`none` verifier kinds may resolve and construct the optional verifier once for the worker lifetime.

Calculate SHA-256 from request bytes and return it in `image.sha256`. Clamp finite detector and supplied-classification coordinates to decoded dimensions, discard zero-area results, and add `edge_clipped` when clamping changed a box. Apply duplicate-IoU review reasons after NMS.

- [ ] **Step 4: Run worker tests**

Run: `python -m unittest test.tools.test_bread_box_worker test.tools.test_bread_label_policy -v`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add tools/detectors/bread_box_worker.py test/tools/test_bread_box_worker.py
git commit -m "feat: run bread detector and classifier pipeline"
```

### Task 4: Protocol version 2 detect/classify responses

**Files:**
- Modify: `tools/detectors/bread_box_worker.py`
- Modify: `test/tools/test_bread_box_worker.py`
- Create: `docs/worker-protocol-v2.md`

**Interfaces:**
- Produces request types `detect`, `classify`, and `shutdown` at protocol version 2.
- Produces ready message capabilities and a stable nested box-label response consumed by Dart.

- [ ] **Step 1: Write failing framed-protocol tests**

```python
def test_ready_advertises_protocol_and_capabilities():
    ready = response_frames(run_worker_once(b""))[0]
    self.assertEqual(ready["version"], 2)
    self.assertEqual(ready["capabilities"], {"detect": True, "classify": True, "autoLabel": True, "verifier": False})

def test_classify_header_boxes_are_returned_with_label_decisions():
    frame = request_frame("r2", png_bytes(), request_type="classify", boxes=[{"id": "b1", "x": 1, "y": 1, "width": 10, "height": 10}])
    response = response_frames(run_worker_once(frame))[1]
    self.assertEqual(response["type"], "result")
    self.assertEqual(response["boxes"][0]["id"], "b1")
    self.assertEqual(response["boxes"][0]["label"]["state"], "accepted")
```

- [ ] **Step 2: Run protocol tests and verify failure**

Run: `python -m unittest test.tools.test_bread_box_worker.WorkerProtocolTest -v`

Expected: FAIL because version 2 and classify dispatch are not implemented.

- [ ] **Step 3: Implement and document the exact response contract**

```json
{
  "version": 2,
  "type": "result",
  "requestId": "auto-box-1",
  "pipelineVersion": "bread-pipeline-v1",
  "policyVersion": "bread-label-policy-v1",
  "detectorName": "bread-yolo-boxes",
  "modelHashes": {"detector": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "classifier": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "verifier": null},
  "image": {"width": 1920, "height": 1080, "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},
  "boxes": [{
    "id": "b1", "x": 10.0, "y": 20.0, "width": 100.0, "height": 80.0, "confidence": 0.98,
    "label": {"state": "review", "labelId": null, "suggestedLabelId": 3, "candidates": [{"labelId": 3, "score": 0.72}], "reviewReasons": ["classifier_ambiguous"], "embeddingUsed": true}
  }],
  "stageErrors": []
}
```

Replace the illustrative image hash with `hashlib.sha256(payload).hexdigest()` at runtime. Populate model hashes from the validated manifest rather than recalculating them per request. Reject unknown message types, version mismatches, more than 100 supplied boxes, and headers over the existing 64 KiB limit.

- [ ] **Step 4: Run all worker tests**

Run: `python -m unittest test.tools.test_bread_box_worker test.tools.test_bread_pipeline_manifest test.tools.test_bread_label_policy -v`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add tools/detectors/bread_box_worker.py test/tools/test_bread_box_worker.py docs/worker-protocol-v2.md
git commit -m "feat: add bread worker protocol v2"
```

### Task 5: Manifest-driven release packaging

**Files:**
- Modify: `tools/packaging/verify_release_models.ps1`
- Modify: `test/packaging/installer_script_test.dart`
- Modify: `models/README.md`

**Interfaces:**
- Consumes: pipeline manifest and selected local model files.
- Produces: a release allow-list derived from manifest filenames, with no research weights.

- [ ] **Step 1: Add failing packaging assertions**

```dart
test('release verifier requires manifest detector classifier and optional verifier', () {
  final script = File('tools/packaging/verify_release_models.ps1').readAsStringSync();
  expect(script, contains('bread_pipeline_manifest.json'));
  expect(script, contains('classifier.file'));
  expect(script, contains('verifier.kind'));
  expect(script, contains('Get-FileHash'));
});
```

- [ ] **Step 2: Run packaging test and verify failure**

Run: `flutter test test/packaging/installer_script_test.dart`

Expected: FAIL because packaging only permits the current detector.

- [ ] **Step 3: Implement manifest-driven checks**

```powershell
$manifestPath = Join-Path $releaseRoot "models\bread_pipeline_manifest.json"
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$required = @($manifest.detector, $manifest.classifier)
if ($manifest.verifier.kind -ne "none") { $required += $manifest.verifier }
foreach ($model in $required) {
  $path = Join-Path (Split-Path $manifestPath) $model.file
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required pipeline model was not found: $path" }
  $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $model.sha256) { throw "Pipeline model checksum mismatch: $path" }
}
```

Keep the existing torch, torchvision, OpenCV, NumPy, and Ultralytics pins unchanged. Do not add OpenCLIP because the concrete verifier candidates use already bundled torch/torchvision and a local manifest-selected `.pt` bundle.

- [ ] **Step 4: Run packaging tests**

Run: `flutter test test/packaging/installer_script_test.dart test/packaging/version_consistency_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add tools/packaging/verify_release_models.ps1 test/packaging/installer_script_test.dart models/README.md
git commit -m "build: package bread label pipeline"
```

### Task 6: Cold/warm CPU benchmark and final worker verification

**Files:**
- Create: `tools/detectors/benchmark_bread_pipeline.py`
- Create: `test/tools/test_bread_pipeline_benchmark.py`

**Interfaces:**
- Produces: `summarize_latencies(cold_ms: float, warm_ms: list[float]) -> dict`.
- Produces: non-zero exit when cold, p50, or p95 gates fail.

- [ ] **Step 1: Write failing percentile and gate tests**

```python
def test_latency_summary_uses_nearest_rank_percentiles():
    summary = summarize_latencies(9000, [400, 500, 600, 700, 800])
    self.assertEqual(summary["p50Ms"], 600)
    self.assertEqual(summary["p95Ms"], 800)
    self.assertTrue(summary["accepted"])

def test_latency_gate_rejects_slow_p95():
    self.assertFalse(summarize_latencies(9000, [400, 500, 2100])["accepted"])
```

- [ ] **Step 2: Run benchmark tests and verify failure**

Run: `python -m unittest test.tools.test_bread_pipeline_benchmark -v`

Expected: FAIL because the benchmark module does not exist.

- [ ] **Step 3: Implement fresh-process cold timing and 30-image warm timing**

```python
def nearest_rank(values, percentile):
    ordered = sorted(values)
    index = max(0, math.ceil(percentile * len(ordered)) - 1)
    return ordered[index]

def summarize_latencies(cold_ms, warm_ms):
    p50 = nearest_rank(warm_ms, .50)
    p95 = nearest_rank(warm_ms, .95)
    return {"coldMs": cold_ms, "p50Ms": p50, "p95Ms": p95, "accepted": cold_ms <= 15000 and p50 <= 1000 and p95 <= 2000}
```

The CLI starts a fresh worker for cold timing, sends one untimed warm-up inference, then measures the 30 real images in `Test_20260714` through the framed protocol.

- [ ] **Step 4: Run all Python tests and target benchmark**

Run: `python -m unittest discover -s test/tools -p "test_*.py" -v`

Expected: PASS with zero failures and zero errors.

Run: `python tools\detectors\benchmark_bread_pipeline.py --python runtime\python\python.exe --worker tools\detectors\bread_box_worker.py --manifest models\bread_pipeline_manifest.json --images C:\workspace\bixolon_bakery\Test_20260714 --output outputs\benchmarks\bread_pipeline_windows_cpu.json`

Expected: exit 0 only when cold <= 15,000 ms, p50 <= 1,000 ms, and p95 <= 2,000 ms.

- [ ] **Step 5: Commit**

```powershell
git add tools/detectors/benchmark_bread_pipeline.py test/tools/test_bread_pipeline_benchmark.py
git commit -m "test: benchmark bread inference pipeline"
```
