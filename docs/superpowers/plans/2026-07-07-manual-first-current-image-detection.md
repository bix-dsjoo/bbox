# Manual-First Current Image Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make image import immediate, move automatic detection to an explicit current-image action, and move label assignment into a center-bottom quick-label workflow.

**Architecture:** Keep the current Flutter desktop three-panel workbench. Add small domain support for persisted label shortcuts, add detector run options, move import to metadata-only image creation, and expose current-image detection and clear operations through `AppController`. UI changes stay in `WorkbenchScreen` and a new focused label-management widget.

**Tech Stack:** Flutter, Dart, `flutter_test`, existing `image` package, existing FastSAM Python sidecar.

## Global Constraints

- Image import must not run automatic detection for every imported image by default.
- `Auto boxes` runs detection only for the selected image.
- `Auto boxes` fully replaces all current visible boxes on the selected image, including labeled boxes.
- `Auto boxes` and `Clear boxes` must not show confirmation modals.
- Undo/Redo must restore destructive current-image actions.
- Proposal count is off by default and uses the detector default when off.
- Proposal count, when enabled, is a maximum proposal count in the valid range `1..100`.
- Detection failure must not destroy the current boxes.
- COCO export behavior remains unchanged: only valid labeled boxes are exported.
- Coordinates remain original image pixel coordinates.
- The right inspector must not duplicate full label management.
- The bottom quick-label bar shows shortcut, color, and label name.
- Label creation and editing includes shortcut, color, and name.
- Keep UI dense and work-focused for Windows desktop.

---

## File Structure

- Modify `lib/annotation/models.dart`: add nullable `shortcut` to `LabelClass` with backward-compatible JSON.
- Modify `lib/annotation/default_labels.dart`: assign default shortcuts `1..p` to default labels.
- Modify `lib/annotation/annotation_rules.dart`: add label update and shortcut uniqueness rules.
- Modify `test/annotation/annotation_rules_test.dart`: cover shortcut creation, update, duplicate handling.
- Modify `test/project/project_store_test.dart`: cover shortcut save/load compatibility if an existing serialization test is present.
- Modify `lib/detector/detector.dart`: add `DetectionOptions`, pass optional `maxProposals`, and trim unsupported detector results.
- Modify `lib/ui/app_controller.dart`: stop detecting during image import, add `detectSelectedImage`, `clearSelectedImageBoxes`, and proposal count UI state.
- Modify `test/ui/app_controller_test.dart`: cover metadata-only import, current-image auto replacement, detector failure preservation, clear boxes, undo, proposal count.
- Modify `test/integration/mvp_flow_test.dart`: update assumptions that import creates proposal boxes.
- Modify `lib/ui/workbench_copy.dart`: add copy keys for auto boxes, clear boxes, proposal count, label management.
- Modify `lib/ui/workbench_screen.dart`: add inspector controls, move quick-label bar to the center viewer area, use persisted shortcuts.
- Create `lib/ui/label_management_popover.dart`: compact label manager for shortcut, color, and name.
- Create `test/ui/label_management_popover_test.dart`: widget tests for create/edit/conflict display.
- Modify `test/ui/workbench_widget_test.dart`: cover new inspector controls and bottom quick-label bar location.
- Modify `test/ui/workbench_label_selector_test.dart`: delete or narrow tests if the old inspector selector is removed from the workbench but keep the selector if still used elsewhere.

---

### Task 1: Persisted Label Shortcuts

**Files:**
- Modify: `lib/annotation/models.dart`
- Modify: `lib/annotation/default_labels.dart`
- Modify: `lib/annotation/annotation_rules.dart`
- Test: `test/annotation/annotation_rules_test.dart`
- Test: `test/project/project_store_test.dart`

**Interfaces:**
- Produces: `LabelClass.shortcut: String?`
- Produces: `AnnotationRules.addLabel(project, name, color, shortcut)`
- Produces: `AnnotationRules.updateLabel(project, labelId, name, color, shortcut)`
- Produces: duplicate shortcut policy where the new label receives the shortcut and the previous holder is cleared.

- [ ] **Step 1: Write failing shortcut model and rule tests**

Add these tests to `test/annotation/annotation_rules_test.dart`:

```dart
test('adds labels with normalized shortcuts', () {
  final project = AnnotationProject.empty(name: 'demo');

  final updated = AnnotationRules.addLabel(
    project,
    name: 'Bread',
    color: 0xff123456,
    shortcut: 'Q',
  );

  expect(updated.labels.single.name, 'Bread');
  expect(updated.labels.single.shortcut, 'q');
});

test('moving a shortcut clears it from the previous label', () {
  final project = AnnotationProject.empty(name: 'demo').copyWith(
    labels: const [
      LabelClass(id: 1, name: 'Bread', color: 0xff111111, shortcut: '1'),
      LabelClass(id: 2, name: 'Cream', color: 0xff222222),
    ],
  );

  final updated = AnnotationRules.updateLabel(
    project,
    labelId: 2,
    name: 'Cream',
    color: 0xff222222,
    shortcut: '1',
  );

  expect(updated.labels.first.shortcut, isNull);
  expect(updated.labels.last.shortcut, '1');
});

test('rejects shortcuts outside the quick-label set', () {
  final project = AnnotationProject.empty(name: 'demo');

  expect(
    () => AnnotationRules.addLabel(
      project,
      name: 'Bread',
      color: 0xff123456,
      shortcut: 'a',
    ),
    throwsA(isA<AnnotationValidationException>()),
  );
});
```

If `test/project/project_store_test.dart` already has a round-trip test, extend it with:

```dart
expect(loaded.labels.first.shortcut, '1');
```

Use a fixture label like:

```dart
const LabelClass(
  id: 1,
  name: 'Bread',
  color: 0xff123456,
  shortcut: '1',
)
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```powershell
flutter test test/annotation/annotation_rules_test.dart test/project/project_store_test.dart
```

Expected: fail because `LabelClass.shortcut`, `AnnotationRules.updateLabel`, and `shortcut` parameters do not exist.

- [ ] **Step 3: Implement `LabelClass.shortcut`**

In `lib/annotation/models.dart`, replace `LabelClass` with this shape while preserving the existing fields:

```dart
class LabelClass {
  const LabelClass({
    required this.id,
    required this.name,
    required this.color,
    this.shortcut,
    this.supercategory = 'object',
  });

  final int id;
  final String name;
  final int color;
  final String? shortcut;
  final String supercategory;

  LabelClass copyWith({
    int? id,
    String? name,
    int? color,
    Object? shortcut = _unchanged,
    String? supercategory,
  }) {
    return LabelClass(
      id: id ?? this.id,
      name: name ?? this.name,
      color: color ?? this.color,
      shortcut: identical(shortcut, _unchanged)
          ? this.shortcut
          : shortcut as String?,
      supercategory: supercategory ?? this.supercategory,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'color': color,
      'shortcut': shortcut,
      'supercategory': supercategory,
    };
  }

  factory LabelClass.fromJson(Map<String, Object?> json) {
    return LabelClass(
      id: json['id'] as int,
      name: json['name'] as String,
      color: json['color'] as int,
      shortcut: json['shortcut'] as String?,
      supercategory: json['supercategory'] as String? ?? 'object',
    );
  }
}
```

- [ ] **Step 4: Implement default shortcuts**

In `lib/annotation/default_labels.dart`, add:

```dart
const defaultLabelShortcuts = <String>[
  '1',
  '2',
  '3',
  '4',
  '5',
  '6',
  '7',
  '8',
  '9',
  '0',
  'q',
  'w',
  'e',
  'r',
  't',
  'y',
  'u',
  'i',
  'o',
  'p',
];
```

Then set the shortcut in `createDefaultLabels()`:

```dart
shortcut: index < defaultLabelShortcuts.length
    ? defaultLabelShortcuts[index]
    : null,
```

- [ ] **Step 5: Implement label shortcut rules**

In `lib/annotation/annotation_rules.dart`, add this constant near the top:

```dart
const quickLabelShortcutSet = <String>{
  '1',
  '2',
  '3',
  '4',
  '5',
  '6',
  '7',
  '8',
  '9',
  '0',
  'q',
  'w',
  'e',
  'r',
  't',
  'y',
  'u',
  'i',
  'o',
  'p',
};
```

Change `addLabel` to accept `String? shortcut`:

```dart
static AnnotationProject addLabel(
  AnnotationProject project, {
  required String name,
  required int color,
  String? shortcut,
}) {
  final trimmed = _normalizeDisplayName(name);
  final normalizedShortcut = _normalizeShortcut(shortcut);
  _ensureUniqueLabelName(project.labels, trimmed);
  final nextProject = _moveShortcut(project, normalizedShortcut);
  return nextProject.withLabel(
    LabelClass(
      id: nextProject.nextLabelId,
      name: trimmed,
      color: color,
      shortcut: normalizedShortcut,
    ),
  );
}
```

Add `updateLabel`:

```dart
static AnnotationProject updateLabel(
  AnnotationProject project, {
  required int labelId,
  required String name,
  required int color,
  String? shortcut,
}) {
  final trimmed = _normalizeDisplayName(name);
  final normalizedShortcut = _normalizeShortcut(shortcut);
  _ensureUniqueLabelName(
    project.labels.where((label) => label.id != labelId),
    trimmed,
  );
  final movedProject = _moveShortcut(
    project,
    normalizedShortcut,
    exceptLabelId: labelId,
  );
  return movedProject.copyWith(
    labels: [
      for (final label in movedProject.labels)
        if (label.id == labelId)
          label.copyWith(
            name: trimmed,
            color: color,
            shortcut: normalizedShortcut,
          )
        else
          label,
    ],
  );
}
```

Add helpers:

```dart
static String? _normalizeShortcut(String? shortcut) {
  final normalized = shortcut?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  if (!quickLabelShortcutSet.contains(normalized)) {
    throw AnnotationValidationException('Unsupported label shortcut.');
  }
  return normalized;
}

static AnnotationProject _moveShortcut(
  AnnotationProject project,
  String? shortcut, {
  int? exceptLabelId,
}) {
  if (shortcut == null) {
    return project;
  }
  return project.copyWith(
    labels: [
      for (final label in project.labels)
        if (label.id != exceptLabelId && label.shortcut == shortcut)
          label.copyWith(shortcut: null)
        else
          label,
    ],
  );
}
```

- [ ] **Step 6: Run tests**

Run:

```powershell
flutter test test/annotation/annotation_rules_test.dart test/project/project_store_test.dart
```

Expected: PASS.

- [ ] **Step 7: Commit if git is available**

Run:

```powershell
git status --short
git add lib/annotation/models.dart lib/annotation/default_labels.dart lib/annotation/annotation_rules.dart test/annotation/annotation_rules_test.dart test/project/project_store_test.dart
git commit -m "feat: persist label shortcuts"
```

If `git status` says this is not a git repository, skip the commit and note it in the final handoff.

---

### Task 2: Detector Options And Manual-First Controller Flow

**Files:**
- Modify: `lib/detector/detector.dart`
- Modify: `lib/ui/app_controller.dart`
- Test: `test/detector/dummy_detector_test.dart`
- Test: `test/ui/app_controller_test.dart`
- Test: `test/integration/mvp_flow_test.dart`

**Interfaces:**
- Consumes: `BoundingBox`, `AnnotatedImage`, `ImageStatus`, `BoxStatus`
- Produces: `DetectionOptions({int? maxProposals})`
- Produces: `Detector.detect(AnnotatedImage image, {String? imagePath, DetectionOptions options})`
- Produces: `AppController.detectSelectedImage({Detector? detector, DetectionOptions options = const DetectionOptions()})`
- Produces: `AppController.clearSelectedImageBoxes()`
- Produces: `AppController.proposalCountEnabled`, `proposalCount`, `setProposalCountEnabled`, `setProposalCount`

- [ ] **Step 1: Write failing controller tests**

In `test/ui/app_controller_test.dart`, replace the import detector test with:

```dart
test('adds images without running automatic detection during import', () async {
  final tempDir = await Directory.systemTemp.createTemp(
    'bbox_controller_import_no_detect',
  );
  addTearDown(() => tempDir.delete(recursive: true));
  final imagePath = '${tempDir.path}${Platform.pathSeparator}bread.png';
  final fixture = img.Image(width: 80, height: 60);
  img.fill(fixture, color: img.ColorRgb8(8, 10, 12));
  await File(imagePath).writeAsBytes(img.encodePng(fixture));

  final detectedPaths = <String>[];
  final controller = AppController(
    defaultDetectorFactory: () => _RecordingDetector(
      onDetect: (image, {imagePath, options = const DetectionOptions()}) async {
        detectedPaths.add(imagePath!);
        return DetectionResult(detectorName: 'fastsam-cpu', boxes: const []);
      },
    ),
  );
  controller.createProject('demo');

  await controller.addImagesFromFolder(tempDir.path);

  expect(detectedPaths, isEmpty);
  expect(controller.project!.images.single.visibleBoxes, isEmpty);
  expect(controller.project!.images.single.status, ImageStatus.needsReview);
});
```

Add these tests to the same file:

```dart
test('detectSelectedImage replaces all existing boxes with proposals', () async {
  final optionsSeen = <DetectionOptions>[];
  final controller = AppController()..loadProject(_project());
  controller.selectBox('box-1');

  await controller.detectSelectedImage(
    detector: _RecordingDetector(
      onDetect: (image, {imagePath, options = const DetectionOptions()}) async {
        optionsSeen.add(options);
        return DetectionResult(
          detectorName: 'test-detector',
          boxes: [
            BoundingBox(
              id: 'det-${image.id}-1',
              x: 3,
              y: 4,
              width: 10,
              height: 12,
              status: BoxStatus.proposal,
            ),
          ],
        );
      },
    ),
    options: const DetectionOptions(maxProposals: 7),
  );

  expect(optionsSeen.single.maxProposals, 7);
  expect(controller.selectedImage!.visibleBoxes, hasLength(1));
  expect(controller.selectedImage!.visibleBoxes.single.id, 'det-1-1');
  expect(controller.selectedImage!.visibleBoxes.single.status, BoxStatus.proposal);
  expect(controller.selectedBoxId, 'det-1-1');
  expect(controller.canUndo, isTrue);

  controller.undo();
  expect(controller.selectedImage!.visibleBoxes.single.id, 'box-1');
});

test('detectSelectedImage preserves boxes when detector fails', () async {
  final controller = AppController()..loadProject(_project());

  await controller.detectSelectedImage(
    detector: _RecordingDetector(
      onDetect: (image, {imagePath, options = const DetectionOptions()}) async {
        return const DetectionResult(
          detectorName: 'test-detector',
          boxes: [],
          errorMessage: 'boom',
        );
      },
    ),
  );

  expect(controller.selectedImage!.visibleBoxes.single.id, 'box-1');
  expect(controller.selectedImage!.errorMessage, 'boom');
});

test('clearSelectedImageBoxes removes boxes and supports undo', () {
  final controller = AppController()..loadProject(_project());
  controller.selectBox('box-1');

  controller.clearSelectedImageBoxes();

  expect(controller.selectedImage!.visibleBoxes, isEmpty);
  expect(controller.selectedBoxId, isNull);
  expect(controller.canConfirmSelectedImage, isTrue);

  controller.undo();
  expect(controller.selectedImage!.visibleBoxes.single.id, 'box-1');
});

test('proposal count setting is optional and clamped', () {
  final controller = AppController();

  expect(controller.proposalCountEnabled, isFalse);
  expect(controller.proposalCount, 10);

  controller.setProposalCountEnabled(true);
  controller.setProposalCount(200);

  expect(controller.proposalCountEnabled, isTrue);
  expect(controller.proposalCount, 100);
});
```

Update `_RecordingDetector` in the test file to:

```dart
final Future<DetectionResult> Function(
  AnnotatedImage image, {
  String? imagePath,
  DetectionOptions options,
})
onDetect;

@override
Future<DetectionResult> detect(
  AnnotatedImage image, {
  String? imagePath,
  DetectionOptions options = const DetectionOptions(),
}) {
  return onDetect(image, imagePath: imagePath, options: options);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```powershell
flutter test test/ui/app_controller_test.dart
```

Expected: fail because `DetectionOptions`, `detectSelectedImage`, `clearSelectedImageBoxes`, and proposal count controller fields do not exist.

- [ ] **Step 3: Add detector options**

In `lib/detector/detector.dart`, add after `DetectionResult`:

```dart
class DetectionOptions {
  const DetectionOptions({this.maxProposals});

  final int? maxProposals;
}
```

Change the abstract method:

```dart
Future<DetectionResult> detect(
  AnnotatedImage image, {
  String? imagePath,
  DetectionOptions options = const DetectionOptions(),
});
```

In `FastSamSidecarDetector.detect`, add the same parameter and change the `--max-results` argument:

```dart
'--max-results',
(options.maxProposals ?? maxProposals).toString(),
```

In `DummyDetector.detect` and `DarkBackgroundDetector.detect`, add the options parameter. For result lists, trim with:

```dart
final limit = options.maxProposals;
final limitedBoxes = limit == null ? boxes : boxes.take(limit).toList(growable: false);
return DetectionResult(detectorName: name, boxes: limitedBoxes);
```

For `DummyDetector`, apply the trim to its single-box list before returning.

- [ ] **Step 4: Make import metadata-only**

In `lib/ui/app_controller.dart`, keep public method parameters for compatibility but stop using the detector in `_addScannedImages`.

Inside `_addScannedImages`, remove:

```dart
final activeDetector = detector ?? _defaultDetectorFactory();
```

Replace imported image creation and detection with:

```dart
final importedImage = AnnotatedImage(
  id: nextId++,
  sourcePath: sourcePath,
  displayName: scanned.displayName,
  importedFrom: scanned.importedFrom ?? importedFrom ?? p.dirname(sourcePath),
  width: scanned.width,
  height: scanned.height,
  status: scanned.hasError ? ImageStatus.error : ImageStatus.needsReview,
  errorMessage: scanned.errorMessage,
);
nextImages.add(importedImage);
```

At the end, remove the detector name update:

```dart
_project = _project!.copyWith(
  status: ProjectStatus.ready,
  images: nextImages,
);
```

- [ ] **Step 5: Add controller current-image detection and clear operations**

In `AppController`, add fields:

```dart
bool _proposalCountEnabled = false;
int _proposalCount = 10;

bool get proposalCountEnabled => _proposalCountEnabled;
int get proposalCount => _proposalCount;
```

Add setters:

```dart
void setProposalCountEnabled(bool enabled) {
  _proposalCountEnabled = enabled;
  notifyListeners();
}

void setProposalCount(int value) {
  _proposalCount = value.clamp(1, 100).toInt();
  notifyListeners();
}
```

Add methods:

```dart
Future<void> detectSelectedImage({
  Detector? detector,
  DetectionOptions options = const DetectionOptions(),
}) async {
  final image = selectedImage;
  if (image == null || image.status == ImageStatus.error) {
    return;
  }
  final activeDetector = detector ?? _defaultDetectorFactory();
  final previousStatus = image.status;
  _replaceSelectedImage(image.copyWith(status: ImageStatus.detecting));
  notifyListeners();

  final result = await activeDetector.detect(
    image,
    imagePath: image.sourcePath,
    options: options,
  );
  if (result.errorMessage != null) {
    _replaceSelectedImage(
      image.copyWith(
        status: previousStatus,
        errorMessage: result.errorMessage,
      ),
    );
    lastError = result.errorMessage;
    notifyListeners();
    return;
  }

  _recordUndo();
  final updated = image.copyWith(
    status: ImageStatus.needsReview,
    boxes: result.boxes,
    errorMessage: null,
  );
  _replaceSelectedImage(updated);
  _project = _project!.copyWith(detectorName: result.detectorName);
  _selectedBoxId = updated.visibleBoxes.isEmpty
      ? null
      : updated.visibleBoxes.first.id;
  _scheduleAutoSave();
  notifyListeners();
}

void clearSelectedImageBoxes() {
  final image = selectedImage;
  if (image == null) {
    return;
  }
  _recordUndo();
  _replaceSelectedImage(
    image.copyWith(
      status: ImageStatus.needsReview,
      boxes: const [],
      errorMessage: null,
    ),
  );
  _selectedBoxId = null;
  _scheduleAutoSave();
  notifyListeners();
}
```

- [ ] **Step 6: Run focused tests**

Run:

```powershell
flutter test test/detector/dummy_detector_test.dart test/ui/app_controller_test.dart
```

Expected: PASS after updating any detector test call sites to use the new optional `options` parameter.

- [ ] **Step 7: Update integration expectations**

In `test/integration/mvp_flow_test.dart`, change the import flow so it explicitly calls detection before expecting proposal boxes:

```dart
await controller.addImagesFromFolder(tempDir.path);
expect(controller.selectedImage!.visibleBoxes, isEmpty);

await controller.detectSelectedImage(detector: const DummyDetector());
expect(controller.selectedImage!.visibleBoxes.single.status, BoxStatus.proposal);
```

- [ ] **Step 8: Run integration test**

Run:

```powershell
flutter test test/integration/mvp_flow_test.dart
```

Expected: PASS.

- [ ] **Step 9: Commit if git is available**

Run:

```powershell
git status --short
git add lib/detector/detector.dart lib/ui/app_controller.dart test/detector/dummy_detector_test.dart test/ui/app_controller_test.dart test/integration/mvp_flow_test.dart
git commit -m "feat: run detection per selected image"
```

Skip the commit if this workspace is still not a git repository.

---

### Task 3: Right Inspector Auto Boxes Controls

**Files:**
- Modify: `lib/ui/workbench_copy.dart`
- Modify: `lib/ui/workbench_screen.dart`
- Test: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes: `AppController.detectSelectedImage`
- Consumes: `AppController.clearSelectedImageBoxes`
- Consumes: `proposalCountEnabled`, `proposalCount`, `setProposalCountEnabled`, `setProposalCount`
- Produces: inspector buttons with keys `auto-boxes-current-image`, `clear-current-image-boxes`, `proposal-count-toggle`, `proposal-count-input`

- [ ] **Step 1: Write failing widget tests**

Add to `test/ui/workbench_widget_test.dart`:

```dart
testWidgets('inspector shows current-image auto and clear box controls', (tester) async {
  final controller = AppController()..loadProject(_projectWithSelectedImage());

  await tester.pumpWidget(MaterialApp(home: WorkbenchScreen(controller: controller)));

  expect(find.byKey(const ValueKey('auto-boxes-current-image')), findsOneWidget);
  expect(find.byKey(const ValueKey('clear-current-image-boxes')), findsOneWidget);
  expect(find.byKey(const ValueKey('proposal-count-toggle')), findsOneWidget);
  expect(find.byKey(const ValueKey('proposal-count-input')), findsNothing);
});

testWidgets('proposal count input appears only when enabled', (tester) async {
  final controller = AppController()..loadProject(_projectWithSelectedImage());

  await tester.pumpWidget(MaterialApp(home: WorkbenchScreen(controller: controller)));
  await tester.tap(find.byKey(const ValueKey('proposal-count-toggle')));
  await tester.pump();

  expect(find.byKey(const ValueKey('proposal-count-input')), findsOneWidget);
});
```

If the test file already has a project helper, reuse it. Otherwise add:

```dart
AnnotationProject _projectWithSelectedImage() {
  return AnnotationProject.empty(name: 'demo').copyWith(
    labels: createDefaultLabels(),
    images: const [
      AnnotatedImage(
        id: 1,
        sourcePath: 'missing-but-ok-for-widget.jpg',
        displayName: 'sample.jpg',
        width: 100,
        height: 80,
        status: ImageStatus.needsReview,
      ),
    ],
  );
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```powershell
flutter test test/ui/workbench_widget_test.dart --plain-name "inspector shows current-image auto and clear box controls"
```

Expected: fail because the keys are missing.

- [ ] **Step 3: Add copy keys**

In `lib/ui/workbench_copy.dart`, add constants:

```dart
static const autoBoxes = '자동 박스';
static const autoBoxesTooltip = '현재 이미지 박스를 새 후보로 교체';
static const clearBoxes = '박스 모두 지우기';
static const clearBoxesTooltip = '현재 이미지의 모든 박스를 지웁니다';
static const proposalCount = '후보 개수';
static const proposalCountOption = '후보 개수 지정';
```

- [ ] **Step 4: Add inspector controls**

In `_InspectorPanelState.build`, after the selected image summary and before selected box details, add:

```dart
const _SectionTitle('자동 후보'),
const SizedBox(height: 8),
Row(
  children: [
    Expanded(
      child: FilledButton.icon(
        key: const ValueKey('auto-boxes-current-image'),
        onPressed: image.status == ImageStatus.detecting
            ? null
            : () => _runAutoBoxes(),
        icon: const Icon(Icons.auto_fix_high),
        label: const Text(WorkbenchCopy.autoBoxes),
      ),
    ),
  ],
),
const SizedBox(height: 8),
SwitchListTile(
  key: const ValueKey('proposal-count-toggle'),
  dense: true,
  contentPadding: EdgeInsets.zero,
  title: const Text(WorkbenchCopy.proposalCountOption),
  value: widget.controller.proposalCountEnabled,
  onChanged: widget.controller.setProposalCountEnabled,
),
if (widget.controller.proposalCountEnabled)
  TextFormField(
    key: const ValueKey('proposal-count-input'),
    initialValue: widget.controller.proposalCount.toString(),
    keyboardType: TextInputType.number,
    decoration: const InputDecoration(
      isDense: true,
      labelText: WorkbenchCopy.proposalCount,
      border: OutlineInputBorder(),
    ),
    onChanged: (value) {
      final parsed = int.tryParse(value);
      if (parsed != null) {
        widget.controller.setProposalCount(parsed);
      }
    },
  ),
const SizedBox(height: 8),
Align(
  alignment: Alignment.centerLeft,
  child: OutlinedButton.icon(
    key: const ValueKey('clear-current-image-boxes'),
    onPressed: widget.controller.clearSelectedImageBoxes,
    icon: const Icon(Icons.layers_clear_outlined),
    label: const Text(WorkbenchCopy.clearBoxes),
  ),
),
const Divider(height: 28),
```

Add helper method in `_InspectorPanelState`:

```dart
Future<void> _runAutoBoxes() async {
  final maxProposals = widget.controller.proposalCountEnabled
      ? widget.controller.proposalCount
      : null;
  await widget.controller.detectSelectedImage(
    options: DetectionOptions(maxProposals: maxProposals),
  );
}
```

Add import if needed:

```dart
import '../detector/detector.dart';
```

- [ ] **Step 5: Run widget tests**

Run:

```powershell
flutter test test/ui/workbench_widget_test.dart
```

Expected: existing tests may fail where they expect the old label selector in the right inspector. Leave those failures for Task 4 unless they only need text/key updates.

- [ ] **Step 6: Commit if git is available**

Run:

```powershell
git status --short
git add lib/ui/workbench_copy.dart lib/ui/workbench_screen.dart test/ui/workbench_widget_test.dart
git commit -m "feat: add current image auto box controls"
```

Skip the commit if this workspace is still not a git repository.

---

### Task 4: Center Bottom Quick-Label Bar And Label Management

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Create: `lib/ui/label_management_popover.dart`
- Test: `test/ui/workbench_widget_test.dart`
- Test: `test/ui/label_management_popover_test.dart`

**Interfaces:**
- Consumes: `LabelClass.shortcut`
- Consumes: `AppController.addLabel`, `assignSelectedBoxLabel`
- Produces: quick label bar under the center viewer with key `center-quick-label-bar`
- Produces: label manager with key `label-management-popover`
- Produces: label manager callbacks `onCreateLabel(String name, int color, String? shortcut)` and `onUpdateLabel(int id, String name, int color, String? shortcut)`

- [ ] **Step 1: Write failing quick-label location test**

In `test/ui/workbench_widget_test.dart`, add:

```dart
testWidgets('center viewer shows bottom quick-label bar', (tester) async {
  final controller = AppController()..loadProject(_projectWithSelectedImage());

  await tester.pumpWidget(MaterialApp(home: WorkbenchScreen(controller: controller)));

  expect(find.byKey(const ValueKey('center-quick-label-bar')), findsOneWidget);
  expect(find.byKey(const ValueKey('quick-label-bar')), findsNothing);
  expect(find.text('Walnut Donut'), findsOneWidget);
  expect(find.text('1'), findsWidgets);
});
```

- [ ] **Step 2: Write failing label management tests**

Create `test/ui/label_management_popover_test.dart`:

```dart
import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/ui/label_management_popover.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('creates a label with name color and shortcut', (tester) async {
    String? createdName;
    int? createdColor;
    String? createdShortcut;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LabelManagementPopover(
            labels: const [],
            onCreateLabel: (name, color, shortcut) {
              createdName = name;
              createdColor = color;
              createdShortcut = shortcut;
            },
            onUpdateLabel: (_, __, ___, ____) {},
          ),
        ),
      ),
    );

    await tester.enterText(find.byKey(const ValueKey('label-name-input')), 'Bread');
    await tester.enterText(find.byKey(const ValueKey('label-shortcut-input')), '1');
    await tester.tap(find.byKey(const ValueKey('create-managed-label')));
    await tester.pump();

    expect(createdName, 'Bread');
    expect(createdColor, isNotNull);
    expect(createdShortcut, '1');
  });

  testWidgets('shows existing label shortcut color and name', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LabelManagementPopover(
            labels: const [
              LabelClass(
                id: 1,
                name: 'Bread',
                color: 0xff123456,
                shortcut: '1',
              ),
            ],
            onCreateLabel: (_, __, ___) {},
            onUpdateLabel: (_, __, ___, ____) {},
          ),
        ),
      ),
    );

    expect(find.text('1'), findsOneWidget);
    expect(find.text('Bread'), findsOneWidget);
    expect(find.byKey(const ValueKey('managed-label-color-1')), findsOneWidget);
  });
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run:

```powershell
flutter test test/ui/label_management_popover_test.dart test/ui/workbench_widget_test.dart --plain-name "center viewer shows bottom quick-label bar"
```

Expected: fail because `LabelManagementPopover` and `center-quick-label-bar` do not exist.

- [ ] **Step 4: Implement `LabelManagementPopover`**

Create `lib/ui/label_management_popover.dart`:

```dart
import 'package:flutter/material.dart';

import '../annotation/default_labels.dart';
import '../annotation/models.dart';

class LabelManagementPopover extends StatefulWidget {
  const LabelManagementPopover({
    super.key,
    required this.labels,
    required this.onCreateLabel,
    required this.onUpdateLabel,
  });

  final List<LabelClass> labels;
  final void Function(String name, int color, String? shortcut) onCreateLabel;
  final void Function(int id, String name, int color, String? shortcut)
  onUpdateLabel;

  @override
  State<LabelManagementPopover> createState() => _LabelManagementPopoverState();
}

class _LabelManagementPopoverState extends State<LabelManagementPopover> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _shortcut = TextEditingController();
  int _color = defaultLabelColors.first;

  @override
  void dispose() {
    _name.dispose();
    _shortcut.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('label-management-popover'),
      color: Colors.white,
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 420),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('label-name-input'),
                      controller: _name,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: '라벨 이름',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 82,
                    child: TextField(
                      key: const ValueKey('label-shortcut-input'),
                      controller: _shortcut,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: '단축키',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _ColorMenu(
                    value: _color,
                    onChanged: (value) => setState(() => _color = value),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('create-managed-label'),
                    onPressed: _create,
                    child: const Text('추가'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final label in widget.labels)
                      _ManagedLabelRow(
                        label: label,
                        onUpdate: widget.onUpdateLabel,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _create() {
    widget.onCreateLabel(
      _name.text.trim(),
      _color,
      _shortcut.text.trim().isEmpty ? null : _shortcut.text.trim(),
    );
    _name.clear();
    _shortcut.clear();
  }
}

class _ColorMenu extends StatelessWidget {
  const _ColorMenu({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: '색상',
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final color in defaultLabelColors)
          PopupMenuItem(
            value: color,
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: Color(color),
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Color(value),
          shape: BoxShape.circle,
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
      ),
    );
  }
}

class _ManagedLabelRow extends StatelessWidget {
  const _ManagedLabelRow({required this.label, required this.onUpdate});

  final LabelClass label;
  final void Function(int id, String name, int color, String? shortcut)
  onUpdate;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Container(
        key: ValueKey('managed-label-color-${label.id}'),
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: Color(label.color),
          shape: BoxShape.circle,
        ),
      ),
      title: Text(label.name, overflow: TextOverflow.ellipsis),
      trailing: Text(label.shortcut ?? ''),
      onTap: () => onUpdate(label.id, label.name, label.color, label.shortcut),
    );
  }
}
```

- [ ] **Step 5: Move quick-label bar to center viewer**

In `lib/ui/workbench_screen.dart`, remove `_QuickLabelBar` from `_InspectorPanelState.build`.

In `_ViewerPanelState.build`, wrap the viewer content in a `Column`:

```dart
return Column(
  children: [
    Expanded(
      child: _existingViewerContent,
    ),
    Container(
      key: const ValueKey('center-quick-label-bar'),
      decoration: const BoxDecoration(
        color: _workbenchPanel,
        border: Border(top: BorderSide(color: _workbenchBorder)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: _QuickLabelBar(
        controller: widget.controller,
        project: widget.project,
      ),
    ),
  ],
);
```

Use the existing body of `_ViewerPanelState.build` as `_existingViewerContent`; do not change canvas coordinate math.

- [ ] **Step 6: Make quick labels use persisted shortcuts and add manager button**

In `_QuickLabelBar.build`, replace index-based labels with:

```dart
final quickLabels = [
  for (final label in project.labels)
    if (label.shortcut != null) label,
];
```

Use `label.shortcut!` for the chip shortcut.

Append a small add/manage button:

```dart
IconButton(
  key: const ValueKey('open-label-management'),
  tooltip: '라벨 관리',
  onPressed: () => showPopoverForLabels(context),
  icon: const Icon(Icons.add),
)
```

Implement `showPopoverForLabels` with an anchored `OverlayEntry` so label management opens from the quick-label bar `+` action instead of as a modal dialog:

```dart
OverlayEntry? entry;
entry = OverlayEntry(
  builder: (context) => Stack(
    children: [
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => entry?.remove(),
        ),
      ),
      Positioned(
        left: 16,
        bottom: 64,
        child: LabelManagementPopover(
          labels: project.labels,
          onCreateLabel: (name, color, shortcut) {
            controller.addLabel(name, color, shortcut: shortcut);
            entry?.remove();
          },
          onUpdateLabel: (id, name, color, shortcut) {
            controller.updateLabel(
              labelId: id,
              name: name,
              color: color,
              shortcut: shortcut,
            );
            entry?.remove();
          },
        ),
      ),
    ],
  ),
);
Overlay.of(context).insert(entry);
```

This requires adding `AppController.updateLabel`:

```dart
void updateLabel({
  required int labelId,
  required String name,
  required int color,
  String? shortcut,
}) {
  final project = _requireProject();
  _recordUndo();
  _project = AnnotationRules.updateLabel(
    project,
    labelId: labelId,
    name: name,
    color: color,
    shortcut: shortcut,
  );
  _scheduleAutoSave();
  notifyListeners();
}
```

Also change `AppController.addLabel` signature:

```dart
LabelClass addLabel(String name, int color, {String? shortcut}) {
  final project = _requireProject();
  _recordUndo();
  final updated = AnnotationRules.addLabel(
    project,
    name: name,
    color: color,
    shortcut: shortcut,
  );
  _project = updated;
  _scheduleAutoSave();
  notifyListeners();
  return updated.labels.last;
}
```

- [ ] **Step 7: Update keyboard shortcut lookup**

Replace `_quickLabelShortcutIndex` usage in `_handleWorkbenchKey` with label lookup:

```dart
final shortcut = _shortcutForKey(event.logicalKey);
if (shortcut == null || controller.selectedBoxId == null) {
  return KeyEventResult.ignored;
}
final label = project.labels.where((label) => label.shortcut == shortcut).firstOrNull;
if (label == null) {
  return KeyEventResult.ignored;
}
controller.assignSelectedBoxLabel(label.id);
return KeyEventResult.handled;
```

Dart does not have `firstOrNull` in all SDK versions, so add helper:

```dart
LabelClass? _labelForShortcut(AnnotationProject project, String shortcut) {
  for (final label in project.labels) {
    if (label.shortcut == shortcut) {
      return label;
    }
  }
  return null;
}
```

Use:

```dart
final label = _labelForShortcut(project, shortcut);
```

Rename `_quickLabelShortcutIndex` to:

```dart
String? _shortcutForKey(LogicalKeyboardKey key) {
  for (var index = 0; index < _quickLabelShortcutKeys.length; index++) {
    if (_quickLabelShortcutKeys[index] == key) {
      return _quickLabelShortcutLabels[index];
    }
  }
  return null;
}
```

- [ ] **Step 8: Run widget tests**

Run:

```powershell
flutter test test/ui/label_management_popover_test.dart test/ui/workbench_widget_test.dart test/ui/workbench_label_selector_test.dart
```

Expected: PASS after updating old expectations about the right inspector label selector.

- [ ] **Step 9: Commit if git is available**

Run:

```powershell
git status --short
git add lib/ui/workbench_screen.dart lib/ui/label_management_popover.dart lib/ui/app_controller.dart test/ui/workbench_widget_test.dart test/ui/label_management_popover_test.dart test/ui/workbench_label_selector_test.dart
git commit -m "feat: add center quick label management"
```

Skip the commit if this workspace is still not a git repository.

---

### Task 5: Full Regression And Polish

**Files:**
- Modify only files with failing tests or visible copy regressions from Tasks 1-4.
- Test: full test suite.

**Interfaces:**
- Consumes all previous task outputs.
- Produces verified manual-first workflow.

- [ ] **Step 1: Run analyzer**

Run:

```powershell
flutter analyze
```

Expected: no errors. Fix any compile errors caused by signature changes, especially detector test doubles and old `addLabel` call sites.

- [ ] **Step 2: Run full test suite**

Run:

```powershell
flutter test
```

Expected: PASS. Important likely failure areas:

- Tests expecting proposals immediately after import.
- Tests expecting label selector in the right inspector.
- Detector doubles missing the `options` parameter.
- Serialization tests comparing exact JSON without `shortcut`.

- [ ] **Step 3: Build Windows app**

Run:

```powershell
flutter build windows
```

Expected: build succeeds.

- [ ] **Step 4: Manual smoke test**

Run the built app or `flutter run -d windows`, then verify:

```text
1. Create or open a project.
2. Add a folder with multiple images.
3. Confirm the image list appears before any detection work.
4. Select one image.
5. Draw a manual box.
6. Assign a label from the center-bottom quick-label bar.
7. Press Auto boxes and verify existing boxes are replaced without a confirmation modal.
8. Press Undo and verify the previous boxes return.
9. Enable Proposal count, set 5, press Auto boxes, and verify the app remains responsive.
10. Press Clear boxes and confirm the image can be confirmed as no objects.
11. Export COCO and verify proposal boxes are excluded.
```

- [ ] **Step 5: Self-review changed files**

Run:

```powershell
git diff -- lib test docs
```

Check specifically:

- Import path no longer awaits detector calls.
- Current-image detection does not destroy boxes on failure.
- Auto boxes and clear boxes have no confirmation dialog.
- Quick-label bar is in the center viewer area.
- Right inspector no longer shows a full duplicate label list.
- COCO exporter was not changed except tests if needed.

- [ ] **Step 6: Commit if git is available**

Run:

```powershell
git status --short
git add lib test docs
git commit -m "test: verify manual first detection workflow"
```

Skip the commit if this workspace is still not a git repository.

---

## Plan Self-Review

- Spec coverage: Covered immediate import, current-image auto boxes, full replacement, no confirmation modals, Undo recovery, proposal count toggle, right inspector cleanup, bottom quick-label bar, label management, detector options, COCO preservation, and test coverage.
- Placeholder scan: No incomplete placeholder work remains.
- Type consistency: `DetectionOptions`, `LabelClass.shortcut`, `AnnotationRules.updateLabel`, `AppController.detectSelectedImage`, `clearSelectedImageBoxes`, and proposal count properties are introduced before later tasks consume them.
- Scope check: The work is a single coherent workflow change. It touches domain, detector, controller, and UI, but each task produces a testable intermediate state.
