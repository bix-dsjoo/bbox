# Flutter Auto-Label Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate worker protocol v2 into Flutter so accepted automatic labels are white, ambiguous suggestions are red and reviewable, unlabeled boxes are gray, label names alone use category colors, and COCO exports only real labels.

**Architecture:** Extend the annotation domain with immutable automation evidence while keeping `labelId` as the single export truth. `AutoBoxService` parses worker decisions and exposes detect plus classify-existing-box operations; `AppController` applies each completed operation atomically, supports one-step Undo, debounced reclassification after box edits, and never auto-confirms an image.

**Tech Stack:** Flutter/Dart, ChangeNotifier, JSON project persistence, persistent Python worker protocol v2, widget/unit/integration tests, Windows desktop.

## Global Constraints

- Preserve existing label shortcuts `1`–`0`, `Q`–`P`; do not bind unmodified number keys to recommendation ranks.
- `Enter` accepts the selected red box's current top-1 suggestion only when no text field has focus.
- Accepted automatic labels use `BoxStatus.labeled`, non-null `labelId`, and `LabelSource.auto`.
- Ambiguous boxes use `BoxStatus.proposal`, null `labelId`, non-null `suggestedLabelId`, and non-empty review reasons.
- Gray boxes have no real label and no usable suggestion.
- White box outlines indicate a real label; red indicates review required; gray indicates unlabeled or classifier unavailable. Only the label-name badge uses the category's unique color.
- Red and gray boxes are excluded from COCO; unconfirmed images remain exportable with an explicit warning summary.
- Red or gray boxes disable image confirmation; AI never changes an image to confirmed automatically.
- Existing boxes require explicit replacement confirmation before rerunning automatic boxes; the replacement is one Undo operation.
- Editing a box immediately invalidates its prior automatic decision and triggers reclassification after the edit settles.
- All coordinates remain original-image pixels, and all worker results are validated before application.
- Existing schema-version-2 projects load without losing labels or boxes and save as schema version 3.

---

## File Structure

- `lib/annotation/models.dart`: label candidate, source, automation evidence, image checksum, and serialization.
- `lib/annotation/annotation_rules.dart`: accepted-suggestion transition, manual-label transition, confirmation rules.
- `lib/project/project_store.dart`: schema 2-to-3 migration.
- `lib/detector/worker_protocol.dart`: protocol version 2 constant and validation limits.
- `lib/detector/bread_worker_client.dart`: manifest startup argument plus detect/classify requests.
- `lib/detector/auto_box_service.dart`: response parsing, cache, stage fallback, and `classifyBoxes` API.
- `lib/detector/detector.dart`: extended `DetectionResult` metadata.
- `lib/ui/app_controller.dart`: atomic replacement, Enter acceptance, edit invalidation, debounced reclassification.
- `lib/ui/auto_box_replace_dialog.dart`: shared rerun confirmation for button and shortcut.
- `lib/ui/workbench/image_canvas.dart`: white/red/gray outlines and colored label badges.
- `lib/ui/workbench/inspector_panel.dart`: review reasons and top candidates.
- `lib/ui/workbench/workbench_screen.dart`: Enter handling and confirmed rerun entrypoint.
- `lib/ui/workbench/center_toolbar.dart`: confirmed rerun entrypoint.
- `lib/ui/workbench/workbench_feedback.dart`: visible cancellation action while automation is running.
- `lib/export/coco_exporter.dart` and `lib/ui/coco_export_warning_dialog.dart`: expanded counts and exclusion messaging.
- Matching tests under `test/annotation`, `test/project`, `test/detector`, `test/ui/workbench`, `test/export`, and `test/integration`.

### Task 1: Domain model for accepted labels and temporary suggestions

**Files:**
- Modify: `lib/annotation/models.dart`
- Modify: `lib/annotation/annotation_rules.dart`
- Modify: `test/annotation/annotation_rules_test.dart`
- Create: `test/annotation/automation_metadata_test.dart`

**Interfaces:**
- Produces: `enum LabelSource { auto, user }`.
- Produces: `LabelCandidate(labelId, score)` and `BoxAutomationMetadata`.
- Produces: `BoundingBox.requiresLabelReview`, `BoundingBox.isAutoLabeled`, and `BoundingBox.displayLabelId`.
- Produces: `AnnotationRules.acceptSuggestedLabel(image, boxId)`.

- [ ] **Step 1: Write failing serialization and transition tests**

```dart
test('red suggestion is not a real label', () {
  final box = reviewBox(suggestedLabelId: 3, reasons: const ['classifier_ambiguous']);
  expect(box.status, BoxStatus.proposal);
  expect(box.labelId, isNull);
  expect(box.displayLabelId, 3);
  expect(box.requiresLabelReview, isTrue);
});

test('accept suggestion creates a user-approved white label', () {
  final updated = AnnotationRules.acceptSuggestedLabel(reviewImage(), boxId: 'b1');
  final box = updated.visibleBoxes.single;
  expect(box.status, BoxStatus.labeled);
  expect(box.labelId, 3);
  expect(box.labelSource, LabelSource.user);
  expect(box.requiresLabelReview, isFalse);
});

test('automation metadata round trips through JSON', () {
  final restored = BoundingBox.fromJson(autoLabeledBox().toJson());
  expect(restored.automation?.pipelineVersion, 'bread-pipeline-v1');
  expect(restored.labelSource, LabelSource.auto);
});
```

- [ ] **Step 2: Run focused tests and verify failure**

Run: `flutter test test/annotation/automation_metadata_test.dart test/annotation/annotation_rules_test.dart`

Expected: FAIL because automation types and acceptance transition are missing.

- [ ] **Step 3: Implement immutable types and invariants**

```dart
enum LabelSource { auto, user }

class LabelCandidate {
  const LabelCandidate({required this.labelId, required this.score});
  final int labelId;
  final double score;
  Map<String, Object?> toJson() => {'labelId': labelId, 'score': score};
  factory LabelCandidate.fromJson(Map<String, Object?> json) => LabelCandidate(
    labelId: json['labelId'] as int,
    score: (json['score'] as num).toDouble(),
  );
}

class BoxAutomationMetadata {
  const BoxAutomationMetadata({
    this.suggestedLabelId,
    this.candidates = const [],
    this.reviewReasons = const [],
    required this.pipelineVersion,
    required this.policyVersion,
    required this.detectorSha256,
    this.classifierSha256,
    this.verifierSha256,
    this.embeddingUsed = false,
  });
  final int? suggestedLabelId;
  final List<LabelCandidate> candidates;
  final List<String> reviewReasons;
  final String pipelineVersion;
  final String policyVersion;
  final String detectorSha256;
  final String? classifierSha256;
  final String? verifierSha256;
  final bool embeddingUsed;

  BoxAutomationMetadata copyWith({Object? suggestedLabelId = _unchanged, List<LabelCandidate>? candidates, List<String>? reviewReasons}) => BoxAutomationMetadata(
    suggestedLabelId: identical(suggestedLabelId, _unchanged) ? this.suggestedLabelId : suggestedLabelId as int?,
    candidates: candidates ?? this.candidates,
    reviewReasons: reviewReasons ?? this.reviewReasons,
    pipelineVersion: pipelineVersion,
    policyVersion: policyVersion,
    detectorSha256: detectorSha256,
    classifierSha256: classifierSha256,
    verifierSha256: verifierSha256,
    embeddingUsed: embeddingUsed,
  );
}
```

Add `LabelSource? labelSource` and `BoxAutomationMetadata? automation` to `BoundingBox`, plus `String? contentSha256` to `AnnotatedImage`. Define `requiresLabelReview` as `status == proposal && labelId == null && automation?.suggestedLabelId != null && automation!.reviewReasons.isNotEmpty`. `assignLabel` sets `LabelSource.user`, clears suggestion/reasons while retaining candidates and model evidence, and marks the image `needsReview` at controller level.

- [ ] **Step 4: Run annotation tests**

Run: `flutter test test/annotation/automation_metadata_test.dart test/annotation/annotation_rules_test.dart test/annotation/label_shortcut_migration_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/annotation/models.dart lib/annotation/annotation_rules.dart test/annotation/automation_metadata_test.dart test/annotation/annotation_rules_test.dart
git commit -m "feat: model automatic label evidence"
```

### Task 2: Project schema version 3 migration

**Files:**
- Modify: `lib/project/project_store.dart`
- Modify: `test/project/project_store_test.dart`
- Create: `test/annotation/auto_label_project_migration_test.dart`

**Interfaces:**
- Consumes: schema-version-2 JSON and new model types from Task 1.
- Produces: `ProjectStore.currentSchemaVersion == 3` and `_migrateToCurrent(Map<String, Object?>)`.

- [ ] **Step 1: Write failing migration tests**

```dart
test('schema 2 project loads with null automation fields and saves as 3', () async {
  final path = await writeSchema2Fixture();
  final loaded = await ProjectStore.load(path);
  expect(loaded.schemaVersion, 3);
  expect(loaded.images.single.boxes.single.automation, isNull);
  expect(loaded.images.single.boxes.single.labelSource, LabelSource.user);
});

test('unknown future schema still fails closed', () async {
  final path = await writeFixture(schemaVersion: 4);
  await expectLater(ProjectStore.load(path), throwsA(isA<UnsupportedProjectVersionException>()));
});
```

- [ ] **Step 2: Run migration tests and verify failure**

Run: `flutter test test/project/project_store_test.dart test/annotation/auto_label_project_migration_test.dart`

Expected: FAIL because version 2 is rejected after the version bump or migration is absent.

- [ ] **Step 3: Implement one-way migration**

```dart
static Map<String, Object?> _migrateToCurrent(Map<String, Object?> json) {
  final version = json['schemaVersion'] as int? ?? 0;
  if (version == 3) return json;
  if (version != 2) throw UnsupportedProjectVersionException(version);
  final migrated = Map<String, Object?>.from(json)..['schemaVersion'] = 3;
  final images = (migrated['images'] as List<Object?>? ?? const []).cast<Map<String, Object?>>();
  migrated['images'] = [for (final image in images) _migrateImageV2(image)];
  return migrated;
}
```

`_migrateImageV2` adds `contentSha256: null`; each labeled v2 box receives `labelSource: user`, while proposal/deleted boxes receive null source and all boxes receive `automation: null`.

- [ ] **Step 4: Run project persistence tests**

Run: `flutter test test/project/project_store_test.dart test/annotation/auto_label_project_migration_test.dart test/annotation/legacy_project_settings_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/project/project_store.dart test/project/project_store_test.dart test/annotation/auto_label_project_migration_test.dart
git commit -m "feat: migrate projects for automatic labels"
```

### Task 3: Dart worker protocol v2 and result parsing

**Files:**
- Modify: `lib/detector/worker_protocol.dart`
- Modify: `lib/detector/bread_worker_client.dart`
- Modify: `lib/detector/detector.dart`
- Modify: `lib/detector/auto_box_service.dart`
- Modify: `test/detector/worker_protocol_test.dart`
- Modify: `test/detector/bread_worker_client_test.dart`
- Modify: `test/detector/auto_box_service_test.dart`
- Modify: `test/support/fake_auto_box_runtime.dart`

**Interfaces:**
- Produces: `workerProtocolVersion == 2`.
- Produces: `AutoBoxRuntime.classifyBoxes(AnnotatedImage image, List<BoundingBox> boxes)`.
- Produces: `AutoBoxRuntime.cancelActiveRequest()` and `AutoBoxCancelledException`.
- Produces: `DetectionResult.imageSha256`, pipeline/policy versions, model hashes, and `List<WorkerStageError> stageErrors`.
- Consumes: worker response contract from `docs/worker-protocol-v2.md`.

- [ ] **Step 1: Write failing client and parser tests**

```dart
test('client starts worker with pipeline manifest', () async {
  final client = BreadWorkerClient(pythonExecutable: 'python.exe', scriptPath: 'worker.py', pipelineManifestPath: 'models/manifest.json', startWorker: starter);
  await client.start();
  expect(starter.arguments, ['worker.py', '--pipeline-manifest', 'models/manifest.json']);
});

test('review response maps to proposal with suggestion only', () async {
  final result = await serviceFromResponse(reviewWorkerResponse).detect(testImage);
  final box = result.boxes.single;
  expect(box.status, BoxStatus.proposal);
  expect(box.labelId, isNull);
  expect(box.automation?.suggestedLabelId, 3);
  expect(box.requiresLabelReview, isTrue);
});

test('accepted response maps to auto labeled box', () async {
  final box = (await serviceFromResponse(acceptedWorkerResponse).detect(testImage)).boxes.single;
  expect(box.status, BoxStatus.labeled);
  expect(box.labelId, 3);
  expect(box.labelSource, LabelSource.auto);
});

test('cancel kills the active worker and returns runtime to idle', () async {
  final pending = service.detect(testImage);
  await untilState(service, AutoBoxState.running);
  await service.cancelActiveRequest();
  await expectLater(pending, throwsA(isA<AutoBoxCancelledException>()));
  expect(service.state, AutoBoxState.idle);
});
```

- [ ] **Step 2: Run detector tests and verify failure**

Run: `flutter test test/detector/worker_protocol_test.dart test/detector/bread_worker_client_test.dart test/detector/auto_box_service_test.dart`

Expected: FAIL on protocol version, constructor, classification API, and label parsing.

- [ ] **Step 3: Implement v2 request methods and strict nested parsing**

```dart
abstract interface class AutoBoxRuntime implements Detector, Listenable {
  AutoBoxState get state;
  Object? get lastError;
  List<String> get recentStderr;
  Future<DetectionResult> classifyBoxes(AnnotatedImage image, List<BoundingBox> boxes);
  Future<void> cancelActiveRequest();
  Future<void> warmUp();
  Future<void> shutdown();
}

class DetectionResult {
  const DetectionResult({required this.detectorName, required this.boxes, this.imageSha256, this.pipelineVersion, this.policyVersion, this.detectorSha256, this.classifierSha256, this.verifierSha256, this.stageErrors = const [], this.errorMessage});
  final String detectorName;
  final List<BoundingBox> boxes;
  final String? imageSha256;
  final String? pipelineVersion;
  final String? policyVersion;
  final String? detectorSha256;
  final String? classifierSha256;
  final String? verifierSha256;
  final List<WorkerStageError> stageErrors;
  final String? errorMessage;
}

class WorkerStageError {
  const WorkerStageError({required this.stage, required this.code, required this.message});
  final String stage;
  final String code;
  final String message;
}
```

`BreadWorkerClient.detect` sends type `detect`; `classify` sends type `classify` with at most 100 `{id,x,y,width,height}` records. `AutoBoxService._parseResult` validates candidate IDs 1–20, finite scores 0–1, accepted-state non-null `labelId`, review-state null `labelId` plus non-null suggestion and reasons, and unavailable-state with neither label field.

`cancelActiveRequest` increments the service generation, kills the current process, clears the active client, sets state to idle, and completes the pending operation with `AutoBoxCancelledException`. It does not start a replacement worker until the next `warmUp` or inference request.

Replace `modelPath` with `pipelineManifestPath` in `BreadWorkerClient`. `defaultAutoBoxService` resolves `BBOX_BREAD_PIPELINE_MANIFEST`, then app-local `models/bread_pipeline_manifest.json`, then the workspace path. Update existing startup tests to assert this order and remove `BBOX_BREAD_DETECTOR_MODEL` from the Dart launcher contract; model filenames are resolved by the Python manifest loader.

- [ ] **Step 4: Run detector tests**

Run: `flutter test test/detector/worker_protocol_test.dart test/detector/bread_worker_client_test.dart test/detector/auto_box_service_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/detector/worker_protocol.dart lib/detector/bread_worker_client.dart lib/detector/detector.dart lib/detector/auto_box_service.dart test/detector/worker_protocol_test.dart test/detector/bread_worker_client_test.dart test/detector/auto_box_service_test.dart test/support/fake_auto_box_runtime.dart
git commit -m "feat: consume bread worker protocol v2"
```

### Task 4: Atomic detection, rerun confirmation, and suggestion acceptance

**Files:**
- Modify: `lib/ui/app_controller.dart`
- Create: `lib/ui/auto_box_replace_dialog.dart`
- Modify: `lib/ui/workbench/workbench_screen.dart`
- Modify: `lib/ui/workbench/center_toolbar.dart`
- Modify: `lib/ui/workbench/workbench_feedback.dart`
- Modify: `lib/ui/workbench_copy.dart`
- Modify: `test/ui/app_controller_auto_box_test.dart`
- Create: `test/ui/workbench/auto_box_replace_dialog_test.dart`
- Modify: `test/ui/workbench/workbench_shell_test.dart`

**Interfaces:**
- Produces: `detectSelectedImage({bool replaceExisting = false})`.
- Produces: `acceptSelectedSuggestedLabel()`.
- Produces: `cancelAutoBoxes()` that restores the pre-request project and selection.
- Produces: `confirmAndRunAutoBoxes(context, controller) -> Future<void>` shared by toolbar and `Ctrl+B`.

- [ ] **Step 1: Write failing controller and dialog tests**

```dart
test('existing boxes are not replaced without explicit flag', () async {
  controller.debugSetProjectForTest(projectWithOneBox());
  await controller.detectSelectedImage();
  expect(runtime.detectCount, 0);
  expect(controller.selectedImage!.boxes.single.id, 'existing');
});

test('confirmed replacement is one undo operation', () async {
  await controller.detectSelectedImage(replaceExisting: true);
  expect(controller.selectedImage!.boxes.single.id, startsWith('det-'));
  controller.undo();
  expect(controller.selectedImage!.boxes.single.id, 'existing');
});

testWidgets('rerun dialog cancel preserves boxes', (tester) async {
  await pumpWorkbench(tester, project: projectWithOneBox());
  await tester.tap(find.byKey(const ValueKey('auto-boxes-current-image')));
  await tester.tap(find.text(WorkbenchCopy.cancel));
  expect(runtime.detectCount, 0);
});

testWidgets('automation cancel keeps existing boxes and clears busy state', (tester) async {
  await startPendingReplacement(tester, projectWithOneBox());
  await tester.tap(find.byKey(const ValueKey('cancel-auto-boxes')));
  expect(controller.selectedImage!.boxes.single.id, 'existing');
  expect(controller.isAutomationRunning, isFalse);
});
```

- [ ] **Step 2: Run focused tests and verify failure**

Run: `flutter test test/ui/app_controller_auto_box_test.dart test/ui/workbench/auto_box_replace_dialog_test.dart`

Expected: FAIL because replacement is unconditional and the shared dialog does not exist.

- [ ] **Step 3: Implement atomic application and acceptance**

```dart
Future<void> detectSelectedImage({bool replaceExisting = false, DetectionOptions options = const DetectionOptions()}) async {
  final project = _project;
  final image = selectedImage;
  if (project == null || image == null || image.status == ImageStatus.error || isAutomationRunning) return;
  if (image.visibleBoxes.isNotEmpty && !replaceExisting) {
    lastUserMessage = WorkbenchCopy.autoBoxesReplacementConfirmationRequired;
    notifyListeners();
    return;
  }
  final projectEpoch = _projectEpoch;
  final imageId = image.id;
  final previousSelection = _selectedBoxId;
  final token = ++_nextAutoBoxRequestToken;
  _activeAutoBoxRequestToken = token;
  lastUserMessage = WorkbenchCopy.autoBoxesRunning;
  notifyListeners();
  try {
    final result = await _detectWithProgress(_autoBoxRuntime, image, options: options);
    if (!_isCurrentAutoBoxRequest(projectEpoch, imageId)) return;
    if (result.errorMessage != null) {
      lastError = result.errorMessage;
      lastUserMessage = WorkbenchCopy.autoBoxesFailed;
      return;
    }
    _undoStack.add(project);
    _redoStack.clear();
    _project = project;
    final normalizedBoxes = _normalizeDetectionLabelIds(project, result.boxes);
    final updated = image.copyWith(status: ImageStatus.needsReview, boxes: normalizedBoxes, contentSha256: result.imageSha256, errorMessage: null);
    _replaceSelectedImage(updated);
    _project = _project!.copyWith(detectorName: result.detectorName);
    _selectedBoxId = updated.visibleBoxes.isEmpty ? null : updated.visibleBoxes.first.id;
    lastUserMessage = updated.visibleBoxes.isEmpty ? WorkbenchCopy.autoBoxesEmpty : WorkbenchCopy.autoBoxesCreated(updated.visibleBoxes.length);
    _scheduleAutoSave();
  } catch (error) {
    if (_isCurrentAutoBoxRequest(projectEpoch, imageId)) {
      _project = project;
      _selectedBoxId = previousSelection;
      lastError = error;
      lastUserMessage = _autoBoxErrorMessage(error);
    }
  } finally {
    if (_activeAutoBoxRequestToken == token) {
      _activeAutoBoxRequestToken = null;
      notifyListeners();
    }
  }
}

void acceptSelectedSuggestedLabel() {
  final image = selectedImage;
  final boxId = selectedBoxId;
  if (image == null || boxId == null || selectedBox?.requiresLabelReview != true) return;
  _recordUndo();
  _replaceSelectedImage(AnnotationRules.acceptSuggestedLabel(image, boxId: boxId).copyWith(status: ImageStatus.needsReview));
  _scheduleAutoSave();
  notifyListeners();
}

List<BoundingBox> _normalizeDetectionLabelIds(AnnotationProject project, List<BoundingBox> boxes) {
  final validIds = project.labels.map((label) => label.id).toSet();
  return [
    for (final box in boxes)
      if ((box.labelId == null || validIds.contains(box.labelId)) && (box.automation?.suggestedLabelId == null || validIds.contains(box.automation!.suggestedLabelId)))
        box
      else
        box.copyWith(status: BoxStatus.proposal, labelId: null, labelSource: null, automation: box.automation?.copyWith(suggestedLabelId: null, reviewReasons: const ['label_registry_mismatch']))
  ];
}

Future<void> cancelAutoBoxes() async {
  if (!isAutomationRunning) return;
  await _autoBoxRuntime.cancelActiveRequest();
}
```

`confirmAndRunAutoBoxes` bypasses the dialog only when the current image has zero visible boxes. On confirmation it calls `detectSelectedImage(replaceExisting: true)`. Both toolbar click and `Ctrl+B` call this function. While automation runs, `workbench_feedback.dart` shows `cancel-auto-boxes`; the controller catches `AutoBoxCancelledException`, restores the captured project and selection, and reports cancellation without an error banner.

- [ ] **Step 4: Run controller/dialog tests**

Run: `flutter test test/ui/app_controller_auto_box_test.dart test/ui/workbench/auto_box_replace_dialog_test.dart test/ui/workbench/center_toolbar_test.dart test/ui/workbench/workbench_shell_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/ui/app_controller.dart lib/ui/auto_box_replace_dialog.dart lib/ui/workbench/workbench_screen.dart lib/ui/workbench/center_toolbar.dart lib/ui/workbench/workbench_feedback.dart lib/ui/workbench_copy.dart test/ui/app_controller_auto_box_test.dart test/ui/workbench/auto_box_replace_dialog_test.dart test/ui/workbench/center_toolbar_test.dart test/ui/workbench/workbench_shell_test.dart
git commit -m "feat: safely apply automatic bread labels"
```

### Task 5: Edit invalidation, debounced classification, and cache

**Files:**
- Create: `lib/detector/box_label_cache.dart`
- Create: `test/detector/box_label_cache_test.dart`
- Modify: `lib/detector/auto_box_service.dart`
- Modify: `lib/ui/app_controller.dart`
- Modify: `test/ui/app_controller_auto_box_test.dart`

**Interfaces:**
- Produces: `BoxLabelCacheKey(imageSha256, bbox, pipelineVersion)`.
- Produces: `scheduleSelectedBoxClassification()` with a 250 ms debounce.
- Consumes: `AutoBoxRuntime.classifyBoxes` from Task 3.

- [ ] **Step 1: Write failing invalidation and cache tests**

```dart
test('same hash geometry and pipeline hits cache', () {
  final hash = List<String>.filled(64, 'a').join();
  cache.put(key(hash: hash, x: 10, pipeline: 'v1'), metadata());
  expect(cache.get(key(hash: hash, x: 10, pipeline: 'v1')), isNotNull);
  expect(cache.get(key(hash: hash, x: 11, pipeline: 'v1')), isNull);
});

test('editing auto labeled box makes it gray before reclassification', () {
  controller.debugSetProjectForTest(projectWithAutoLabel());
  controller.setSelectedBoxGeometry(x: 20, y: 20, width: 80, height: 60);
  expect(controller.selectedBox!.status, BoxStatus.proposal);
  expect(controller.selectedBox!.labelId, isNull);
});

test('rapid edits produce one classify request', () async {
  controller.moveSelectedBox(1, 0);
  controller.moveSelectedBox(1, 0);
  await Future<void>.delayed(const Duration(milliseconds: 251));
  expect(runtime.classifyCount, 1);
});

test('new manual box is classified after drawing completes', () async {
  controller.addBox(x: 10, y: 12, width: 80, height: 60);
  await Future<void>.delayed(const Duration(milliseconds: 251));
  expect(runtime.classifyCount, 1);
});
```

- [ ] **Step 2: Run focused tests and verify failure**

Run: `flutter test test/detector/box_label_cache_test.dart test/ui/app_controller_auto_box_test.dart`

Expected: FAIL because cache and reclassification scheduling are missing.

- [ ] **Step 3: Implement stable cache key and generation-safe debounce**

```dart
class BoxLabelCacheKey {
  const BoxLabelCacheKey({required this.imageSha256, required this.x, required this.y, required this.width, required this.height, required this.pipelineVersion});
  final String imageSha256;
  final double x, y, width, height;
  final String pipelineVersion;
  @override int get hashCode => Object.hash(imageSha256, x, y, width, height, pipelineVersion);
  @override bool operator ==(Object other) => other is BoxLabelCacheKey && imageSha256 == other.imageSha256 && x == other.x && y == other.y && width == other.width && height == other.height && pipelineVersion == other.pipelineVersion;
}
```

When geometry changes, immediately set `status=proposal`, `labelId=null`, `labelSource=null`, and `automation=null`; mark the image `needsReview`; cancel the previous timer; capture project epoch, image ID, box ID, and geometry; after 250 ms call `classifyBoxes`. Invoke the same scheduler after `addBox` completes. Apply the response only if all captured identifiers and geometry still match. Cache only validated accepted/review metadata and invalidate entries by image hash when the source hash changes.

- [ ] **Step 4: Run cache and controller tests**

Run: `flutter test test/detector/box_label_cache_test.dart test/ui/app_controller_auto_box_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/detector/box_label_cache.dart lib/detector/auto_box_service.dart lib/ui/app_controller.dart test/detector/box_label_cache_test.dart test/ui/app_controller_auto_box_test.dart
git commit -m "feat: reclassify edited bread boxes"
```

### Task 6: White, red, gray overlays and review inspector

**Files:**
- Modify: `lib/ui/workbench/image_canvas.dart`
- Modify: `lib/ui/workbench/inspector_panel.dart`
- Modify: `lib/ui/workbench/workbench_screen.dart`
- Modify: `lib/ui/workbench_copy.dart`
- Modify: `test/ui/workbench/canvas_overlay_test.dart`
- Modify: `test/ui/workbench/inspector_panel_test.dart`
- Modify: `test/ui/workbench/quick_label_bar_test.dart`

**Interfaces:**
- Consumes: `requiresLabelReview`, `displayLabelId`, candidates, and reasons from Task 1.
- Produces: semantic states `자동 라벨`, `검토 필요`, and `미라벨`.

- [ ] **Step 1: Write failing color, badge, and shortcut tests**

```dart
testWidgets('accepted label uses white outline and category-colored name badge', (tester) async {
  await pumpCanvas(tester, box: autoLabeledBox(labelId: 3), labelColor: const Color(0xff123456));
  expect(outlineColor(tester, 'b1'), Colors.white);
  expect(labelBadgeColor(tester, 'b1'), const Color(0xff123456));
});

testWidgets('review suggestion uses red outline and visible reason text', (tester) async {
  await pumpWorkbench(tester, project: projectWithReviewBox());
  expect(outlineColor(tester, 'b1'), WorkbenchPalette.error);
  expect(find.text(WorkbenchCopy.reviewRequired), findsWidgets);
  expect(find.text(WorkbenchCopy.reviewReasonClassifierAmbiguous), findsOneWidget);
});

testWidgets('Enter accepts suggestion while digit key keeps direct label behavior', (tester) async {
  await pumpWorkbench(tester, project: projectWithReviewBox());
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  expect(controller.selectedBox!.labelId, 3);
  await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
  expect(controller.selectedBox!.labelId, 1);
});
```

- [ ] **Step 2: Run widget tests and verify failure**

Run: `flutter test test/ui/workbench/canvas_overlay_test.dart test/ui/workbench/inspector_panel_test.dart test/ui/workbench/quick_label_bar_test.dart`

Expected: FAIL because current labeled outlines use category colors and Enter has no suggestion action.

- [ ] **Step 3: Implement visual and keyboard precedence**

```dart
Color _boxOutlineColor(BoundingBox box) {
  if (box.requiresLabelReview) return WorkbenchPalette.error;
  if (box.status == BoxStatus.labeled && box.labelId != null) return Colors.white;
  return _automaticBoxColor;
}

KeyEventResult _handleWorkbenchKey(KeyEvent event, AnnotationProject project) {
  if (event is! KeyDownEvent || controller.isAutomationRunning || _textInputHasFocus() || _keyboardModifierPressed()) return KeyEventResult.ignored;
  if (event.logicalKey == LogicalKeyboardKey.enter && controller.selectedBox?.requiresLabelReview == true) {
    controller.acceptSelectedSuggestedLabel();
    return KeyEventResult.handled;
  }
  return _handleExistingQuickLabelKey(event, project);
}
```

Draw a 1 px dark halo behind the 2 px white outline. Use category color only for the label-name badge, with `ThemeData.estimateBrightnessForColor` to choose black or white badge text. Add warning icon plus text, candidate score rows, and localized reason strings in the inspector. Selection adds handles and a thicker neutral focus ring without replacing the white/red/gray status color.

- [ ] **Step 4: Run widget and accessibility tests**

Run: `flutter test test/ui/workbench/canvas_overlay_test.dart test/ui/workbench/inspector_panel_test.dart test/ui/workbench/quick_label_bar_test.dart test/ui/workbench/canvas_interaction_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/ui/workbench/image_canvas.dart lib/ui/workbench/inspector_panel.dart lib/ui/workbench/workbench_screen.dart lib/ui/workbench_copy.dart test/ui/workbench/canvas_overlay_test.dart test/ui/workbench/inspector_panel_test.dart test/ui/workbench/quick_label_bar_test.dart
git commit -m "feat: show automatic label review states"
```

### Task 7: COCO summary and export-safe filtering

**Files:**
- Modify: `lib/export/coco_exporter.dart`
- Modify: `lib/ui/coco_export_warning_dialog.dart`
- Modify: `test/export/coco_exporter_test.dart`
- Modify: `test/ui/coco_export_warning_dialog_test.dart`

**Interfaces:**
- Produces: `CocoExportSummary.autoLabeledBoxCount`, `userLabeledBoxCount`, `reviewRequiredBoxCount`, and `unlabeledProposalBoxCount`.
- Preserves: annotations are emitted only for `BoxStatus.labeled` with non-null `labelId` and valid geometry.

- [ ] **Step 1: Write failing export-count tests**

```dart
test('exports white labels and counts excluded red and gray boxes separately', () {
  final summary = CocoExporter.validate(projectWithAutoUserReviewAndGrayBoxes());
  expect(summary.autoLabeledBoxCount, 1);
  expect(summary.userLabeledBoxCount, 1);
  expect(summary.reviewRequiredBoxCount, 1);
  expect(summary.unlabeledProposalBoxCount, 1);
  final coco = CocoExporter.build(projectWithAutoUserReviewAndGrayBoxes());
  expect((coco['annotations'] as List<Object?>), hasLength(2));
});

testWidgets('warning dialog displays all four annotation counts', (tester) async {
  await pumpDialog(tester, summary: fourWaySummary());
  expect(find.text('자동 라벨 박스: 1'), findsOneWidget);
  expect(find.text('사용자 라벨 박스: 1'), findsOneWidget);
  expect(find.text('제외되는 검토 필요 박스: 1'), findsOneWidget);
  expect(find.text('제외되는 미라벨 박스: 1'), findsOneWidget);
});
```

- [ ] **Step 2: Run export tests and verify failure**

Run: `flutter test test/export/coco_exporter_test.dart test/ui/coco_export_warning_dialog_test.dart`

Expected: FAIL because the summary does not distinguish automation states.

- [ ] **Step 3: Implement counts without changing COCO schema**

```dart
for (final box in image.visibleBoxes) {
  if (box.status == BoxStatus.labeled && box.labelId != null) {
    if (box.labelSource == LabelSource.auto) autoLabeled++;
    else userLabeled++;
  } else if (box.requiresLabelReview) {
    reviewRequired++;
  } else {
    unlabeled++;
  }
}
```

Do not add automation metadata to COCO `images`, `annotations`, or `categories`. Keep unconfirmed-image export enabled, display all warning counts, and block only invalid labeled geometry or missing category IDs.

- [ ] **Step 4: Run export tests**

Run: `flutter test test/export/coco_exporter_test.dart test/ui/coco_export_warning_dialog_test.dart test/ui/coco_export_real_writer_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/export/coco_exporter.dart lib/ui/coco_export_warning_dialog.dart test/export/coco_exporter_test.dart test/ui/coco_export_warning_dialog_test.dart
git commit -m "feat: report automatic labels in coco export"
```

### Task 8: Full workflow and regression verification

**Files:**
- Modify: `test/integration/mvp_flow_test.dart`
- Create: `test/integration/auto_label_flow_test.dart`
- Modify: `test/ui/workbench/export_and_completion_test.dart`
- Modify: `test/ui/workbench/export_success_integration_test.dart`

**Interfaces:**
- Exercises: detect -> accepted white label -> red review -> Enter/manual correction -> confirm -> save/reload -> export -> Undo.

- [ ] **Step 1: Write the end-to-end workflow test**

```dart
testWidgets('automatic labels preserve review and export invariants', (tester) async {
  final runtime = FakeAutoBoxRuntime(result: oneAcceptedOneReviewResult());
  final controller = await pumpProjectWithRuntime(tester, runtime);
  await runAutoBoxes(tester);
  expect(find.bySemanticsLabel(RegExp('자동 라벨')), findsOneWidget);
  expect(find.bySemanticsLabel(RegExp('검토 필요')), findsOneWidget);
  expect(controller.canConfirmSelectedImage, isFalse);
  await selectReviewBoxAndPressEnter(tester);
  expect(controller.canConfirmSelectedImage, isTrue);
  controller.confirmSelectedImage();
  await controller.saveProject();
  final restored = await ProjectStore.load(controller.project!.projectFilePath!);
  expect(restored.images.single.labeledBoxCount, 2);
  expect((CocoExporter.build(restored)['annotations'] as List<Object?>), hasLength(2));
});
```

- [ ] **Step 2: Run integration tests against the completed component tasks**

Run: `flutter test test/integration/auto_label_flow_test.dart test/integration/mvp_flow_test.dart`

Expected: PASS; if it fails, return to the owning Task 1–7 and complete that task's specified interface before continuing.

- [ ] **Step 3: Run format, analysis, full tests, and Windows build**

Run: `dart format --output=none --set-exit-if-changed lib test`

Expected: exit 0.

Run: `flutter analyze`

Expected: no issues.

Run: `flutter test`

Expected: all tests pass with zero failures.

Run: `flutter build windows --release`

Expected: exit 0 and release directory contains the manifest-driven detector/classifier assets verified by the packaging script.

- [ ] **Step 4: Commit**

```powershell
git add test/integration/auto_label_flow_test.dart test/integration/mvp_flow_test.dart test/ui/workbench/export_and_completion_test.dart test/ui/workbench/export_success_integration_test.dart
git commit -m "test: verify automatic bread labeling flow"
```
