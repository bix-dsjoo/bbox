# Safe Auto Box Labeling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing `자동박스` action create high-recall bread boxes and assign labels only when a conservative classifier plus retrieval gate agrees.

**Architecture:** Keep the UI as one `자동박스` button. Replace the default import detector sidecar with a bread-specific YOLO pipeline that can return both unlabeled proposal boxes and confidently labeled boxes; the Dart detector maps approved `label` names to existing project label IDs. The Python sidecar stays local-only and CPU-first, with CLIP/SigLIP verification optional but preferred when the runtime and cached model assets are available.

**Tech Stack:** Flutter/Dart, Python sidecar, Ultralytics YOLO CPU, OpenCV/NumPy, optional `open_clip_torch`, Windows bundled Python runtime.

## Global Constraints

- Do not touch or write under `C:\workspace\bakery_vision`.
- `자동박스` is the only primary user-facing action for this flow.
- UI shows only existing states: unlabeled proposal boxes are gray, labeled boxes use label colors.
- Do not add an automatic-label badge or separate automatic state.
- Boxes optimize for recall; labels optimize for precision.
- COCO export continues to include only `BoxStatus.labeled` boxes with a valid `labelId`.
- CPU operation must use app-local runtime paths and should avoid per-image model reload in the final worker design.
- Workspace is not a Git repository, so commit steps are not available.

---

### Task 1: Detector Contract Supports Approved Labels

**Files:**
- Modify: `C:\workspace\bbox\lib\detector\detector.dart`
- Modify: `C:\workspace\bbox\lib\ui\app_controller.dart`
- Test: `C:\workspace\bbox\test\detector\dummy_detector_test.dart`
- Test: `C:\workspace\bbox\test\ui\app_controller_auto_box_test.dart`

**Interfaces:**
- Consumes: sidecar box JSON containing optional `"label": "walnut_donut"` and `"labelConfidence": 0.99`.
- Produces: `BoundingBox(status: BoxStatus.labeled, labelId: matchedLabel.id)` only when the sidecar label matches a project label; otherwise `BoundingBox(status: BoxStatus.proposal, labelId: null)`.

- [ ] **Step 1: Write a failing parser test**

Add a test to `C:\workspace\bbox\test\detector\dummy_detector_test.dart` inside the `FastSamSidecarDetector` group:

```dart
test('parses approved sidecar labels when label names are available', () async {
  final detector = FastSamSidecarDetector(
    pythonExecutable: 'python',
    scriptPath: 'tools/detectors/bread_vision_detector.py',
    runProcess: (_, _) async => const ProcessResultLike(
      exitCode: 0,
      stdout: '''
{
  "detectorName": "bread-yolo-safe-label",
  "boxes": [
    {
      "x": 10,
      "y": 20,
      "width": 30,
      "height": 40,
      "confidence": 0.91,
      "label": "walnut_donut",
      "labelConfidence": 0.995
    },
    {
      "x": 50,
      "y": 60,
      "width": 70,
      "height": 80,
      "confidence": 0.72
    }
  ]
}
''',
      stderr: '',
    ),
  );

  const image = AnnotatedImage(
    id: 5,
    sourcePath: 'photo.jpg',
    displayName: 'photo.jpg',
    width: 200,
    height: 160,
    status: ImageStatus.detecting,
  );

  final result = await detector.detect(
    image,
    imagePath: 'photo.jpg',
    labelByName: const {'walnut_donut': 9},
  );

  expect(result.detectorName, 'bread-yolo-safe-label');
  expect(result.boxes, hasLength(2));
  expect(result.boxes[0].status, BoxStatus.labeled);
  expect(result.boxes[0].labelId, 9);
  expect(result.boxes[1].status, BoxStatus.proposal);
  expect(result.boxes[1].labelId, isNull);
}
```

- [ ] **Step 2: Extend `Detector.detect` signature**

Change the interface in `C:\workspace\bbox\lib\detector\detector.dart`:

```dart
Future<DetectionResult> detect(
  AnnotatedImage image, {
  String? imagePath,
  DetectionOptions options = const DetectionOptions(),
  Map<String, int> labelByName = const {},
});
```

Update every detector implementation and test fake to accept the new optional `labelByName`.

- [ ] **Step 3: Parse optional labels**

In `FastSamSidecarDetector.detect`, after reading each JSON `box`, map label names:

```dart
final labelName = box['label'] as String?;
final labelId = labelName == null ? null : labelByName[labelName];
final status = labelId == null ? BoxStatus.proposal : BoxStatus.labeled;
```

Use `status: status`, `labelId: labelId`, and keep `confidence` as detector confidence.

- [ ] **Step 4: Pass project labels from controller**

In `AppController.detectSelectedImage`, build the mapping before calling the detector:

```dart
final labelByName = {
  for (final label in project.labels) label.name: label.id,
};
```

Pass it into `activeDetector.detect(..., labelByName: labelByName)`.

- [ ] **Step 5: Add controller behavior test**

Add a fake detector test in `C:\workspace\bbox\test\ui\app_controller_auto_box_test.dart` that returns one labeled box and one proposal box. Assert the selected image has one `BoxStatus.labeled` with `labelId` and one `BoxStatus.proposal` without `labelId`.

- [ ] **Step 6: Run focused tests**

Run:

```powershell
flutter test test/detector/dummy_detector_test.dart test/ui/app_controller_auto_box_test.dart
```

Expected: all tests pass.

---

### Task 2: Bread Vision Sidecar

**Files:**
- Create: `C:\workspace\bbox\tools\detectors\bread_vision_detector.py`
- Test: `C:\workspace\bbox\test\detector\dummy_detector_test.dart`

**Interfaces:**
- Consumes: `--image`, `--detector-model`, `--classifier-model`, optional `--prototype-dir`, optional CLIP model settings.
- Produces JSON:

```json
{
  "detectorName": "bread-yolo-safe-label",
  "boxes": [
    {
      "x": 10.0,
      "y": 20.0,
      "width": 30.0,
      "height": 40.0,
      "confidence": 0.91,
      "label": "walnut_donut",
      "labelConfidence": 0.995
    },
    {
      "x": 50.0,
      "y": 60.0,
      "width": 70.0,
      "height": 80.0,
      "confidence": 0.72
    }
  ]
}
```

- [ ] **Step 1: Create sidecar skeleton**

Create `bread_vision_detector.py` with argparse options:

```python
parser.add_argument("--image", required=True)
parser.add_argument("--detector-model", required=True)
parser.add_argument("--classifier-model", required=True)
parser.add_argument("--imgsz", type=int, default=640)
parser.add_argument("--det-conf", type=float, default=0.40)
parser.add_argument("--iou", type=float, default=0.55)
parser.add_argument("--class-conf", type=float, default=0.97)
parser.add_argument("--class-margin", type=float, default=0.40)
parser.add_argument("--max-results", type=int, default=50)
parser.add_argument("--min-box-size", type=int, default=45)
parser.add_argument("--max-area-ratio", type=float, default=0.38)
```

- [ ] **Step 2: Implement YOLO detection**

Use `ultralytics.YOLO(detector_model).predict(..., device="cpu", conf=args.det_conf, iou=args.iou)`, clamp boxes to image bounds, filter by minimum size and maximum area ratio, and sort by `(y, x)`.

- [ ] **Step 3: Implement crop classification**

For each retained box, crop the original image with small padding, run `YOLO(classifier_model).predict(crops, imgsz=224, batch=16, device="cpu")`, and compute top-1/top-2 confidence margin.

- [ ] **Step 4: Add conservative label approval**

Approve a label only when:

```python
class_conf >= args.class_conf
class_margin >= args.class_margin
```

If CLIP/SigLIP retrieval is available later, additionally require retrieval agreement before emitting `"label"`.

- [ ] **Step 5: Keep uncertain boxes unlabeled**

For every detected box, always emit coordinates and detector confidence. Only include `"label"` and `"labelConfidence"` for approved labels. Never emit guessed labels for rejected boxes.

- [ ] **Step 6: Add Dart sidecar path test**

Update default detector path tests so app-local `tools/detectors/bread_vision_detector.py` can be preferred when present.

---

### Task 3: Default Detector Configuration

**Files:**
- Modify: `C:\workspace\bbox\lib\detector\detector.dart`
- Test: `C:\workspace\bbox\test\detector\dummy_detector_test.dart`

**Interfaces:**
- Consumes: app-local or environment paths:
  - `BBOX_BREAD_PYTHON`
  - `BBOX_BREAD_SCRIPT`
  - `BBOX_BREAD_DETECTOR_MODEL`
  - `BBOX_BREAD_CLASSIFIER_MODEL`
- Produces: default `자동박스` detector named `bread-yolo-safe-label`.

- [ ] **Step 1: Introduce `BreadVisionSidecarDetector`**

Create a new Dart class that follows the existing sidecar pattern and accepts:

```dart
BreadVisionSidecarDetector({
  this.pythonExecutable = 'python',
  this.scriptPath = 'tools/detectors/bread_vision_detector.py',
  this.detectorModelPath = 'models/bread_yolov8n_1class_best.pt',
  this.classifierModelPath = 'models/bread_classifier_yolov8n_cls_best.pt',
  this.imageSize = 640,
  this.detectorConfidenceThreshold = 0.40,
  this.iouThreshold = 0.55,
  this.classConfidenceThreshold = 0.97,
  this.classMarginThreshold = 0.40,
  this.maxProposals = 50,
  this.runProcess = _defaultRunProcess,
});
```

- [ ] **Step 2: Preserve FastSAM class**

Keep `FastSamSidecarDetector` available for fallback/support tests. Do not remove `fastsam_detector.py`.

- [ ] **Step 3: Switch `defaultImportDetector`**

Return `BreadVisionSidecarDetector` when `bread_vision_detector.py`, detector model, and classifier model are present. Fall back to `FastSamSidecarDetector` when any bread runtime asset is missing.

- [ ] **Step 4: Add tests**

Update tests to assert:

```dart
expect(defaultImportDetector(...), isA<BreadVisionSidecarDetector>());
```

when bread assets exist, and:

```dart
expect(defaultImportDetector(...), isA<FastSamSidecarDetector>());
```

when only FastSAM assets exist.

---

### Task 4: Runtime And Packaging

**Files:**
- Modify: `C:\workspace\bbox\tools\packaging\prepare_windows_detector_runtime.ps1`
- Modify: `C:\workspace\bbox\installer\bbox_labeler.iss`
- Modify: `C:\workspace\bbox\docs\release-checklist.md`
- Optional create: `C:\workspace\bbox\models\README.md`

**Interfaces:**
- Consumes: runtime Python, model files prepared outside source control or copied into release payload.
- Produces: installed app with `runtime/python`, `tools/detectors/bread_vision_detector.py`, and model files available next to the executable.

- [ ] **Step 1: Add Python packages**

Add optional `open_clip_torch` and its runtime dependencies to the packaging script only if CLIP gate is enabled for release. Keep YOLO-only safe labeling working without CLIP.

- [ ] **Step 2: Add release asset convention**

Document model placement:

```text
models/bread_yolov8n_1class_best.pt
models/bread_classifier_yolov8n_cls_best.pt
models/clip_prototypes.npz
```

- [ ] **Step 3: Include runtime assets in installer**

Ensure the installer includes `tools/detectors/*.py`, `models/*.pt`, and optional `models/*.npz`, while continuing to delete/exclude datasets, `train`, `outputs`, `qa_samples`, and `research`.

- [ ] **Step 4: Release checklist**

Add a checklist item to run one image through `bread_vision_detector.py` from the release build directory and confirm JSON contains proposal boxes and no labels for uncertain boxes.

---

### Task 5: Verification

**Files:**
- Test and generated outputs only.

**Interfaces:**
- Consumes: Tasks 1-4.
- Produces: evidence the app behavior matches the product policy.

- [ ] **Step 1: Focused Dart tests**

Run:

```powershell
flutter test test/detector/dummy_detector_test.dart test/ui/app_controller_auto_box_test.dart
```

Expected: all tests pass.

- [ ] **Step 2: Full Dart tests**

Run:

```powershell
flutter test
```

Expected: all tests pass or pre-existing unrelated failures are documented.

- [ ] **Step 3: Python smoke test**

Run against `C:\workspace\bbox\qa_samples\images\sample_01.jpg`:

```powershell
& runtime\python\python.exe tools\detectors\bread_vision_detector.py `
  --image C:\workspace\bbox\qa_samples\images\sample_01.jpg `
  --detector-model C:\workspace\bbox\models\bread_yolov8n_1class_best.pt `
  --classifier-model C:\workspace\bbox\models\bread_classifier_yolov8n_cls_best.pt
```

Expected: exit code 0, JSON with boxes, and labels only when approval thresholds pass.

- [ ] **Step 4: Manual UX check**

Open a project, choose a bread image, click `자동박스`, and confirm:

- Gray boxes appear for unlabeled proposals.
- Label-colored boxes appear only for approved labels.
- No automatic-state badge is shown.
- Image remains `needsReview`.
- Confirmation remains blocked while any gray proposal remains.
