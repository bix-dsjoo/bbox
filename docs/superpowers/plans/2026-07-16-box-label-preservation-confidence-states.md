# Box Label Preservation and Confidence States Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve every assigned box label across geometry edits and map classifier confidence to gray, red, or white box states at the exact 0.50 and 0.98 boundaries.

**Architecture:** Keep classification-state decisions in the Python label policy and transport them through the existing worker protocol into Flutter domain models. Geometry editing treats a box with `BoxStatus.labeled` and a non-null `labelId` as immutable with respect to classification, while unlabeled/review boxes remain eligible for debounced reclassification.

**Tech Stack:** Flutter/Dart, Python 3 `unittest`, existing bread worker JSON protocol, Flutter widget and controller tests.

## Global Constraints

- A labeled box keeps its label after move, resize, or direct coordinate editing regardless of whether `labelSource` is `user` or `auto`.
- `candidate.score >= 0.98` produces an automatic label and white outline.
- `0.50 < candidate.score < 0.98` produces a review suggestion and red outline.
- `candidate.score <= 0.50` produces an unlabeled proposal with no suggested label and a gray outline.
- Thresholds use the top classifier candidate score, never detector box confidence.
- Preserve existing uncommitted changes in `models/bread_pipeline_manifest.json`, `test/tools/test_bread_box_worker.py`, and `tools/detectors/bread_box_worker.py`; edit only required hunks.
- Do not change the project snapshot schema or retrain models.

---

### Task 1: Preserve Assigned Labels During Geometry Edits

**Files:**
- Modify: `test/ui/app_controller_auto_box_test.dart:408-475`
- Modify: `lib/ui/app_controller.dart:1928-1966`

**Interfaces:**
- Consumes: `BoundingBox.status`, `BoundingBox.labelId`, `BoundingBox.labelSource`, `AppController._editSelectedBox`.
- Produces: geometry edits that preserve complete labeled-box state and only schedule classification for boxes that still need a label.

- [ ] **Step 1: Write failing preservation tests**

Replace the obsolete “editing makes gray” test and add a user-label regression:

```dart
test('editing an auto-labeled box preserves its label without reclassification', () async {
  final runtime = FakeAutoBoxRuntime();
  final controller = AppController(autoBoxRuntime: runtime)
    ..loadProject(_autoLabeledProject())
    ..selectBox('auto-box');
  addTearDown(controller.dispose);

  controller.setSelectedBoxGeometry(x: 20, y: 20, width: 30, height: 30);
  await Future<void>.delayed(const Duration(milliseconds: 300));

  expect(controller.selectedBox!.status, BoxStatus.labeled);
  expect(controller.selectedBox!.labelId, 1);
  expect(controller.selectedBox!.labelSource, LabelSource.auto);
  expect(runtime.classifyCount, 0);
});

test('editing a user-labeled automatic box preserves the user label', () async {
  final runtime = FakeAutoBoxRuntime();
  final controller = AppController(autoBoxRuntime: runtime)
    ..loadProject(_autoLabeledProject())
    ..selectBox('auto-box');
  addTearDown(controller.dispose);
  controller.assignSelectedBoxLabel(2);

  controller.moveSelectedBox(1, 0);
  await Future<void>.delayed(const Duration(milliseconds: 300));

  expect(controller.selectedBox!.status, BoxStatus.labeled);
  expect(controller.selectedBox!.labelId, 2);
  expect(controller.selectedBox!.labelSource, LabelSource.user);
  expect(runtime.classifyCount, 0);
});
```

- [ ] **Step 2: Run tests and verify RED**

```powershell
flutter test test/ui/app_controller_auto_box_test.dart --plain-name "editing an auto-labeled box preserves its label without reclassification"
flutter test test/ui/app_controller_auto_box_test.dart --plain-name "editing a user-labeled automatic box preserves the user label"
```

Expected: failures show the label reset and unwanted classify request.

- [ ] **Step 3: Implement the smallest controller fix**

In `_editSelectedBox`, derive assignment from domain state rather than automation history:

```dart
final hasAssignedLabel =
    box.status == BoxStatus.labeled && box.labelId != null;
final shouldReclassify = !hasAssignedLabel;
final updatedBox = editedBox;
```

Keep the image transition to `ImageStatus.needsReview`, autosave, notification, and debounced classify call only when `shouldReclassify` is true. Do not clear current automation metadata for red/gray proposals while their replacement is pending.

- [ ] **Step 4: Run controller tests and verify GREEN**

```powershell
flutter test test/ui/app_controller_auto_box_test.dart
```

Expected: all pass; rapid edits of unlabeled/review boxes still produce one classification request.

- [ ] **Step 5: Commit**

```powershell
git add lib/ui/app_controller.dart test/ui/app_controller_auto_box_test.dart
git commit -m "fix: preserve box labels during geometry edits"
```

---

### Task 2: Implement Exact Classifier Confidence States

**Files:**
- Modify: `test/tools/test_bread_label_policy.py`
- Modify: `tools/detectors/bread_label_policy.py`
- Modify: `models/bread_pipeline_manifest.json`

**Interfaces:**
- Consumes: ordered `LabelCandidate` values from `normalized_scores`.
- Produces: `LabelDecision` using the exact top-score boundaries.

- [ ] **Step 1: Write failing boundary tests**

```python
def test_classifier_confidence_maps_to_exact_ui_states(self) -> None:
    cases = (
        (0.50, "unavailable", None, None),
        (0.5001, "review", None, 3),
        (0.9799, "review", None, 3),
        (0.98, "accepted", 3, None),
    )
    for confidence, state, label_id, suggested_id in cases:
        with self.subTest(confidence=confidence):
            decision = classify_policy(
                scores(top1=3, confidence=confidence, margin=0.40),
                normal_box(),
                (1920, 1080),
                manifest(accept_confidence=0.98),
            )
            self.assertEqual(decision.state, state)
            self.assertEqual(decision.label_id, label_id)
            self.assertEqual(decision.suggested_label_id, suggested_id)
```

Also add a high-confidence quality-warning case asserting that `0.98` remains `accepted` while diagnostic reasons may remain attached.

- [ ] **Step 2: Run and verify RED**

```powershell
python -m unittest test.tools.test_bread_label_policy.BreadLabelPolicyTest.test_classifier_confidence_maps_to_exact_ui_states -v
```

Expected: 0.50 currently returns `review`, and margin/quality rules can prevent 0.98 acceptance.

- [ ] **Step 3: Implement the three-way policy**

Add fixed product thresholds and branch on the top candidate:

```python
UNLABELED_CONFIDENCE_MAX = 0.50
AUTO_LABEL_CONFIDENCE_MIN = 0.98

top = candidates[0]
if top.score <= UNLABELED_CONFIDENCE_MAX:
    return LabelDecision(
        state="unavailable",
        label_id=None,
        suggested_label_id=None,
        candidates=top_candidates,
        review_reasons=("classifier_low_confidence",),
        embedding_used=False,
    )
if top.score < AUTO_LABEL_CONFIDENCE_MIN:
    return LabelDecision(
        state="review",
        label_id=None,
        suggested_label_id=top.label_id,
        candidates=top_candidates,
        review_reasons=("classifier_confidence_review",),
        embedding_used=False,
    )
return LabelDecision(
    state="accepted",
    label_id=top.label_id,
    suggested_label_id=None,
    candidates=top_candidates,
    review_reasons=quality_reasons(
        det_box, image_size, _manifest_section(manifest, "quality")
    ),
    embedding_used=False,
)
```

Retain score normalization and validation. Legacy ambiguity helpers may remain for training callers, but margin, conservative class, verifier, edge, and duplicate diagnostics must not downgrade a `>= 0.98` result. Update only `classifier.acceptConfidence` to `0.98` in the dirty manifest; preserve hashes, model settings, and metrics.

- [ ] **Step 4: Run policy and manifest tests**

```powershell
python -m unittest test.tools.test_bread_label_policy test.tools.test_bread_pipeline_manifest -v
```

Expected: all pass and exact boundaries are covered.

- [ ] **Step 5: Commit intended hunks only**

Inspect `git diff -- models/bread_pipeline_manifest.json`; stage only the threshold hunk when unrelated user changes remain.

```powershell
git add tools/detectors/bread_label_policy.py test/tools/test_bread_label_policy.py
git add -p models/bread_pipeline_manifest.json
git commit -m "feat: map classifier confidence to review states"
```

---

### Task 3: Preserve Confidence States Through Worker and Flutter

**Files:**
- Modify: `test/tools/test_bread_box_worker.py`
- Modify: `tools/detectors/bread_box_worker.py`
- Modify: `test/detector/auto_box_service_test.dart`
- Modify: `test/ui/workbench/canvas_overlay_test.dart`

**Interfaces:**
- Consumes: worker states `accepted`, `review`, and `unavailable`.
- Produces: Flutter white auto-label boxes, red review proposals, and gray suggestion-free proposals.

- [ ] **Step 1: Write failing worker and Dart tests**

Add worker assertions that edge/duplicate diagnostics do not convert an accepted high-confidence decision to review. Add an `unavailable` fixture with non-empty candidates and `suggestedLabelId: null`, then assert:

```dart
expect(box.status, BoxStatus.proposal);
expect(box.labelId, isNull);
expect(box.automation?.suggestedLabelId, isNull);
expect(box.requiresLabelReview, isFalse);
expect(box.automation?.candidates.first.score, 0.50);
```

Keep review and accepted fixtures, using candidate scores `0.75` and `0.98`. Extend canvas tests to assert gray for low, danger red for review, and white for accepted.

- [ ] **Step 2: Run focused tests and verify RED**

```powershell
python -m unittest test.tools.test_bread_box_worker -v
flutter test test/detector/auto_box_service_test.dart
flutter test test/ui/workbench/canvas_overlay_test.dart
```

Expected: worker quality helpers currently downgrade accepted labels; the low-confidence fixture exposes protocol or color mismatches.

- [ ] **Step 3: Keep diagnostics without downgrading accepted state**

```python
def _add_review_reason(label, reason):
    result = dict(label)
    reasons = list(result.get("reviewReasons", []))
    if reason not in reasons:
        reasons.append(reason)
    result["reviewReasons"] = reasons
    return result
```

Do not disturb the existing runtime-path import fix in the dirty worker file. Flutter production color code should remain unchanged because it already maps labeled to white, `requiresLabelReview` to red, and remaining proposals to gray.

- [ ] **Step 4: Run focused regressions**

```powershell
python -m unittest test.tools.test_bread_label_policy test.tools.test_bread_box_worker test.tools.test_bread_pipeline_manifest -v
flutter test test/detector/auto_box_service_test.dart test/ui/app_controller_auto_box_test.dart test/ui/workbench/canvas_overlay_test.dart test/ui/workbench/quick_label_bar_test.dart
flutter analyze
```

Expected: all commands exit 0.

- [ ] **Step 5: Commit intended hunks only**

Inspect diffs and use patch staging so packaging/runtime user changes remain unstaged.

```powershell
git add -p tools/detectors/bread_box_worker.py test/tools/test_bread_box_worker.py
git add test/detector/auto_box_service_test.dart test/ui/workbench/canvas_overlay_test.dart
git commit -m "test: verify confidence-driven box colors"
```

---

### Task 4: Final Verification

**Files:**
- Verify only; no production edits expected.

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: fresh evidence for label preservation, exact boundaries, worker protocol, UI colors, and static analysis.

- [ ] **Step 1: Run Python detector tests**

```powershell
python -m unittest discover -s test/tools -p "test_bread*.py" -v
```

Expected: exit 0, no failures.

- [ ] **Step 2: Run full Flutter tests**

```powershell
flutter test
```

Expected: exit 0, all pass.

- [ ] **Step 3: Run analysis and diff checks**

```powershell
flutter analyze
git diff --check
git status --short --branch
```

Expected: analysis and diff checks exit 0; status contains only intentional changes plus pre-existing user-owned changes.

- [ ] **Step 4: Review requirement evidence**

Confirm from fresh output:

- labeled boxes retain labels after geometry edits and make zero classify calls;
- 0.50 is gray/unlabeled;
- values strictly between 0.50 and 0.98 are red/review;
- 0.98 is white/auto-labeled;
- user-owned dirty changes were not overwritten.
