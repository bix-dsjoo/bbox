# Portable Project And Review Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow image-free BBox project snapshots to move between PCs, safely reconnect missing source files, keep box numbering and label progression in visual order, improve confirmed-box visibility, and make review candidates explicitly selectable.

**Architecture:** Keep internal autosave separate from transferable snapshots. Add focused `ProjectSnapshotService`, `SourceRelinkService`, and `BoxDisplayOrder` units, then expose them through `AppController`; UI widgets only pick paths and render controller state. Source availability is derived per PC and never overwrites persisted annotation review state.

**Tech Stack:** Flutter 3.x/Dart 3.12, Windows desktop, `filepicker_windows`, `path`, `image`, `crypto`, Flutter unit/widget/integration tests.

## Global Constraints

- Transfer files contain project JSON only; never copy or embed source images.
- Try stored absolute `sourcePath` values first and show reconnect actions only for missing paths.
- Reconnect must support both multiple files and recursive folder search.
- Missing sources must not change `ImageStatus`, labels, boxes, automatic-label metadata, or confirmation state.
- Confirmed labeled boxes retain white borders; remove the black shadow and interior fill.
- Canvas numbering, inspector ordering, and next-label selection share one top-left-to-bottom-right row order.
- Review candidates must support mouse selection, Up/Down selection, Enter application, and an explicit apply button.
- Preserve unrelated working-tree changes in `models/bread_pipeline_manifest.json`, packaging files, detector worker files, and their tests.
- Do not change original image bytes or paths on disk.

---

## File Structure

### New production files

- `lib/annotation/box_display_order.dart`: deterministic visual row ordering and display-number lookup.
- `lib/project/project_snapshot_service.dart`: write/read transferable JSON without changing the active internal project path.
- `lib/project/source_relink_service.dart`: source availability inspection, candidate metadata loading, safe file/folder matching.
- `lib/ui/project_transfer_picker.dart`: injectable Windows open/save dialogs for `.bbox.json` files.

### New test files

- `test/annotation/box_display_order_test.dart`
- `test/project/project_snapshot_service_test.dart`
- `test/project/source_relink_service_test.dart`
- `test/ui/project_transfer_picker_test.dart`
- `test/integration/project_transfer_relink_test.dart`

### Existing files modified

- `pubspec.yaml`, `pubspec.lock`: declare direct `crypto` dependency.
- `lib/project/project_library.dart`: import a validated snapshot into a new internal project directory.
- `lib/ui/app_controller.dart`: snapshot actions, source availability/relink state, common next-box order, review candidate selection.
- `lib/ui/bbox_app.dart`, `lib/ui/start_screen.dart`, `lib/ui/project_home_copy.dart`: inject picker and expose project-file import.
- `lib/ui/workbench_screen.dart`, `lib/ui/workbench/workbench_helpers.dart`, `lib/ui/workbench/workbench_feedback.dart`, `lib/ui/workbench/viewer_panel.dart`, `lib/ui/workbench/inspector_panel.dart`, `lib/ui/workbench/image_canvas.dart`, `lib/ui/workbench_copy.dart`: snapshot save, reconnect UI, shared ordering, candidate UI, box styling.
- `test/support/memory_project_library.dart`: in-memory snapshot import implementation.
- `test/ui/workbench/workbench_test_support.dart`: injectable project-transfer and image-relink test fakes.
- Existing controller, project, home, workbench, inspector, and canvas test files listed in each task.

---

### Task 1: Shared Visual Box Order And Sequential Label Progression

**Files:**
- Create: `lib/annotation/box_display_order.dart`
- Create: `test/annotation/box_display_order_test.dart`
- Modify: `lib/ui/app_controller.dart`
- Modify: `lib/ui/workbench/workbench_screen.dart`
- Modify: `lib/ui/workbench/workbench_helpers.dart`
- Modify: `test/ui/app_controller_test.dart`
- Modify: `test/ui/workbench/inspector_panel_test.dart`

**Interfaces:**
- Produces: `BoxDisplayOrder.sorted(AnnotatedImage) -> List<BoundingBox>` and `BoxDisplayOrder.numbers(AnnotatedImage) -> Map<String, int>`.
- Consumed by: `AppController.nextBoxNeedingLabelId`, workbench display-number helpers, sidebar grouping, and table order.

- [ ] **Step 1: Write failing deterministic-order tests**

```dart
// test/annotation/box_display_order_test.dart
import 'package:bbox_labeler/annotation/box_display_order.dart';
import 'package:bbox_labeler/annotation/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('orders rows top-to-bottom and boxes left-to-right', () {
    final image = _image(const [
      BoundingBox(id: 'bottom-left', x: 8, y: 60, width: 20, height: 20, status: BoxStatus.proposal),
      BoundingBox(id: 'top-right', x: 70, y: 12, width: 20, height: 20, status: BoxStatus.proposal),
      BoundingBox(id: 'top-left', x: 10, y: 10, width: 20, height: 20, status: BoxStatus.proposal),
    ]);

    expect(BoxDisplayOrder.sorted(image).map((box) => box.id), [
      'top-left',
      'top-right',
      'bottom-left',
    ]);
    expect(BoxDisplayOrder.numbers(image), {
      'top-left': 1,
      'top-right': 2,
      'bottom-left': 3,
    });
  });

  test('uses a fixed row anchor so chained y offsets do not merge rows', () {
    final image = _image(const [
      BoundingBox(id: 'a', x: 60, y: 0, width: 20, height: 20, status: BoxStatus.proposal),
      BoundingBox(id: 'b', x: 40, y: 9, width: 20, height: 20, status: BoxStatus.proposal),
      BoundingBox(id: 'c', x: 20, y: 18, width: 20, height: 20, status: BoxStatus.proposal),
    ]);

    expect(BoxDisplayOrder.sorted(image).map((box) => box.id), ['b', 'a', 'c']);
  });
}

AnnotatedImage _image(List<BoundingBox> boxes) => AnnotatedImage(
  id: 1,
  sourcePath: 'a.jpg',
  displayName: 'a.jpg',
  width: 200,
  height: 100,
  status: ImageStatus.needsReview,
  boxes: boxes,
);
```

Add a controller test whose source list is deliberately `#3, #1, #2`, select visual `#1`, assign a label, and expect visual `#2` to be selected. Add an inspector test asserting row keys follow the same order.

- [ ] **Step 2: Run tests and verify the missing API/current-order failures**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\annotation\box_display_order_test.dart test\ui\app_controller_test.dart test\ui\workbench\inspector_panel_test.dart -r expanded
```

Expected: FAIL because `box_display_order.dart` does not exist and the controller still uses `image.visibleBoxes` insertion order.

- [ ] **Step 3: Implement the common ordering service**

```dart
// lib/annotation/box_display_order.dart
import 'dart:math' as math;

import 'models.dart';

class BoxDisplayOrder {
  const BoxDisplayOrder._();

  static List<BoundingBox> sorted(AnnotatedImage image) {
    final indexed = <_IndexedBox>[
      for (var index = 0; index < image.boxes.length; index++)
        if (!image.boxes[index].isDeleted)
          _IndexedBox(image.boxes[index], index),
    ]..sort(_compareInitial);

    final rows = <_VisualRow>[];
    for (final item in indexed) {
      if (rows.isEmpty || !rows.last.accepts(item.box)) {
        rows.add(_VisualRow(item));
      } else {
        rows.last.items.add(item);
      }
    }

    return [
      for (final row in rows)
        ...([...row.items]..sort(_compareWithinRow)).map((item) => item.box),
    ];
  }

  static Map<String, int> numbers(AnnotatedImage image) {
    final ordered = sorted(image);
    return {
      for (var index = 0; index < ordered.length; index++)
        ordered[index].id: index + 1,
    };
  }

  static int _compareInitial(_IndexedBox a, _IndexedBox b) {
    final y = a.box.y.compareTo(b.box.y);
    if (y != 0) return y;
    final x = a.box.x.compareTo(b.box.x);
    if (x != 0) return x;
    return _stableTieBreak(a, b);
  }

  static int _compareWithinRow(_IndexedBox a, _IndexedBox b) {
    final x = a.box.x.compareTo(b.box.x);
    if (x != 0) return x;
    final y = a.box.y.compareTo(b.box.y);
    if (y != 0) return y;
    return _stableTieBreak(a, b);
  }

  static int _stableTieBreak(_IndexedBox a, _IndexedBox b) {
    final original = a.originalIndex.compareTo(b.originalIndex);
    return original != 0 ? original : a.box.id.compareTo(b.box.id);
  }
}

class _IndexedBox {
  const _IndexedBox(this.box, this.originalIndex);
  final BoundingBox box;
  final int originalIndex;
}

class _VisualRow {
  _VisualRow(_IndexedBox anchor)
      : anchorY = anchor.box.y,
        anchorHeight = anchor.box.height,
        items = [anchor];

  final double anchorY;
  final double anchorHeight;
  final List<_IndexedBox> items;

  bool accepts(BoundingBox box) {
    final tolerance = math.max(4.0, math.min(anchorHeight, box.height) * 0.5);
    return (box.y - anchorY).abs() <= tolerance;
  }
}
```

In `app_controller.dart`, import the file and replace the first line of `nextBoxNeedingLabelId` with:

```dart
final boxes = BoxDisplayOrder.sorted(image);
```

In `workbench_screen.dart`, import `../../annotation/box_display_order.dart`. Replace `_boxDisplayNumbers` with:

```dart
Map<String, int> _boxDisplayNumbers(AnnotatedImage image) =>
    BoxDisplayOrder.numbers(image);
```

Delete `_sameVisualRow`, remove the now-unused `math` dependency from `workbench_helpers.dart`, and make `_sidebarBoxGroups` iterate over `BoxDisplayOrder.sorted(image)`.

- [ ] **Step 4: Run focused tests and the analyzer**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\annotation\box_display_order_test.dart test\ui\app_controller_test.dart test\ui\workbench\inspector_panel_test.dart -r expanded
& C:\tools\flutter\bin\flutter.bat analyze
```

Expected: all focused tests PASS; analyzer reports no new issue.

- [ ] **Step 5: Commit the shared-order change**

```powershell
git add lib/annotation/box_display_order.dart lib/ui/app_controller.dart lib/ui/workbench/workbench_screen.dart lib/ui/workbench/workbench_helpers.dart test/annotation/box_display_order_test.dart test/ui/app_controller_test.dart test/ui/workbench/inspector_panel_test.dart
git commit -m "fix: align label progression with box numbers"
```

---

### Task 2: Transferable Project Snapshot Core

**Files:**
- Create: `lib/project/project_snapshot_service.dart`
- Create: `test/project/project_snapshot_service_test.dart`
- Modify: `lib/project/project_library.dart`
- Modify: `test/project/project_library_test.dart`
- Modify: `test/support/memory_project_library.dart`

**Interfaces:**
- Produces: `ProjectSnapshotService.writeSnapshot(project, targetPath)` and `readSnapshot(path)`.
- Produces: `ProjectLibrary.importProject(AnnotationProject) -> Future<AnnotationProject>`.
- Consumed by: controller transfer actions in Task 4.

- [ ] **Step 1: Write failing snapshot and library-import tests**

Test these exact invariants:

```dart
final original = _project(projectFilePath: internalPath);
await service.writeSnapshot(original, transferPath);
final raw = jsonDecode(await File(transferPath).readAsString()) as Map<String, Object?>;
expect(raw['projectFilePath'], isNull);
expect(original.projectFilePath, internalPath);

final restored = await service.readSnapshot(transferPath);
expect(restored.projectFilePath, isNull);
expect(restored.images.single.status, ImageStatus.confirmed);
expect(restored.images.single.boxes.single.labelId, 1);
expect(restored.images.single.boxes.single.automation?.pipelineVersion, 'pipeline-v1');
```

In `project_library_test.dart`, import an `AnnotationProject` whose `projectFilePath` points outside the library and expect the returned path to be `projects/<new-id>/project.bbox.json`, with the source image absolute path and annotation IDs unchanged.

Also write a snapshot whose labeled box references a missing label ID and expect `InvalidProjectSnapshotException`; verify no internal library directory or index entry is created.

- [ ] **Step 2: Run focused tests and verify failure**

```powershell
& C:\tools\flutter\bin\flutter.bat test test\project\project_snapshot_service_test.dart test\project\project_library_test.dart -r expanded
```

Expected: FAIL because the service and `ProjectLibrary.importProject` do not exist.

- [ ] **Step 3: Implement snapshot serialization and internal import**

```dart
// lib/project/project_snapshot_service.dart
import 'dart:convert';
import 'dart:io';

import '../annotation/models.dart';
import 'project_store.dart';

typedef SnapshotClock = DateTime Function();

class InvalidProjectSnapshotException implements Exception {
  const InvalidProjectSnapshotException(this.message);
  final String message;
  @override
  String toString() => 'Invalid project snapshot: $message';
}

class ProjectSnapshotService {
  ProjectSnapshotService({SnapshotClock? clock}) : _clock = clock ?? DateTime.now;

  final SnapshotClock _clock;

  Future<void> writeSnapshot(
    AnnotationProject project,
    String targetPath,
  ) async {
    final snapshot = project.copyWith(
      schemaVersion: ProjectStore.currentSchemaVersion,
      projectFilePath: null,
      status: ProjectStatus.ready,
      lastSavedAt: _clock().toUtc(),
    );
    final target = File(targetPath);
    await target.parent.create(recursive: true);
    final temp = File('$targetPath.tmp-${DateTime.now().microsecondsSinceEpoch}');
    final backup = File('$targetPath.bak-${DateTime.now().microsecondsSinceEpoch}');
    var targetMovedToBackup = false;
    try {
      await temp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(snapshot.toJson()),
        encoding: utf8,
        flush: true,
      );
      if (await target.exists()) {
        await target.rename(backup.path);
        targetMovedToBackup = true;
      }
      await temp.rename(targetPath);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (targetMovedToBackup && !await target.exists() && await backup.exists()) {
        await backup.rename(targetPath);
      }
      rethrow;
    } finally {
      if (await temp.exists()) await temp.delete();
      if (await backup.exists() && await target.exists()) await backup.delete();
    }
  }

  Future<AnnotationProject> readSnapshot(String path) async {
    final loaded = await ProjectStore.load(path);
    final snapshot = loaded.copyWith(
      projectFilePath: null,
      status: ProjectStatus.ready,
    );
    _validate(snapshot);
    return snapshot;
  }

  void _validate(AnnotationProject project) {
    final labelIds = project.labels.map((label) => label.id).toSet();
    if (labelIds.length != project.labels.length) {
      throw const InvalidProjectSnapshotException('duplicate label id');
    }
    final imageIds = project.images.map((image) => image.id).toSet();
    if (imageIds.length != project.images.length) {
      throw const InvalidProjectSnapshotException('duplicate image id');
    }
    for (final image in project.images) {
      final boxIds = image.boxes.map((box) => box.id).toSet();
      if (boxIds.length != image.boxes.length) {
        throw InvalidProjectSnapshotException(
          'duplicate box id in image ${image.id}',
        );
      }
      for (final box in image.boxes) {
        if (box.labelId != null && !labelIds.contains(box.labelId)) {
          throw InvalidProjectSnapshotException(
            'missing label ${box.labelId} for box ${box.id}',
          );
        }
        final automation = box.automation;
        if (automation?.suggestedLabelId != null &&
            !labelIds.contains(automation!.suggestedLabelId)) {
          throw InvalidProjectSnapshotException(
            'missing suggested label for box ${box.id}',
          );
        }
        for (final candidate in automation?.candidates ?? const <LabelCandidate>[]) {
          if (!labelIds.contains(candidate.labelId)) {
            throw InvalidProjectSnapshotException(
              'missing candidate label for box ${box.id}',
            );
          }
        }
      }
    }
  }
}
```

Add this public method to `ProjectLibrary`:

```dart
Future<AnnotationProject> importProject(AnnotationProject source) async {
  final timestamp = _clock().toUtc();
  final id = await _uniqueProjectId(source.name, timestamp);
  final targetPath = p.join(projectsRootPath, id, 'project.bbox.json');
  final imported = source.copyWith(
    projectFilePath: targetPath,
    status: ProjectStatus.ready,
  );
  final saved = await ProjectStore.save(imported, targetPath);
  try {
    await refreshEntry(saved, createdAt: timestamp, updatedAt: timestamp);
    return saved;
  } catch (_) {
    final directory = Directory(p.dirname(targetPath));
    if (await directory.exists()) await directory.delete(recursive: true);
    rethrow;
  }
}
```

Override the same method in `MemoryProjectLibrary`, allocating a unique ID and storing a copy with the internal memory-library path.

- [ ] **Step 4: Run tests**

```powershell
& C:\tools\flutter\bin\flutter.bat test test\project\project_snapshot_service_test.dart test\project\project_library_test.dart -r expanded
```

Expected: PASS, including unsupported schema propagation from `ProjectStore.load`.

- [ ] **Step 5: Commit snapshot core**

```powershell
git add lib/project/project_snapshot_service.dart lib/project/project_library.dart test/project/project_snapshot_service_test.dart test/project/project_library_test.dart test/support/memory_project_library.dart
git commit -m "feat: add transferable project snapshots"
```

---

### Task 3: Source Availability And Safe File/Folder Relinking

**Files:**
- Create: `lib/project/source_relink_service.dart`
- Create: `test/project/source_relink_service_test.dart`
- Modify: `pubspec.yaml`
- Modify: `pubspec.lock`

**Interfaces:**
- Produces: `SourceAvailability`, `SourceRelinkResult`, `SourceRelinkService.inspectSources`, `relinkFiles`, and `relinkFolder`.
- Consumed by: `AppController` in Task 4.

- [ ] **Step 1: Add the direct hashing dependency**

Add under `dependencies`:

```yaml
  crypto: ^3.0.7
```

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat pub get
```

Expected: dependency resolution succeeds and `pubspec.lock` records `crypto` as a direct main dependency.

- [ ] **Step 2: Write failing service tests with real temporary images**

Create small PNG fixtures and cover:

```dart
test('availability does not mutate annotation status', () async {
  final image = _image(sourcePath: missingPath, status: ImageStatus.confirmed);
  final result = await service.inspectSources([image]);
  expect(result[image.id], SourceAvailability.missing);
  expect(image.status, ImageStatus.confirmed);
});

test('file relink matches a unique filename and dimensions', () async {
  final result = await service.relinkFiles(
    missingImages: [_image(sourcePath: r'C:\old\bread.png', width: 32, height: 24)],
    candidatePaths: [candidate.path],
  );
  expect(result.matchedPaths, {1: candidate.path});
  expect(result.ambiguousImageIds, isEmpty);
});

test('folder relink prefers the original relative path', () async {
  final image = _image(
    sourcePath: p.join('C:\\old', 'batch', 'bread.png'),
    importedFrom: 'C:\\old',
    width: 32,
    height: 24,
  );
  final result = await service.relinkFolder(
    missingImages: [image],
    folderPath: replacementRoot.path,
  );
  expect(result.matchedPaths[1], p.join(replacementRoot.path, 'batch', 'bread.png'));
});

test('does not auto-link ambiguous candidates', () async {
  final result = await service.relinkFiles(
    missingImages: [_image(sourcePath: r'C:\old\bread.png', width: 32, height: 24)],
    candidatePaths: [candidateA.path, candidateB.path],
  );
  expect(result.matchedPaths, isEmpty);
  expect(result.ambiguousImageIds, {1});
});
```

Also add a hash-priority test where two files have the same name/dimensions but only one SHA-256 matches `contentSha256`.

- [ ] **Step 3: Run the service tests and verify failure**

```powershell
& C:\tools\flutter\bin\flutter.bat test test\project\source_relink_service_test.dart -r expanded
```

Expected: FAIL because the service does not exist.

- [ ] **Step 4: Implement source inspection and matching**

The public types must be:

```dart
enum SourceAvailability { unknown, available, missing }

class SourceRelinkResult {
  const SourceRelinkResult({
    required this.matchedPaths,
    required this.matchedImportedFrom,
    required this.unresolvedImageIds,
    required this.ambiguousImageIds,
  });

  final Map<int, String> matchedPaths;
  final Map<int, String> matchedImportedFrom;
  final Set<int> unresolvedImageIds;
  final Set<int> ambiguousImageIds;

  int get matchedCount => matchedPaths.length;
}

class SourceRelinkService {
  const SourceRelinkService();

  Future<Map<int, SourceAvailability>> inspectSources(
    Iterable<AnnotatedImage> images,
  ) async {
    final entries = await Future.wait([
      for (final image in images)
        File(image.sourcePath).exists().then(
          (exists) => MapEntry(
            image.id,
            exists ? SourceAvailability.available : SourceAvailability.missing,
          ),
        ),
    ]);
    return Map.fromEntries(entries);
  }

  Future<SourceRelinkResult> relinkFiles({
    required List<AnnotatedImage> missingImages,
    required List<String> candidatePaths,
  }) async => _match(
    missingImages,
    candidatePaths,
    importedFromForMatch: p.dirname,
  );

  Future<SourceRelinkResult> relinkFolder({
    required List<AnnotatedImage> missingImages,
    required String folderPath,
  }) async {
    final root = Directory(folderPath);
    if (!await root.exists()) {
      throw FileSystemException('Image folder does not exist.', folderPath);
    }
    final candidates = await root
        .list(recursive: true, followLinks: false)
        .where((entity) => entity is File && ImageScanner.isSupportedImagePath(entity.path))
        .cast<File>()
        .map((file) => file.path)
        .toList();
    final preferred = <int, String>{};
    for (final image in missingImages) {
      final importedFrom = image.importedFrom;
      if (importedFrom == null) continue;
      if (!p.isWithin(p.normalize(importedFrom), p.normalize(image.sourcePath))) {
        continue;
      }
      final relative = p.relative(image.sourcePath, from: importedFrom);
      if (p.isAbsolute(relative)) continue;
      final candidate = p.join(folderPath, relative);
      if (await File(candidate).exists()) preferred[image.id] = candidate;
    }
    return _match(
      missingImages,
      candidates,
      preferredPaths: preferred,
      importedFromForMatch: (_) => folderPath,
    );
  }
}
```

Implement `_match` and candidate inspection as follows:

```dart
Future<SourceRelinkResult> _match(
  List<AnnotatedImage> images,
  List<String> paths, {
  Map<int, String> preferredPaths = const {},
  required String Function(String path) importedFromForMatch,
}) async {
  final includeHash = images.any((image) => image.contentSha256 != null);
  final uniquePaths = <String, String>{
    for (final path in paths) p.normalize(path).toLowerCase(): p.normalize(path),
  }.values.toList(growable: false);
  final inspected = await Future.wait([
    for (final path in uniquePaths) _inspectCandidate(path, includeHash),
  ]);
  final candidates = inspected.whereType<_CandidateMetadata>().toList();
  final byPath = {
    for (final candidate in candidates)
      p.normalize(candidate.path).toLowerCase(): candidate,
  };

  final proposals = <int, List<_CandidateMetadata>>{};
  for (final image in images) {
    final preferred = preferredPaths[image.id];
    final preferredCandidate = preferred == null
        ? null
        : byPath[p.normalize(preferred).toLowerCase()];
    if (preferredCandidate != null && _matches(image, preferredCandidate)) {
      proposals[image.id] = [preferredCandidate];
      continue;
    }
    proposals[image.id] = [
      for (final candidate in candidates)
        if (_matches(image, candidate)) candidate,
    ];
  }

  final ambiguous = <int>{};
  final single = <int, _CandidateMetadata>{};
  for (final entry in proposals.entries) {
    if (entry.value.length > 1) {
      ambiguous.add(entry.key);
    } else if (entry.value.length == 1) {
      single[entry.key] = entry.value.single;
    }
  }

  final ownersByPath = <String, List<int>>{};
  for (final entry in single.entries) {
    final key = p.normalize(entry.value.path).toLowerCase();
    ownersByPath.putIfAbsent(key, () => []).add(entry.key);
  }
  for (final owners in ownersByPath.values) {
    if (owners.length > 1) {
      ambiguous.addAll(owners);
      for (final imageId in owners) single.remove(imageId);
    }
  }

  final matchedPaths = <int, String>{};
  final matchedImportedFrom = <int, String>{};
  for (final entry in single.entries) {
    if (ambiguous.contains(entry.key)) continue;
    matchedPaths[entry.key] = entry.value.path;
    matchedImportedFrom[entry.key] = importedFromForMatch(entry.value.path);
  }
  final unresolved = {
    for (final image in images)
      if (!matchedPaths.containsKey(image.id) && !ambiguous.contains(image.id))
        image.id,
  };
  return SourceRelinkResult(
    matchedPaths: matchedPaths,
    matchedImportedFrom: matchedImportedFrom,
    unresolvedImageIds: unresolved,
    ambiguousImageIds: ambiguous,
  );
}

bool _matches(AnnotatedImage image, _CandidateMetadata candidate) {
  final expectedHash = image.contentSha256;
  if (expectedHash != null) return candidate.sha256 == expectedHash;
  return candidate.fileNameKey == image.displayName.toLowerCase() &&
      candidate.width == image.width &&
      candidate.height == image.height;
}

Future<_CandidateMetadata?> _inspectCandidate(
  String path,
  bool includeHash,
) async {
  try {
    final bytes = await File(path).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    return _CandidateMetadata(
      path: p.normalize(path),
      fileNameKey: p.basename(path).toLowerCase(),
      width: decoded.width,
      height: decoded.height,
      sha256: includeHash ? sha256.convert(bytes).toString() : null,
    );
  } on FileSystemException {
    return null;
  }
}

class _CandidateMetadata {
  const _CandidateMetadata({
    required this.path,
    required this.fileNameKey,
    required this.width,
    required this.height,
    required this.sha256,
  });

  final String path;
  final String fileNameKey;
  final int width;
  final int height;
  final String? sha256;
}
```

Import `package:crypto/crypto.dart`, `package:image/image.dart` as `img`, `package:path/path.dart` as `p`, `../annotation/models.dart`, and `../image_import/image_scanner.dart`. Do not update `AnnotatedImage` inside this service.

- [ ] **Step 5: Run service tests and analyzer**

```powershell
& C:\tools\flutter\bin\flutter.bat test test\project\source_relink_service_test.dart -r expanded
& C:\tools\flutter\bin\flutter.bat analyze
```

Expected: PASS and no analyzer issue.

- [ ] **Step 6: Commit the relink service**

```powershell
git add pubspec.yaml pubspec.lock lib/project/source_relink_service.dart test/project/source_relink_service_test.dart
git commit -m "feat: match missing project image sources"
```

---

### Task 4: Controller Transfer, Availability, And Relink Actions

**Files:**
- Modify: `lib/ui/app_controller.dart`
- Modify: `test/ui/app_controller_library_test.dart`
- Modify: `test/ui/app_controller_test.dart`

**Interfaces:**
- Consumes: snapshot, library import, and relink service APIs from Tasks 2-3.
- Produces: controller state and commands used by UI Tasks 5-6.

- [ ] **Step 1: Write failing controller tests**

Add tests for:

```dart
await controller.saveProjectSnapshot(transferPath);
expect(controller.project!.projectFilePath, internalPath);
expect(await File(transferPath).exists(), isTrue);

await receivingController.importProjectSnapshot(transferPath);
expect(receivingController.project!.projectFilePath, startsWith(receivingLibrary.projectsRootPath));
expect(receivingController.project!.images.single.status, ImageStatus.confirmed);

await controller.refreshSourceAvailability();
expect(controller.missingSourceCount, 1);
expect(controller.project!.images.single.status, ImageStatus.confirmed);

final result = await controller.relinkSourceFiles([replacementPath]);
expect(result.matchedCount, 1);
expect(controller.project!.images.single.sourcePath, replacementPath);
expect(controller.project!.images.single.status, ImageStatus.confirmed);
```

Add two identical missing-image records and verify `relinkSourceFiles([replacementPath])` is ambiguous, then select one missing image and verify `relinkSelectedSourceFile(replacementPath)` connects only that image. Change the existing `validates missing image source files before continuing` assertion from `ImageStatus.error` to the original status and assert `SourceAvailability.missing` instead.

- [ ] **Step 2: Run tests and verify failure**

```powershell
& C:\tools\flutter\bin\flutter.bat test test\ui\app_controller_library_test.dart test\ui\app_controller_test.dart -r expanded
```

Expected: FAIL because transfer/relink APIs and state are missing.

- [ ] **Step 3: Add injected services and derived availability state**

Extend the constructor and fields:

```dart
AppController({
  ProjectLibrary? projectLibrary,
  ProjectSnapshotService? projectSnapshotService,
  SourceRelinkService? sourceRelinkService,
  AutoBoxRuntime? autoBoxRuntime,
  BoxLabelCache? boxLabelCache,
}) : _projectLibrary = projectLibrary ?? ProjectLibrary.appData(),
     _projectSnapshotService = projectSnapshotService ?? ProjectSnapshotService(),
     _sourceRelinkService = sourceRelinkService ?? const SourceRelinkService(),
     _autoBoxRuntime = autoBoxRuntime ?? defaultAutoBoxService(),
     _boxLabelCache = boxLabelCache ?? BoxLabelCache() {
  _autoBoxRuntime.addListener(_handleAutoBoxRuntimeChanged);
}

final ProjectSnapshotService _projectSnapshotService;
final SourceRelinkService _sourceRelinkService;
Map<int, SourceAvailability> _sourceAvailability = const {};

Map<int, SourceAvailability> get sourceAvailability =>
    Map.unmodifiable(_sourceAvailability);
int get missingSourceCount => _sourceAvailability.values
    .where((value) => value == SourceAvailability.missing)
    .length;
SourceAvailability get selectedSourceAvailability =>
    _sourceAvailability[selectedImageId] ?? SourceAvailability.unknown;

SelectedImageViewState get selectedImageViewState =>
    switch (selectedSourceAvailability) {
      SourceAvailability.available => SelectedImageViewState.ready,
      SourceAvailability.missing => SelectedImageViewState.missing,
      SourceAvailability.unknown => SelectedImageViewState.unknown,
    };
```

Replace the existing synchronous `File.existsSync()` implementation of `selectedImageViewState`. Reset `_sourceAvailability` to `unknown` entries whenever a project is loaded and clear it whenever the active project is cleared. After adding new image files, record those new IDs as `available` without rescanning the entire project; after removing an image, remove its map entry. After Undo or Redo restores a project snapshot, call `unawaited(refreshSourceAvailability())` so the derived map cannot refer to stale image IDs or paths.

- [ ] **Step 4: Implement snapshot and refresh commands**

```dart
Future<void> saveProjectSnapshot(String targetPath) async {
  await _autoSaveChain;
  await _projectSnapshotService.writeSnapshot(_requireProject(), targetPath);
  lastUserMessage = WorkbenchCopy.projectFileSaved(targetPath);
  notifyListeners();
}

Future<void> importProjectSnapshot(String sourcePath) async {
  final source = await _projectSnapshotService.readSnapshot(sourcePath);
  final imported = await _projectLibrary.importProject(source);
  loadProject(imported);
  _currentLibraryProjectId = _libraryProjectIdForPath(imported.projectFilePath);
  _projectLibraryEntries = await _projectLibrary.listProjects();
  await refreshSourceAvailability();
}

Future<void> refreshSourceAvailability() async {
  final project = _project;
  if (project == null) return;
  _projectActivity = ProjectActivity.validating;
  notifyListeners();
  try {
    _sourceAvailability = await _sourceRelinkService.inspectSources(project.images);
  } finally {
    _projectActivity = ProjectActivity.idle;
    notifyListeners();
  }
}
```

Make `openLibraryProject` await `refreshSourceAvailability()` after loading. Rewrite `validateSourceFiles()` as a compatibility wrapper that calls refresh and returns missing paths without modifying the project.

- [ ] **Step 5: Implement file/folder relink commands**

```dart
Future<SourceRelinkResult> relinkSourceFiles(List<String> paths) async {
  return _relink(() => _sourceRelinkService.relinkFiles(
    missingImages: _missingImages(),
    candidatePaths: paths,
  ));
}

Future<SourceRelinkResult> relinkSelectedSourceFile(String path) async {
  final image = selectedImage;
  if (image == null ||
      _sourceAvailability[image.id] != SourceAvailability.missing) {
    return const SourceRelinkResult(
      matchedPaths: {},
      matchedImportedFrom: {},
      unresolvedImageIds: {},
      ambiguousImageIds: {},
    );
  }
  return _relink(() => _sourceRelinkService.relinkFiles(
    missingImages: [image],
    candidatePaths: [path],
  ));
}

Future<SourceRelinkResult> relinkSourceFolder(String folderPath) async {
  return _relink(() => _sourceRelinkService.relinkFolder(
    missingImages: _missingImages(),
    folderPath: folderPath,
  ));
}

List<AnnotatedImage> _missingImages() => [
  for (final image in _requireProject().images)
    if (_sourceAvailability[image.id] == SourceAvailability.missing) image,
];

Future<SourceRelinkResult> _relink(
  Future<SourceRelinkResult> Function() operation,
) async {
  _projectActivity = ProjectActivity.validating;
  notifyListeners();
  try {
    final result = await operation();
    if (result.matchedPaths.isNotEmpty) {
      final project = _requireProject();
      _project = project.copyWith(images: [
        for (final image in project.images)
          if (result.matchedPaths.containsKey(image.id))
            image.copyWith(
              sourcePath: result.matchedPaths[image.id],
              importedFrom: result.matchedImportedFrom[image.id],
            )
          else
            image,
      ]);
      _scheduleAutoSave();
    }
    await refreshSourceAvailability();
    return result;
  } finally {
    if (_projectActivity != ProjectActivity.idle) {
      _projectActivity = ProjectActivity.idle;
      notifyListeners();
    }
  }
}
```

Source relink is environment configuration rather than annotation editing, so it does not add an annotation Undo entry. The service sets `matchedImportedFrom` to each selected file's parent for file relink and to the selected replacement root for folder relink. Assert both cases in controller tests.

- [ ] **Step 6: Run controller tests**

```powershell
& C:\tools\flutter\bin\flutter.bat test test\ui\app_controller_library_test.dart test\ui\app_controller_test.dart -r expanded
```

Expected: PASS; missing sources leave `ImageStatus.confirmed`/`needsReview` unchanged.

- [ ] **Step 7: Commit controller integration**

```powershell
git add lib/ui/app_controller.dart test/ui/app_controller_library_test.dart test/ui/app_controller_test.dart
git commit -m "feat: import and reconnect project sources"
```

---

### Task 5: Native Project File Picker And Project Import/Save UI

**Files:**
- Create: `lib/ui/project_transfer_picker.dart`
- Create: `test/ui/project_transfer_picker_test.dart`
- Modify: `lib/ui/bbox_app.dart`
- Modify: `lib/ui/start_screen.dart`
- Modify: `lib/ui/project_home_copy.dart`
- Modify: `lib/ui/workbench/workbench_screen.dart`
- Modify: `lib/ui/workbench_copy.dart`
- Modify: `test/ui/project_home_widget_test.dart`
- Modify: `test/ui/workbench/workbench_test_support.dart`
- Modify: `test/ui/workbench/workbench_shell_test.dart`

**Interfaces:**
- Produces: injectable `ProjectTransferPicker` with import and save destinations.
- Consumes: controller snapshot methods from Task 4.

- [ ] **Step 1: Write failing picker and widget tests**

Assert exact picker configuration:

```dart
expect(projectImportPickerTitle, 'BBox 프로젝트 파일 가져오기');
expect(projectSavePickerTitle, 'BBox 프로젝트 파일 저장');
expect(projectFileFilterSpecification, {'BBox 프로젝트 (*.bbox.json)': '*.bbox.json'});
```

Add home test with a fake picker that returns a temporary snapshot path, tap `import-project-file`, and expect the workbench to open the imported project. Add workbench test that taps `save-project-copy`, expects the fake save picker to be called, and verifies the snapshot file exists while `controller.project!.projectFilePath` remains internal.

- [ ] **Step 2: Run tests and verify failure**

```powershell
& C:\tools\flutter\bin\flutter.bat test test\ui\project_transfer_picker_test.dart test\ui\project_home_widget_test.dart test\ui\workbench\workbench_shell_test.dart -r expanded
```

Expected: FAIL because the picker and buttons do not exist.

- [ ] **Step 3: Implement the injectable picker**

```dart
// lib/ui/project_transfer_picker.dart
import 'package:filepicker_windows/filepicker_windows.dart';

abstract class ProjectTransferPicker {
  const ProjectTransferPicker();
  Future<String?> pickImportFile();
  Future<String?> pickSnapshotDestination();
}

const projectImportPickerTitle = 'BBox 프로젝트 파일 가져오기';
const projectSavePickerTitle = 'BBox 프로젝트 파일 저장';
const projectFileFilterSpecification = {
  'BBox 프로젝트 (*.bbox.json)': '*.bbox.json',
};

class WindowsProjectTransferPicker extends ProjectTransferPicker {
  const WindowsProjectTransferPicker();

  @override
  Future<String?> pickImportFile() async {
    final picker = OpenFilePicker()
      ..title = projectImportPickerTitle
      ..filterSpecification = projectFileFilterSpecification
      ..defaultExtension = 'bbox.json'
      ..fileMustExist = true
      ..forceFileSystemItems = true;
    return picker.getFile()?.path;
  }

  @override
  Future<String?> pickSnapshotDestination() async {
    final picker = SaveFilePicker()
      ..title = projectSavePickerTitle
      ..filterSpecification = projectFileFilterSpecification
      ..defaultExtension = 'bbox.json'
      ..forceFileSystemItems = true;
    return picker.getFile()?.path;
  }
}
```

- [ ] **Step 4: Wire the picker through app, home, and workbench**

Add `projectTransferPicker` injection to `BboxApp`, `StartScreen`, and `WorkbenchScreen`:

```dart
// BboxApp
const BboxApp({
  super.key,
  this.controller,
  this.projectTransferPicker = const WindowsProjectTransferPicker(),
});
final ProjectTransferPicker projectTransferPicker;

// Pass the same instance to both branches.
StartScreen(
  controller: _controller,
  projectTransferPicker: widget.projectTransferPicker,
)
WorkbenchScreen(
  controller: _controller,
  projectTransferPicker: widget.projectTransferPicker,
)
```

On the home screen, place an outlined `프로젝트 파일 가져오기` button beside/below project creation with key `import-project-file` and use:

```dart
Future<void> _importProjectFile() async {
  try {
    final path = await widget.projectTransferPicker.pickImportFile();
    if (path == null) return;
    await widget.controller.importProjectSnapshot(path);
    if (mounted) setState(() => _error = null);
  } catch (error) {
    if (mounted) setState(() => _error = error);
  }
}
```

Add exact home copy:

```dart
static const importProjectFile = '프로젝트 파일 가져오기';
static const importProjectFileHint = '다른 PC에서 저장한 BBox 프로젝트를 가져옵니다.';
```

In the workbench document actions, add a text/icon action with key `save-project-copy`, label `프로젝트 파일 저장`, and call:

```dart
Future<void> _saveProjectCopy(BuildContext context) async {
  try {
    final path = await projectTransferPicker.pickSnapshotDestination();
    if (path == null) return;
    await controller.saveProjectSnapshot(path);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(WorkbenchCopy.projectFileSaved(path))),
      );
    }
  } catch (error) {
    if (context.mounted) {
      _showError(context, WorkbenchCopy.projectFileSaveFailed(error));
    }
  }
}
```

Keep the existing disk-icon `save-project` action for internal autosave/manual save. Do not rename it.

Add exact workbench copy helpers:

```dart
static const saveProjectFile = '프로젝트 파일 저장';
static String projectFileSaved(String path) => '프로젝트 파일을 저장했습니다: $path';
static String projectFileSaveFailed(Object error) =>
    '프로젝트 파일을 저장하지 못했습니다. 경로와 권한을 확인한 뒤 다시 시도하세요. $error';
```

Add an injectable fake in the relevant test support:

```dart
class FakeProjectTransferPicker extends ProjectTransferPicker {
  const FakeProjectTransferPicker({this.importPath, this.snapshotPath});
  final String? importPath;
  final String? snapshotPath;
  @override
  Future<String?> pickImportFile() => SynchronousFuture(importPath);
  @override
  Future<String?> pickSnapshotDestination() =>
      SynchronousFuture(snapshotPath);
}
```

- [ ] **Step 5: Run picker and widget tests**

```powershell
& C:\tools\flutter\bin\flutter.bat test test\ui\project_transfer_picker_test.dart test\ui\project_home_widget_test.dart test\ui\workbench\workbench_shell_test.dart -r expanded
```

Expected: PASS with no native dialog invocation in tests.

- [ ] **Step 6: Commit transfer UI**

```powershell
git add lib/ui/project_transfer_picker.dart lib/ui/bbox_app.dart lib/ui/start_screen.dart lib/ui/project_home_copy.dart lib/ui/workbench/workbench_screen.dart lib/ui/workbench_copy.dart test/ui/project_transfer_picker_test.dart test/ui/project_home_widget_test.dart test/ui/workbench/workbench_test_support.dart test/ui/workbench/workbench_shell_test.dart
git commit -m "feat: expose project file transfer actions"
```

---

### Task 6: Missing-Source Banner And Dual Reconnect UI

**Files:**
- Modify: `lib/ui/workbench/workbench_screen.dart`
- Modify: `lib/ui/workbench/workbench_feedback.dart`
- Modify: `lib/ui/workbench/viewer_panel.dart`
- Modify: `lib/ui/workbench_copy.dart`
- Modify: `test/ui/workbench/workbench_test_support.dart`
- Modify: `test/ui/workbench/workbench_shell_test.dart`
- Modify: `test/ui/workbench/canvas_overlay_test.dart`

**Interfaces:**
- Consumes: `missingSourceCount`, `selectedSourceAvailability`, and relink methods from Task 4.
- Consumes: existing `ImageImportPicker.pickImageFiles/pickImageFolder` for reconnect input.

- [ ] **Step 1: Write failing missing-source UI tests**

Create a project with one `confirmed` image pointing to a missing path, refresh availability, and assert:

```dart
expect(find.byKey(const ValueKey('missing-source-banner')), findsOneWidget);
expect(find.text('원본 이미지 1개를 찾을 수 없습니다'), findsOneWidget);
expect(find.text('라벨링 데이터는 보존되어 있습니다'), findsOneWidget);
expect(find.byKey(const ValueKey('relink-source-files')), findsOneWidget);
expect(find.byKey(const ValueKey('relink-source-folder')), findsOneWidget);
expect(controller.project!.images.single.status, ImageStatus.confirmed);
```

Use a fake image picker to reconnect by files and by folder in separate tests. Expect a summary such as `1개 연결 · 0개 미해결 · 0개 중복 후보` and expect the missing viewer state to disappear.

- [ ] **Step 2: Run workbench tests and verify failure**

```powershell
& C:\tools\flutter\bin\flutter.bat test test\ui\workbench\workbench_shell_test.dart test\ui\workbench\canvas_overlay_test.dart -r expanded
```

Expected: FAIL because no banner or reconnect actions exist.

- [ ] **Step 3: Add banner and reconnect handlers**

Import `../../project/source_relink_service.dart` from the workbench library file so its part files can use `SourceAvailability` and `SourceRelinkResult`.

In the body `Column`, insert the banner before the main `Expanded` row:

```dart
if (controller.missingSourceCount > 0)
  _MissingSourceBanner(
    count: controller.missingSourceCount,
    busy: controller.projectActivity == ProjectActivity.validating,
    onRelinkFiles: () => _relinkSourceFiles(context),
    onRelinkFolder: () => _relinkSourceFolder(context),
  ),
```

Implement handlers:

```dart
Future<void> _relinkSourceFiles(BuildContext context) async {
  final paths = await imageImportPicker.pickImageFiles();
  if (paths.isEmpty) return;
  final result = paths.length == 1 &&
          controller.selectedSourceAvailability == SourceAvailability.missing
      ? await controller.relinkSelectedSourceFile(paths.single)
      : await controller.relinkSourceFiles(paths);
  if (context.mounted) _showRelinkSummary(context, result);
}

Future<void> _relinkSourceFolder(BuildContext context) async {
  final path = await imageImportPicker.pickImageFolder();
  if (path == null) return;
  final result = await controller.relinkSourceFolder(path);
  if (context.mounted) _showRelinkSummary(context, result);
}
```

The banner must use the approved copy and remain compact at 1280×720. Disable both buttons only while validation/relink is running.

When one file is chosen while a missing image is selected, the handler targets that image only. This is the explicit escape hatch for ambiguous same-name/same-size images; selecting multiple files continues to match across all missing images.

- [ ] **Step 4: Prevent the viewer from trying to paint a missing file**

In `_ViewerPanelState._buildSelectedImage`, before toolbar/image construction, return a `_MissingSelectedSource` surface when `selectedSourceAvailability == SourceAvailability.missing`. Show the original path and the preservation copy; do not alter the inspector or box list.

Add copy helpers:

```dart
static String missingSourceCount(int count) => '원본 이미지 $count개를 찾을 수 없습니다';
static const labelingDataPreserved = '라벨링 데이터는 보존되어 있습니다.';
static const relinkFiles = '파일로 다시 연결';
static const relinkFolder = '폴더로 다시 연결';
static String relinkSummary({
  required int matched,
  required int unresolved,
  required int ambiguous,
}) => '$matched개 연결 · $unresolved개 미해결 · $ambiguous개 중복 후보';
```

`_showRelinkSummary` passes `result.matchedCount`, `result.unresolvedImageIds.length`, and `result.ambiguousImageIds.length` to this copy helper so `workbench_copy.dart` does not depend on project services.

- [ ] **Step 5: Run tests at 1280×720 and normal size**

```powershell
& C:\tools\flutter\bin\flutter.bat test test\ui\workbench\workbench_shell_test.dart test\ui\workbench\canvas_overlay_test.dart -r expanded
```

Expected: PASS, no overflow exception, both reconnect actions reachable.

- [ ] **Step 6: Commit reconnect UI**

```powershell
git add lib/ui/workbench/workbench_screen.dart lib/ui/workbench/workbench_feedback.dart lib/ui/workbench/viewer_panel.dart lib/ui/workbench_copy.dart test/ui/workbench/workbench_test_support.dart test/ui/workbench/workbench_shell_test.dart test/ui/workbench/canvas_overlay_test.dart
git commit -m "feat: guide missing image reconnection"
```

---

### Task 7: Confirmed Box Visibility

**Files:**
- Modify: `lib/ui/workbench/image_canvas.dart`
- Modify: `test/ui/workbench/canvas_overlay_test.dart`

**Interfaces:**
- No new public API.
- Preserves: white border, colored label badge, selected resize handles.

- [ ] **Step 1: Write a failing decoration test**

Extend the existing labeled-box test:

```dart
final decoration = box.decoration! as BoxDecoration;
expect(decoration.border!.top.color, Colors.white);
expect(decoration.border!.top.width, 2);
expect(decoration.color, Colors.transparent);
expect(decoration.boxShadow, isNull);
```

Add a selected labeled-box assertion that border width is 3 and eight resize handles still render.

- [ ] **Step 2: Run the canvas test and verify failure**

```powershell
& C:\tools\flutter\bin\flutter.bat test test\ui\workbench\canvas_overlay_test.dart -r expanded
```

Expected: FAIL because labeled boxes currently have a translucent fill and `Color(0xcc000000)` shadow.

- [ ] **Step 3: Remove only labeled fill and black shadow**

In `_BoxOverlay.build`:

```dart
final isLabeled = box.status == BoxStatus.labeled && box.labelId != null;
final color = box.requiresLabelReview
    ? WorkbenchPalette.danger
    : isLabeled
        ? Colors.white
        : _automaticBoxColor;
final fillColor = isLabeled
    ? Colors.transparent
    : color.withAlpha(fillAlpha);
```

Use `color: fillColor` and remove the labeled `boxShadow` branch entirely. Do not change the badge background color, warning color, white border, selected border width, or resize handles.

- [ ] **Step 4: Run canvas tests**

```powershell
& C:\tools\flutter\bin\flutter.bat test test\ui\workbench\canvas_overlay_test.dart -r expanded
```

Expected: PASS.

- [ ] **Step 5: Commit visibility fix**

```powershell
git add lib/ui/workbench/image_canvas.dart test/ui/workbench/canvas_overlay_test.dart
git commit -m "fix: keep confirmed boxes visually clear"
```

---

### Task 8: Explicit Review Candidate Selection And Application

**Files:**
- Modify: `lib/ui/app_controller.dart`
- Modify: `lib/ui/workbench/workbench_screen.dart`
- Modify: `lib/ui/workbench/inspector_panel.dart`
- Modify: `lib/ui/workbench_copy.dart`
- Modify: `test/ui/app_controller_auto_box_test.dart`
- Modify: `test/ui/workbench/inspector_panel_test.dart`
- Modify: `test/ui/workbench/center_toolbar_test.dart`

**Interfaces:**
- Produces: `selectedReviewCandidateLabelId`, `selectReviewCandidate`, `moveReviewCandidate`, `applySelectedReviewCandidate`.
- Consumed by: interactive candidate rows and workbench key handler.

- [ ] **Step 1: Write failing controller candidate-selection tests**

Use a review box with candidates `labelId 1` and `labelId 2`:

```dart
expect(controller.selectedReviewCandidateLabelId, 1);
controller.moveReviewCandidate(1);
expect(controller.selectedReviewCandidateLabelId, 2);
controller.applySelectedReviewCandidate();
expect(controller.project!.images.first.boxes.first.labelId, 2);
expect(controller.project!.images.first.boxes.first.labelSource, LabelSource.user);
expect(controller.selectedBoxId, 'visual-next-unlabeled-box');
```

Also test that selecting another review box resets to its first candidate and that an invalid label ID is ignored.

- [ ] **Step 2: Write failing inspector and keyboard tests**

Assert:

```dart
expect(find.text('추천 라벨을 선택한 뒤 Enter를 누르세요'), findsOneWidget);
expect(find.byKey(const ValueKey('review-candidate-1')), findsOneWidget);
expect(find.byKey(const ValueKey('review-candidate-2')), findsOneWidget);
expect(find.byKey(const ValueKey('apply-review-candidate')), findsOneWidget);
```

Tap candidate 2, press Enter, and expect label 2. Reload the fixture, press ArrowDown then Enter, and expect label 2. Add a 1280×720 test verifying the apply button can be scrolled into view and has no overflow.

- [ ] **Step 3: Run focused tests and verify failure**

```powershell
& C:\tools\flutter\bin\flutter.bat test test\ui\app_controller_auto_box_test.dart test\ui\workbench\inspector_panel_test.dart test\ui\workbench\center_toolbar_test.dart -r expanded
```

Expected: FAIL because candidates are non-interactive and Enter always applies `suggestedLabelId`.

- [ ] **Step 4: Implement controller candidate state**

Add:

```dart
int? _selectedReviewCandidateLabelId;
int? get selectedReviewCandidateLabelId => _selectedReviewCandidateLabelId;

List<LabelCandidate> get selectedReviewCandidates {
  final candidates = selectedBox?.automation?.candidates ?? const <LabelCandidate>[];
  final validIds = _project?.labels.map((label) => label.id).toSet() ?? const <int>{};
  return [for (final candidate in candidates) if (validIds.contains(candidate.labelId)) candidate];
}

void selectReviewCandidate(int labelId) {
  if (!selectedReviewCandidates.any((candidate) => candidate.labelId == labelId)) return;
  _selectedReviewCandidateLabelId = labelId;
  notifyListeners();
}

void moveReviewCandidate(int delta) {
  final candidates = selectedReviewCandidates;
  if (candidates.isEmpty) return;
  final current = candidates.indexWhere(
    (candidate) => candidate.labelId == _selectedReviewCandidateLabelId,
  );
  final next = ((current < 0 ? 0 : current) + delta)
      .clamp(0, candidates.length - 1)
      .toInt();
  selectReviewCandidate(candidates[next].labelId);
}

void applySelectedReviewCandidate() {
  final labelId = _selectedReviewCandidateLabelId;
  if (labelId == null) return;
  assignSelectedBoxLabel(labelId);
}

void _syncSelectedReviewCandidate() {
  final candidates = selectedReviewCandidates;
  if (candidates.isNotEmpty) {
    _selectedReviewCandidateLabelId = candidates.first.labelId;
    return;
  }
  final suggestion = selectedBox?.automation?.suggestedLabelId;
  final validSuggestion = suggestion != null &&
      (_project?.labels.any((label) => label.id == suggestion) ?? false);
  _selectedReviewCandidateLabelId = validSuggestion ? suggestion : null;
}
```

Call `_syncSelectedReviewCandidate()` after `loadProject`, `selectBox`, selection repair, and after `assignSelectedBoxLabel` advances to the next box. Keep `acceptSelectedSuggestedLabel` as this compatibility wrapper:

```dart
void acceptSelectedSuggestedLabel() {
  final suggestion = selectedBox?.automation?.suggestedLabelId;
  if (selectedBox?.requiresLabelReview != true || suggestion == null) return;
  assignSelectedBoxLabel(suggestion);
}
```

- [ ] **Step 5: Make inspector candidates interactive and unclipped**

Move selected details and `_SidebarBoxList` into the same `SingleChildScrollView` in the work tab so the completion footer remains fixed and details can grow. Remove the `ConstrainedBox(maxHeight: 126)` and nested details scroll.

Pass `controller` to `_SelectedBoxDetails` and `_ReviewEvidence`. Render each candidate as an `InkWell`/radio-like row:

```dart
InkWell(
  key: ValueKey('review-candidate-${candidate.labelId}'),
  onTap: () => controller.selectReviewCandidate(candidate.labelId),
  child: Row(
    children: [
      Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        size: 18,
      ),
      const SizedBox(width: 6),
      Expanded(child: Text(label?.name ?? '#${candidate.labelId}')),
      Text('${(candidate.score * 100).round()}%'),
    ],
  ),
)
```

Above rows, show `WorkbenchCopy.chooseReviewCandidate`; below rows, add:

```dart
FilledButton.icon(
  key: const ValueKey('apply-review-candidate'),
  onPressed: controller.selectedReviewCandidateLabelId == null
      ? null
      : controller.applySelectedReviewCandidate,
  icon: const Icon(Icons.keyboard_return, size: 16),
  label: const Text(WorkbenchCopy.applyReviewCandidate),
)
```

If no candidates exist, render `추천 결과 없음` and `빠른 라벨 버튼 또는 단축키로 라벨을 선택하세요.`.

Add the exact copy constants:

```dart
static const chooseReviewCandidate = '추천 라벨을 선택한 뒤 Enter를 누르세요';
static const applyReviewCandidate = '선택한 라벨 적용 · Enter';
static const noReviewCandidates = '추천 결과 없음';
static const noReviewCandidatesHint = '빠른 라벨 버튼 또는 단축키로 라벨을 선택하세요.';
static const labelSelectionRequired = '라벨 선택 필요';
static const suggestionReviewRequired = '추천 검토 필요';
```

- [ ] **Step 6: Route Up/Down/Enter keys**

Before quick-label shortcut handling in `_handleWorkbenchKey`:

```dart
if (controller.selectedBox?.requiresLabelReview == true) {
  if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
    controller.moveReviewCandidate(-1);
    return KeyEventResult.handled;
  }
  if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
    controller.moveReviewCandidate(1);
    return KeyEventResult.handled;
  }
  if (event.logicalKey == LogicalKeyboardKey.enter) {
    controller.applySelectedReviewCandidate();
    return KeyEventResult.handled;
  }
}
```

Update sidebar status copy: normal proposal `라벨 선택 필요`, review proposal `추천 검토 필요`.

- [ ] **Step 7: Run focused tests**

```powershell
& C:\tools\flutter\bin\flutter.bat test test\ui\app_controller_auto_box_test.dart test\ui\workbench\inspector_panel_test.dart test\ui\workbench\center_toolbar_test.dart -r expanded
```

Expected: PASS, including candidate 2 application and next visual box selection.

- [ ] **Step 8: Commit candidate UX**

```powershell
git add lib/ui/app_controller.dart lib/ui/workbench/workbench_screen.dart lib/ui/workbench/inspector_panel.dart lib/ui/workbench_copy.dart test/ui/app_controller_auto_box_test.dart test/ui/workbench/inspector_panel_test.dart test/ui/workbench/center_toolbar_test.dart
git commit -m "feat: make label review candidates explicit"
```

---

### Task 9: End-To-End Transfer, Relink, Export, And Regression Verification

**Files:**
- Create: `test/integration/project_transfer_relink_test.dart`

**Interfaces:**
- Verifies all prior task interfaces together.

- [ ] **Step 1: Write the end-to-end integration test**

The test must:

```dart
// 1. Create a sender library/project with one confirmed labeled image and one
//    needsReview image with manual boxes stored out of visual order.
// 2. Save a snapshot and assert no image bytes are created beside it.
// 3. Import into a receiver library while original absolute paths still exist;
//    expect zero missing sources and identical image IDs, category IDs, boxes,
//    confirmation states, and automation metadata.
// 4. Move fixture images to a new folder, refresh availability, and expect both
//    sources missing without ImageStatus changes.
// 5. Reconnect one image through relinkSourceFiles and the other through
//    relinkSourceFolder; expect zero missing sources.
// 6. Save/reopen the receiver project and export COCO.
// 7. Assert COCO image IDs, category IDs, and bbox arrays equal the sender's.
// 8. Assign a label to visual #1 and assert visual #2 becomes selected.
```

- [ ] **Step 2: Run the integration test and fix only in-scope defects**

```powershell
& C:\tools\flutter\bin\flutter.bat test test\integration\project_transfer_relink_test.dart -r expanded
```

Expected: PASS. A failure returns execution to the owning earlier task: add a focused regression test to that task's listed test file, make the minimal in-scope correction, rerun that task, and then rerun this integration test.

- [ ] **Step 3: Run all affected Dart tests**

```powershell
& C:\tools\flutter\bin\flutter.bat test test\annotation test\project test\ui test\integration -r expanded
```

Expected: all tests PASS. Pay special attention to the existing `validateSourceFiles`, project-home, inspector overflow, quick-label, and canvas overlay suites.

- [ ] **Step 4: Run static analysis and formatting verification**

```powershell
& C:\tools\flutter\bin\dart.bat format --output=none --set-exit-if-changed lib test
& C:\tools\flutter\bin\flutter.bat analyze
git diff --check
```

Expected: formatter exits 0, analyzer has no issue, and `git diff --check` is clean.

- [ ] **Step 5: Commit the integration coverage**

```powershell
git add test/integration/project_transfer_relink_test.dart
git commit -m "test: cover portable project handoff"
```

- [ ] **Step 6: Review final scope and working tree**

```powershell
git status --short
git log --oneline -10
```

Expected: only the user's pre-existing unrelated detector/packaging changes remain unstaged; the feature is represented by the task commits above.

---

## Manual Acceptance Checklist

- [ ] On PC A, open a project with both file-added and folder-added images.
- [ ] Use `프로젝트 파일 저장`; confirm the generated `.bbox.json` is small and contains no image files.
- [ ] On PC B with identical absolute image paths, import the project and confirm no reconnect prompt appears.
- [ ] On PC B without those paths, confirm `파일로 다시 연결` and `폴더로 다시 연결` are both visible.
- [ ] Reconnect only part of the project and confirm the success/unresolved/ambiguous summary is accurate.
- [ ] Confirm previously completed images remain completed before and after relink.
- [ ] Draw five manual boxes out of insertion order, start at visual #1, and verify labels advance #1→#5.
- [ ] Confirm completed boxes have white borders, transparent interiors, and no black shadow.
- [ ] Select a review-required box, choose a non-first candidate by mouse and by Down arrow, and apply it with Enter and the button.
- [ ] At 1280×720, verify the reconnect actions and candidate apply button remain reachable without overflow.
- [ ] Export COCO after handoff and compare IDs and bbox values with the sender project.

## Self-Review

- Spec coverage: snapshot save/import, existing-path-first behavior, file/folder relink, derived source availability, visual order, white confirmed borders, candidate interaction, error cases, and tests are each assigned to a task.
- Placeholder scan: every task names files, commands, expected results, APIs, and concrete code or exact behavioral rules.
- Type consistency: `BoxDisplayOrder`, `ProjectSnapshotService`, `SourceAvailability`, `SourceRelinkResult`, `ProjectTransferPicker`, and review-candidate controller APIs are defined before their consumers and use the same names throughout.
- Scope: image packaging, cloud collaboration, viewport persistence, and Undo history transfer remain excluded.
