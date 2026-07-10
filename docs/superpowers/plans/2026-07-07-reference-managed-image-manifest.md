# Reference-Managed Image Manifest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the project-wide image folder model with a reference-managed image manifest that supports adding individual files or folders, append imports, remove-from-project, loading states, and COCO export from image source paths.

**Architecture:** Move image location ownership from `AnnotationProject.imageFolderPath` to `AnnotatedImage.sourcePath`. Keep project JSON in the internal project library, but store only image references and annotations. Add explicit controller activity/import/viewer loading state so 6000-image projects never look frozen.

**Tech Stack:** Flutter desktop, Dart, `ChangeNotifier`, `dart:io`, `package:path`, `package:image`, existing detector/project/export modules, Flutter unit/widget/integration tests.

## Global Constraints

- Existing schema migration is out of scope; save and load schema version 2 only.
- Original images must not be modified, moved, copied, or deleted by normal project actions.
- Import is append-based; selecting a folder never replaces the existing image list.
- Folder selection is an input method only; projects are not connected to a single folder.
- MVP duplicate detection uses normalized absolute source path.
- Windows path comparison ignores case.
- Missing source files are recoverable image-level errors; existing annotations are preserved.
- COCO export includes only valid labeled boxes and never exports proposal boxes.
- Long operations expose loading/progress state and keep the UI responsive.
- Current workspace is not a Git repository and `git` is not on PATH; commit steps are intentionally omitted for this workspace.

---

## File Structure

- `C:\workspace\bbox\lib\annotation\models.dart`
  - Change project schema to version 2.
  - Remove `AnnotationProject.imageFolderPath`.
  - Replace `AnnotatedImage.relativePath` with `sourcePath`, `displayName`, and `importedFrom`.
- `C:\workspace\bbox\lib\project\project_store.dart`
  - Save/load schema version 2.
  - Reject non-v2 project files.
- `C:\workspace\bbox\lib\project\project_library.dart`
  - Remove image folder metadata and reconnect logic.
  - Keep project library index as project metadata only.
- `C:\workspace\bbox\lib\image_import\image_scanner.dart`
  - Add file-list scanning.
  - Return absolute normalized `sourcePath` plus display/import metadata.
- `C:\workspace\bbox\lib\ui\app_controller.dart`
  - Add append import APIs, import progress, project activity, viewer load state, duplicate skipping, remove image, source validation.
  - Remove reconnect-folder behavior.
- `C:\workspace\bbox\lib\ui\workbench_copy.dart`
  - Rename image folder copy to image add/remove/loading language.
- `C:\workspace\bbox\lib\ui\image_folder_path_dialog.dart`
  - Replace or repurpose as an add-images dialog if useful; otherwise remove from UI use.
- `C:\workspace\bbox\lib\ui\windows_dialog_service.dart`
  - Add image file picker if missing.
- `C:\workspace\bbox\lib\ui\workbench_screen.dart`
  - Replace `이미지 폴더` with `이미지 추가`.
  - Add file/folder import menu, progress surface, viewer loading state, remove-from-project action.
- `C:\workspace\bbox\lib\export\coco_exporter.dart`
  - Build COCO `file_name` from `displayName`, resolve collisions, handle missing source policy.
- Tests under `C:\workspace\bbox\test\...`
  - Rewrite affected tests to source-path model and add coverage for append import, loading, missing, remove, and export collisions.

---

### Task 1: Schema V2 Source Path Domain Model

**Files:**
- Modify: `C:\workspace\bbox\lib\annotation\models.dart`
- Modify: `C:\workspace\bbox\lib\project\project_store.dart`
- Modify: `C:\workspace\bbox\test\project\project_store_test.dart`

**Interfaces:**
- Produces: `AnnotatedImage(sourcePath, displayName, importedFrom, ...)`
- Produces: `AnnotationProject` without `imageFolderPath`
- Produces: `ProjectStore.currentSchemaVersion == 2`

- [ ] **Step 1: Write the failing save/load test**

Replace the first `ProjectStore` test with source-path assertions:

```dart
test('saves and loads schema 2 project state with source paths', () async {
  final tempDir = await Directory.systemTemp.createTemp(
    'bbox_project_store_test',
  );
  addTearDown(() => tempDir.delete(recursive: true));
  final projectPath =
      '${tempDir.path}${Platform.pathSeparator}project.bbox.json';
  final sourcePath =
      '${tempDir.path}${Platform.pathSeparator}이미지 폴더'
      '${Platform.pathSeparator}테스트 이미지.jpg';
  final project = AnnotationProject.empty(name: '검수 프로젝트').copyWith(
    status: ProjectStatus.ready,
    labels: const [
      LabelClass(id: 1, name: '사람', color: 0xffe64a19),
    ],
    images: [
      AnnotatedImage(
        id: 1,
        sourcePath: sourcePath,
        displayName: '테스트 이미지.jpg',
        importedFrom: '${tempDir.path}${Platform.pathSeparator}이미지 폴더',
        width: 640,
        height: 480,
        status: ImageStatus.confirmed,
        boxes: const [
          BoundingBox(
            id: 'box-1',
            x: 10,
            y: 20,
            width: 30,
            height: 40,
            status: BoxStatus.labeled,
            labelId: 1,
            confidence: 0.8,
          ),
        ],
      ),
    ],
  );

  final saved = await ProjectStore.save(project, projectPath);
  final raw = await File(projectPath).readAsString(encoding: utf8);
  final json = jsonDecode(raw) as Map<String, Object?>;
  final loaded = await ProjectStore.load(projectPath);

  expect(saved.projectFilePath, projectPath);
  expect(json['schemaVersion'], 2);
  expect(json.containsKey('imageFolderPath'), isFalse);
  expect(loaded.name, '검수 프로젝트');
  expect(loaded.images.single.sourcePath, sourcePath);
  expect(loaded.images.single.displayName, '테스트 이미지.jpg');
  expect(loaded.images.single.importedFrom, endsWith('이미지 폴더'));
  expect(loaded.images.single.boxes.single.labelId, 1);
});
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run: `flutter test test/project/project_store_test.dart -r compact`

Expected: FAIL because `AnnotatedImage.sourcePath`, `displayName`, and `importedFrom` do not exist.

- [ ] **Step 3: Update `AnnotatedImage`**

In `models.dart`, replace `relativePath` with the new fields:

```dart
class AnnotatedImage {
  const AnnotatedImage({
    required this.id,
    required this.sourcePath,
    required this.displayName,
    this.importedFrom,
    required this.width,
    required this.height,
    required this.status,
    this.boxes = const [],
    this.errorMessage,
  });

  final int id;
  final String sourcePath;
  final String displayName;
  final String? importedFrom;
  final int width;
  final int height;
  final ImageStatus status;
  final List<BoundingBox> boxes;
  final String? errorMessage;
}
```

Update `copyWith`, `toJson`, and `fromJson` to use:

```dart
'sourcePath': sourcePath,
'displayName': displayName,
'importedFrom': importedFrom,
```

and parse:

```dart
sourcePath: json['sourcePath'] as String,
displayName: json['displayName'] as String,
importedFrom: json['importedFrom'] as String?,
```

- [ ] **Step 4: Remove project image folder storage**

In `AnnotationProject`, delete:

```dart
this.imageFolderPath,
final String? imageFolderPath;
Object? imageFolderPath = _unchanged,
'imageFolderPath': imageFolderPath,
imageFolderPath: json['imageFolderPath'] as String?,
```

Update constructor, `copyWith`, `toJson`, and `fromJson` so no image folder value is accepted or emitted.

- [ ] **Step 5: Move project store to schema version 2**

In `project_store.dart`, set:

```dart
static const int currentSchemaVersion = 2;
```

Keep the existing unsupported-version exception behavior.

- [ ] **Step 6: Run the focused test and verify it passes**

Run: `flutter test test/project/project_store_test.dart -r compact`

Expected: PASS.

---

### Task 2: Source-Path Image Scanner

**Files:**
- Modify: `C:\workspace\bbox\lib\image_import\image_scanner.dart`
- Modify: `C:\workspace\bbox\test\image_import\image_scanner_test.dart`

**Interfaces:**
- Consumes: `AnnotatedImage.sourcePath` model from Task 1.
- Produces: `ImageScanner.scanFiles(List<String> filePaths, {String? importedFrom})`
- Produces: `ScannedImage.sourcePath`, `displayName`, `importedFrom`

- [ ] **Step 1: Write scanner tests for files and folders**

Add these tests:

```dart
test('scanFiles reads supported images and records source metadata', () async {
  final tempDir = await Directory.systemTemp.createTemp('bbox_scan_files');
  addTearDown(() => tempDir.delete(recursive: true));
  final imageFile = File('${tempDir.path}${Platform.pathSeparator}한글 샘플.jpg');
  await imageFile.writeAsBytes(img.encodeJpg(img.Image(width: 32, height: 24)));

  final scanned = await ImageScanner.scanFiles(
    [imageFile.path],
    importedFrom: tempDir.path,
  );

  expect(scanned, hasLength(1));
  expect(scanned.single.sourcePath, imageFile.absolute.path);
  expect(scanned.single.displayName, '한글 샘플.jpg');
  expect(scanned.single.importedFrom, tempDir.path);
  expect(scanned.single.width, 32);
  expect(scanned.single.height, 24);
});

test('scanFolder returns absolute source paths from nested folders', () async {
  final tempDir = await Directory.systemTemp.createTemp('bbox_scan_folder');
  addTearDown(() => tempDir.delete(recursive: true));
  final nested = Directory('${tempDir.path}${Platform.pathSeparator}nested');
  await nested.create();
  final imageFile = File('${nested.path}${Platform.pathSeparator}a.png');
  await imageFile.writeAsBytes(img.encodePng(img.Image(width: 12, height: 10)));

  final scanned = await ImageScanner.scanFolder(tempDir.path);

  expect(scanned.single.sourcePath, imageFile.absolute.path);
  expect(scanned.single.displayName, 'a.png');
  expect(scanned.single.importedFrom, tempDir.path);
});
```

- [ ] **Step 2: Run scanner tests and verify they fail**

Run: `flutter test test/image_import/image_scanner_test.dart -r compact`

Expected: FAIL because scanner output still uses `absolutePath` and `relativePath`.

- [ ] **Step 3: Update `ScannedImage`**

Change the scanner model:

```dart
class ScannedImage {
  const ScannedImage({
    required this.sourcePath,
    required this.displayName,
    this.importedFrom,
    required this.width,
    required this.height,
    this.errorMessage,
  });

  final String sourcePath;
  final String displayName;
  final String? importedFrom;
  final int width;
  final int height;
  final String? errorMessage;

  bool get hasError => errorMessage != null;
}
```

- [ ] **Step 4: Add `scanFiles` and update `scanFolder`**

Implement:

```dart
static Future<List<ScannedImage>> scanFiles(
  List<String> filePaths, {
  String? importedFrom,
}) async {
  final files = filePaths
      .where(isSupportedImagePath)
      .map((path) => File(path).absolute)
      .toList();
  files.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
  final images = <ScannedImage>[];
  for (final file in files) {
    images.add(await _scanFile(file, importedFrom: importedFrom));
  }
  return images;
}

static Future<List<ScannedImage>> scanFolder(String folderPath) async {
  final root = Directory(folderPath);
  if (!await root.exists()) {
    throw FileSystemException('Image folder does not exist.', folderPath);
  }
  final files = await root
      .list(recursive: true, followLinks: false)
      .where((entity) => entity is File && isSupportedImagePath(entity.path))
      .cast<File>()
      .toList();
  return scanFiles(files.map((file) => file.path).toList(), importedFrom: root.path);
}
```

Update `_scanFile` to emit `sourcePath: file.absolute.path` and `displayName: p.basename(file.path)`.

- [ ] **Step 5: Run scanner tests**

Run: `flutter test test/image_import/image_scanner_test.dart -r compact`

Expected: PASS.

---

### Task 3: Project Library Without Folder Reconnect

**Files:**
- Modify: `C:\workspace\bbox\lib\project\project_library.dart`
- Modify: `C:\workspace\bbox\test\project\project_library_test.dart`
- Modify: `C:\workspace\bbox\test\support\memory_project_library.dart`

**Interfaces:**
- Consumes: `AnnotationProject` without `imageFolderPath`.
- Produces: `ProjectLibraryEntry` without `imageFolderPath`.
- Removes: `ReconnectImageFolderResult`, `isImageFolderMissing`, `reconnectImageFolder`.

- [ ] **Step 1: Rewrite library metadata tests**

Change metadata refresh expectations:

```dart
test('refreshes index metadata from saved project state', () async {
  final created = await library.createProject('Dataset');
  final updated = created.copyWith(
    images: const [
      AnnotatedImage(
        id: 1,
        sourcePath: r'D:\images\a.jpg',
        displayName: 'a.jpg',
        width: 100,
        height: 80,
        status: ImageStatus.confirmed,
      ),
      AnnotatedImage(
        id: 2,
        sourcePath: r'D:\images\broken.jpg',
        displayName: 'broken.jpg',
        width: 0,
        height: 0,
        status: ImageStatus.error,
        errorMessage: 'decode failed',
      ),
    ],
  );
  await ProjectStore.save(updated, updated.projectFilePath!);

  await library.refreshEntry(updated);

  final entry = (await library.listProjects()).single;
  expect(entry.imageCount, 2);
  expect(entry.confirmedImageCount, 1);
  expect(entry.errorImageCount, 1);
});
```

Delete reconnect-specific tests from `project_library_test.dart`.

- [ ] **Step 2: Run library tests and verify they fail**

Run: `flutter test test/project/project_library_test.dart -r compact`

Expected: FAIL because entry and reconnect APIs still refer to image folders.

- [ ] **Step 3: Remove folder metadata from `ProjectLibraryEntry`**

Delete `imageFolderPath` field, constructor parameter, JSON entry, and parser entry.

Update `_entryFromProject` to construct:

```dart
return ProjectLibraryEntry(
  id: id,
  name: project.name,
  projectFilePath: project.projectFilePath!,
  createdAt: createdAt.toUtc(),
  updatedAt: updatedAt.toUtc(),
  imageCount: project.images.length,
  confirmedImageCount: project.images
      .where((image) => image.status == ImageStatus.confirmed)
      .length,
  errorImageCount: project.images
      .where((image) => image.status == ImageStatus.error)
      .length,
);
```

- [ ] **Step 4: Remove reconnect APIs**

Delete these from `project_library.dart` and `memory_project_library.dart`:

```dart
class ReconnectImageFolderResult
bool isImageFolderMissing(AnnotationProject project)
Future<ReconnectImageFolderResult> reconnectImageFolder(...)
```

- [ ] **Step 5: Run library tests**

Run: `flutter test test/project/project_library_test.dart -r compact`

Expected: PASS.

---

### Task 4: App Controller Append Import, Activity, Removal, Missing Validation

**Files:**
- Modify: `C:\workspace\bbox\lib\ui\app_controller.dart`
- Modify: `C:\workspace\bbox\test\ui\app_controller_test.dart`
- Modify: `C:\workspace\bbox\test\ui\app_controller_library_test.dart`

**Interfaces:**
- Consumes: `ImageScanner.scanFiles`, `ImageScanner.scanFolder`.
- Produces: `ProjectActivity`, `ImageImportProgress`, `ImageViewLoadState`.
- Produces: `addImageFiles`, `addImagesFromFolder`, `removeImageFromProject`, `validateSourceFiles`.

- [ ] **Step 1: Add controller tests for append import and duplicate skip**

Add to `app_controller_test.dart`:

```dart
test('adds images from folders by appending and skipping duplicate paths', () async {
  final tempDir = await Directory.systemTemp.createTemp('bbox_append_import');
  addTearDown(() => tempDir.delete(recursive: true));
  final first = Directory('${tempDir.path}${Platform.pathSeparator}first');
  final second = Directory('${tempDir.path}${Platform.pathSeparator}second');
  await first.create();
  await second.create();
  final a = File('${first.path}${Platform.pathSeparator}a.jpg');
  final b = File('${second.path}${Platform.pathSeparator}b.jpg');
  await a.writeAsBytes(img.encodeJpg(img.Image(width: 20, height: 10)));
  await b.writeAsBytes(img.encodeJpg(img.Image(width: 30, height: 15)));

  final controller = AppController();
  controller.createProject('demo');

  await controller.addImagesFromFolder(first.path, detector: const DummyDetector());
  await controller.addImagesFromFolder(second.path, detector: const DummyDetector());
  await controller.addImagesFromFolder(first.path, detector: const DummyDetector());

  expect(controller.project!.images, hasLength(2));
  expect(controller.project!.images.map((image) => image.displayName), ['a.jpg', 'b.jpg']);
  expect(controller.lastImportProgress?.skippedDuplicateCount, 1);
});
```

- [ ] **Step 2: Add controller test for remove without deleting source**

```dart
test('removes an image from the project without deleting the source file', () async {
  final tempDir = await Directory.systemTemp.createTemp('bbox_remove_image');
  addTearDown(() => tempDir.delete(recursive: true));
  final file = File('${tempDir.path}${Platform.pathSeparator}a.jpg');
  await file.writeAsBytes(img.encodeJpg(img.Image(width: 20, height: 10)));

  final controller = AppController();
  controller.createProject('demo');
  await controller.addImageFiles([file.path], detector: const DummyDetector());

  controller.removeImageFromProject(controller.project!.images.single.id);

  expect(controller.project!.images, isEmpty);
  expect(await file.exists(), isTrue);
});
```

- [ ] **Step 3: Add controller test for missing source validation**

```dart
test('validates missing source files without deleting annotations', () async {
  final controller = AppController();
  controller.loadProject(
    AnnotationProject.empty(name: 'demo').copyWith(
      images: const [
        AnnotatedImage(
          id: 1,
          sourcePath: r'C:\missing\a.jpg',
          displayName: 'a.jpg',
          width: 100,
          height: 80,
          status: ImageStatus.needsReview,
          boxes: [
            BoundingBox(
              id: 'box-1',
              x: 1,
              y: 1,
              width: 10,
              height: 10,
              status: BoxStatus.proposal,
            ),
          ],
        ),
      ],
    ),
  );

  final missing = await controller.validateSourceFiles();

  expect(missing, [1]);
  expect(controller.project!.images.single.status, ImageStatus.error);
  expect(controller.project!.images.single.boxes.single.id, 'box-1');
});
```

- [ ] **Step 4: Run controller tests and verify they fail**

Run: `flutter test test/ui/app_controller_test.dart test/ui/app_controller_library_test.dart -r compact`

Expected: FAIL because the new controller APIs and fields do not exist.

- [ ] **Step 5: Add state types and getters**

In `app_controller.dart`, add:

```dart
enum ProjectActivity {
  idle,
  openingProject,
  importingImages,
  loadingImage,
  validatingSources,
  exportingCoco,
}

class ImageImportProgress {
  const ImageImportProgress({
    required this.discoveredCount,
    required this.processedCount,
    required this.addedCount,
    required this.skippedDuplicateCount,
    required this.failedCount,
    this.currentFileName,
    this.isCancelling = false,
  });

  final int discoveredCount;
  final int processedCount;
  final int addedCount;
  final int skippedDuplicateCount;
  final int failedCount;
  final String? currentFileName;
  final bool isCancelling;
}

class ImageViewLoadState {
  const ImageViewLoadState({
    this.imageId,
    this.isLoading = false,
    this.error,
  });

  final int? imageId;
  final bool isLoading;
  final Object? error;
}
```

Add private fields and getters:

```dart
ProjectActivity _activity = ProjectActivity.idle;
ImageImportProgress? _lastImportProgress;
ImageViewLoadState _imageViewLoadState = const ImageViewLoadState();

ProjectActivity get activity => _activity;
ImageImportProgress? get lastImportProgress => _lastImportProgress;
ImageViewLoadState get imageViewLoadState => _imageViewLoadState;
```

- [ ] **Step 6: Implement append import APIs**

Replace `importImagesFromFolder` with wrappers and a shared import method:

```dart
Future<void> addImageFiles(
  List<String> filePaths, {
  Detector? detector,
}) async {
  final scanned = await ImageScanner.scanFiles(filePaths);
  await _addScannedImages(scanned, detector: detector);
}

Future<void> addImagesFromFolder(
  String folderPath, {
  Detector? detector,
}) async {
  final scanned = await ImageScanner.scanFolder(folderPath);
  await _addScannedImages(scanned, detector: detector);
}
```

Implement `_addScannedImages` with path-based duplicate detection:

```dart
Future<void> _addScannedImages(
  List<ScannedImage> scannedImages, {
  Detector? detector,
}) async {
  final activeDetector = detector ?? _defaultDetectorFactory();
  final project = _requireProject();
  _recordUndo();
  _activity = ProjectActivity.importingImages;
  _project = project.copyWith(status: ProjectStatus.scanning);
  notifyListeners();

  final existingKeys = project.images
      .map((image) => _sourcePathKey(image.sourcePath))
      .toSet();
  final importedImages = <AnnotatedImage>[];
  var nextId = project.nextImageId;
  var skipped = 0;
  var failed = 0;

  for (final scanned in scannedImages) {
    final key = _sourcePathKey(scanned.sourcePath);
    if (existingKeys.contains(key)) {
      skipped += 1;
      continue;
    }
    existingKeys.add(key);
    _lastImportProgress = ImageImportProgress(
      discoveredCount: scannedImages.length,
      processedCount: importedImages.length + skipped + failed,
      addedCount: importedImages.length,
      skippedDuplicateCount: skipped,
      failedCount: failed,
      currentFileName: scanned.displayName,
    );
    notifyListeners();

    if (scanned.hasError) {
      failed += 1;
      importedImages.add(_imageFromScan(nextId++, scanned, ImageStatus.error));
      continue;
    }

    final detectingImage = _imageFromScan(nextId++, scanned, ImageStatus.detecting);
    final result = await activeDetector.detect(
      detectingImage,
      imagePath: scanned.sourcePath,
    );
    importedImages.add(
      detectingImage.copyWith(
        status: result.errorMessage == null
            ? ImageStatus.needsReview
            : ImageStatus.error,
        boxes: result.boxes,
        errorMessage: result.errorMessage,
      ),
    );
  }

  _project = _requireProject().copyWith(
    status: ProjectStatus.ready,
    images: [..._requireProject().images, ...importedImages],
    detectorName: activeDetector.name,
  );
  _selectedImageId ??= importedImages.isEmpty ? null : importedImages.first.id;
  _selectedBoxId = null;
  _lastImportProgress = ImageImportProgress(
    discoveredCount: scannedImages.length,
    processedCount: scannedImages.length,
    addedCount: importedImages.length,
    skippedDuplicateCount: skipped,
    failedCount: failed,
  );
  _activity = ProjectActivity.idle;
  _scheduleAutoSave();
  notifyListeners();
}
```

Add helpers:

```dart
String _sourcePathKey(String path) {
  final normalized = p.normalize(File(path).absolute.path);
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

AnnotatedImage _imageFromScan(
  int id,
  ScannedImage scanned,
  ImageStatus status,
) {
  return AnnotatedImage(
    id: id,
    sourcePath: scanned.sourcePath,
    displayName: scanned.displayName,
    importedFrom: scanned.importedFrom,
    width: scanned.width,
    height: scanned.height,
    status: status,
    errorMessage: scanned.errorMessage,
  );
}
```

- [ ] **Step 7: Implement remove and source validation**

Add:

```dart
void removeImageFromProject(int imageId) {
  final project = _requireProject();
  if (!project.images.any((image) => image.id == imageId)) {
    return;
  }
  _recordUndo();
  _project = project.copyWith(
    images: [
      for (final image in project.images)
        if (image.id != imageId) image,
    ],
  );
  _repairSelection();
  _scheduleAutoSave();
  notifyListeners();
}

Future<List<int>> validateSourceFiles() async {
  final project = _requireProject();
  _activity = ProjectActivity.validatingSources;
  notifyListeners();
  final missing = <int>[];
  final updatedImages = <AnnotatedImage>[];
  for (final image in project.images) {
    if (await File(image.sourcePath).exists()) {
      updatedImages.add(image);
    } else {
      missing.add(image.id);
      updatedImages.add(
        image.copyWith(
          status: ImageStatus.error,
          errorMessage: 'Source image file is missing.',
        ),
      );
    }
  }
  _project = project.copyWith(images: updatedImages);
  _activity = ProjectActivity.idle;
  _scheduleAutoSave();
  notifyListeners();
  return missing;
}
```

- [ ] **Step 8: Remove folder reconnect references**

Delete these controller APIs and usages:

```dart
isSelectedProjectImageFolderMissing
reconnectSelectedProjectImageFolder
importImagesFromFolder
```

Update tests that called `importImagesFromFolder` to `addImagesFromFolder`.

- [ ] **Step 9: Run controller tests**

Run: `flutter test test/ui/app_controller_test.dart test/ui/app_controller_library_test.dart -r compact`

Expected: PASS.

---

### Task 5: COCO Export From Source Manifest

**Files:**
- Modify: `C:\workspace\bbox\lib\export\coco_exporter.dart`
- Modify: `C:\workspace\bbox\test\export\coco_exporter_test.dart`

**Interfaces:**
- Consumes: `AnnotatedImage.displayName`, `sourcePath`.
- Produces: collision-safe COCO `images.file_name`.

- [ ] **Step 1: Add file-name collision test**

```dart
test('uses stable file names when display names collide', () {
  final project = AnnotationProject.empty(name: 'demo').copyWith(
    labels: const [LabelClass(id: 1, name: 'Person', color: 0xffe64a19)],
    images: const [
      AnnotatedImage(
        id: 1,
        sourcePath: r'D:\a\same.jpg',
        displayName: 'same.jpg',
        width: 100,
        height: 80,
        status: ImageStatus.confirmed,
      ),
      AnnotatedImage(
        id: 2,
        sourcePath: r'E:\b\same.jpg',
        displayName: 'same.jpg',
        width: 100,
        height: 80,
        status: ImageStatus.confirmed,
      ),
    ],
  );

  final coco = CocoExporter.build(project);
  final images = coco['images'] as List<Object?>;

  expect(images[0], containsPair('file_name', 'same.jpg'));
  expect(images[1], containsPair('file_name', 'image_000002_same.jpg'));
});
```

- [ ] **Step 2: Run export tests and verify they fail**

Run: `flutter test test/export/coco_exporter_test.dart -r compact`

Expected: FAIL because exporter still reads `relativePath`.

- [ ] **Step 3: Implement file-name selection**

In `coco_exporter.dart`, replace relative path file names with:

```dart
static Map<int, String> _cocoFileNames(List<AnnotatedImage> images) {
  final used = <String>{};
  final names = <int, String>{};
  for (final image in images) {
    var candidate = image.displayName;
    if (used.contains(candidate)) {
      candidate = 'image_${image.id.toString().padLeft(6, '0')}_${image.displayName}';
    }
    used.add(candidate);
    names[image.id] = candidate;
  }
  return names;
}
```

Use `fileNames[image.id]!` for each COCO image entry.

- [ ] **Step 4: Update existing export tests to sourcePath model**

Change all `AnnotatedImage(relativePath: ...)` fixtures to:

```dart
AnnotatedImage(
  id: 1,
  sourcePath: r'D:\images\a.jpg',
  displayName: 'a.jpg',
  width: 100,
  height: 80,
  status: ImageStatus.confirmed,
)
```

- [ ] **Step 5: Run export tests**

Run: `flutter test test/export/coco_exporter_test.dart -r compact`

Expected: PASS.

---

### Task 6: Workbench UI Add Images, Progress, Viewer Loading, Remove Image

**Files:**
- Modify: `C:\workspace\bbox\lib\ui\workbench_copy.dart`
- Modify: `C:\workspace\bbox\lib\ui\windows_dialog_service.dart`
- Modify: `C:\workspace\bbox\lib\ui\workbench_screen.dart`
- Modify: `C:\workspace\bbox\test\ui\workbench_widget_test.dart`
- Modify: `C:\workspace\bbox\test\ui\project_home_widget_test.dart`

**Interfaces:**
- Consumes: `AppController.addImageFiles`, `addImagesFromFolder`, `removeImageFromProject`, `activity`, `lastImportProgress`, `imageViewLoadState`.
- Produces: `choose-image-add`, `add-image-files`, `add-image-folder`, `remove-image-from-project`, `import-progress-surface`, `viewer-loading-state`.

- [ ] **Step 1: Add widget test for add menu and append behavior**

```dart
testWidgets('adds images from a folder without replacing existing images', (tester) async {
  final tempDir = Directory.systemTemp.createTempSync('bbox_add_folder_ui');
  addTearDown(() => tempDir.deleteSync(recursive: true));
  File('${tempDir.path}${Platform.pathSeparator}b.jpg').writeAsBytesSync(
    img.encodeJpg(img.Image(width: 20, height: 10)),
  );

  final controller = AppController();
  controller.loadProject(
    AnnotationProject.empty(name: 'demo').copyWith(
      status: ProjectStatus.ready,
      images: const [
        AnnotatedImage(
          id: 1,
          sourcePath: r'C:\images\a.jpg',
          displayName: 'a.jpg',
          width: 100,
          height: 80,
          status: ImageStatus.needsReview,
        ),
      ],
    ),
  );

  await tester.pumpWidget(
    _app(
      controller,
      chooseImageFolderPath: (context, currentPath) async => tempDir.path,
    ),
  );
  await tester.tap(find.byKey(const ValueKey('choose-image-add')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('add-image-folder')));
  await tester.pumpAndSettle();

  expect(controller.project!.images, hasLength(2));
  expect(controller.project!.images.map((image) => image.displayName), ['a.jpg', 'b.jpg']);
});
```

- [ ] **Step 2: Add widget test for remove action**

```dart
testWidgets('removes selected image from project after confirmation', (tester) async {
  final controller = AppController();
  controller.loadProject(_project());

  await tester.pumpWidget(_app(controller));
  await tester.tap(find.byKey(const ValueKey('remove-image-from-project')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('confirm-remove-image-from-project')));
  await tester.pumpAndSettle();

  expect(controller.project!.images.map((image) => image.id), [2]);
});
```

- [ ] **Step 3: Add widget test for viewer loading state**

```dart
testWidgets('shows viewer loading state while selected image is loading', (tester) async {
  final controller = AppController();
  controller.loadProject(_project());
  controller.debugSetImageViewLoadState(
    const ImageViewLoadState(imageId: 1, isLoading: true),
  );

  await tester.pumpWidget(_app(controller));

  expect(find.byKey(const ValueKey('viewer-loading-state')), findsOneWidget);
});
```

If using a debug setter is undesirable, expose it only under `@visibleForTesting`:

```dart
@visibleForTesting
void debugSetImageViewLoadState(ImageViewLoadState state) {
  _imageViewLoadState = state;
  notifyListeners();
}
```

- [ ] **Step 4: Run UI tests and verify they fail**

Run: `flutter test test/ui/workbench_widget_test.dart test/ui/project_home_widget_test.dart -r compact`

Expected: FAIL because old keys and copy still refer to image folders.

- [ ] **Step 5: Update copy constants**

In `workbench_copy.dart`, replace folder-centered labels with:

```dart
static const imageAdd = '이미지 추가';
static const addImageFiles = '파일 추가';
static const addImageFolder = '폴더 추가';
static const noImagesYet = '아직 이미지가 없습니다.';
static const addImagesToStart = '파일 또는 폴더를 추가해 라벨링을 시작하세요.';
static const sourceImagesUnchanged = '원본 이미지는 수정하지 않습니다.';
static const removeImageFromProject = '프로젝트에서 제거';
static const removeImageTitle = '이미지를 프로젝트에서 제거할까요?';
static const removeImageMessage = '원본 파일은 삭제하지 않습니다.';
static const loadingImage = '이미지 불러오는 중';
```

- [ ] **Step 6: Add file picker service**

In `windows_dialog_service.dart`, add:

```dart
static Future<List<String>> pickImageFiles() async {
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-Command',
    r'''
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Multiselect = $true
$dialog.Filter = "Image files (*.jpg;*.jpeg;*.png)|*.jpg;*.jpeg;*.png"
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  $dialog.FileNames -join "`n"
}
''',
  ]);
  final output = result.stdout.toString().trim();
  if (output.isEmpty) {
    return const [];
  }
  return output.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList();
}
```

- [ ] **Step 7: Replace toolbar action with add menu**

In `workbench_screen.dart`, replace the `choose-image-folder` button with:

```dart
PopupMenuButton<String>(
  key: const ValueKey('choose-image-add'),
  tooltip: WorkbenchCopy.imageAdd,
  onSelected: (value) {
    if (value == 'files') {
      _addImageFiles(context);
    } else if (value == 'folder') {
      _addImageFolder(context);
    }
  },
  itemBuilder: (context) => const [
    PopupMenuItem(
      key: ValueKey('add-image-files'),
      value: 'files',
      child: Text(WorkbenchCopy.addImageFiles),
    ),
    PopupMenuItem(
      key: ValueKey('add-image-folder'),
      value: 'folder',
      child: Text(WorkbenchCopy.addImageFolder),
    ),
  ],
  child: TextButton.icon(
    onPressed: null,
    icon: Icon(Icons.add_photo_alternate_outlined),
    label: Text(WorkbenchCopy.imageAdd),
  ),
)
```

If a disabled child blocks tests, use `PopupMenuButton` with `icon` and adjacent text instead of a disabled `TextButton`.

- [ ] **Step 8: Implement add handlers**

Add:

```dart
Future<void> _addImageFiles(BuildContext context) async {
  try {
    final paths = await WindowsDialogService.pickImageFiles();
    if (!context.mounted || paths.isEmpty) {
      return;
    }
    await controller.addImageFiles(paths);
  } catch (error) {
    if (!context.mounted) {
      return;
    }
    _showError(context, '이미지를 추가하지 못했어요. $error');
  }
}

Future<void> _addImageFolder(BuildContext context) async {
  try {
    final pathPrompt = chooseImageFolderPath;
    final folderPath = pathPrompt == null
        ? await _showImageFolderPathDialog(context, null)
        : await pathPrompt(context, null);
    if (!context.mounted || folderPath == null) {
      return;
    }
    await controller.addImagesFromFolder(folderPath);
  } catch (error) {
    if (!context.mounted) {
      return;
    }
    _showError(context, '이미지 폴더를 추가하지 못했어요. $error');
  }
}
```

- [ ] **Step 9: Add progress and viewer loading widgets**

Near the top of workbench body, show:

```dart
if (controller.activity == ProjectActivity.importingImages &&
    controller.lastImportProgress != null)
  _ImportProgressSurface(progress: controller.lastImportProgress!),
```

Implement:

```dart
class _ImportProgressSurface extends StatelessWidget {
  const _ImportProgressSurface({required this.progress});

  final ImageImportProgress progress;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('import-progress-surface'),
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${progress.processedCount} / ${progress.discoveredCount} 처리 중'
                ' · 추가 ${progress.addedCount}'
                ' · 중복 ${progress.skippedDuplicateCount}'
                ' · 실패 ${progress.failedCount}',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

In viewer, before rendering `Image.file`, check:

```dart
if (widget.controller.imageViewLoadState.imageId == widget.image.id &&
    widget.controller.imageViewLoadState.isLoading)
```

and render a fixed-size centered state with key `viewer-loading-state`.

- [ ] **Step 10: Change image file resolution**

Replace:

```dart
File? _imageFile(AnnotationProject project, AnnotatedImage image)
```

with:

```dart
File _imageFile(AnnotatedImage image) {
  return File(image.sourcePath);
}
```

Update image label text from `image.relativePath` to `image.displayName`.

- [ ] **Step 11: Add remove action**

In inspector selected-image area, add:

```dart
OutlinedButton.icon(
  key: const ValueKey('remove-image-from-project'),
  onPressed: () => _removeImageFromProject(context, image.id),
  icon: const Icon(Icons.remove_circle_outline),
  label: const Text(WorkbenchCopy.removeImageFromProject),
)
```

Implement confirmation:

```dart
Future<void> _removeImageFromProject(BuildContext context, int imageId) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text(WorkbenchCopy.removeImageTitle),
      content: const Text(WorkbenchCopy.removeImageMessage),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text(WorkbenchCopy.cancel),
        ),
        FilledButton(
          key: const ValueKey('confirm-remove-image-from-project'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text(WorkbenchCopy.removeImageFromProject),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    controller.removeImageFromProject(imageId);
  }
}
```

- [ ] **Step 12: Run UI tests**

Run: `flutter test test/ui/workbench_widget_test.dart test/ui/project_home_widget_test.dart -r compact`

Expected: PASS.

---

### Task 7: Rewrite Integration Flow For Source Manifest

**Files:**
- Modify: `C:\workspace\bbox\test\integration\mvp_flow_test.dart`
- Modify: `C:\workspace\bbox\test\ui\workbench_widget_test.dart`
- Modify: any remaining tests that fail due to `relativePath` or `imageFolderPath`

**Interfaces:**
- Consumes all earlier tasks.
- Produces full source-manifest integration coverage.

- [ ] **Step 1: Update MVP flow import calls**

Replace:

```dart
await controller.importImagesFromFolder(
  imageDir.path,
  detector: const DummyDetector(),
);
```

with:

```dart
await controller.addImagesFromFolder(
  imageDir.path,
  detector: const DummyDetector(),
);
```

Replace `imageFolderPath` expectations with source-path checks:

```dart
expect(reloaded.project!.images.first.sourcePath, contains('a.jpg'));
expect(reloaded.project!.images.first.displayName, 'a.jpg');
```

- [ ] **Step 2: Add integration assertion for append from a second folder**

In the library flow test, create a second folder and add one file:

```dart
final secondDir = Directory(
  '${tempDir.path}${Platform.pathSeparator}more-images',
);
await secondDir.create();
await File(
  '${secondDir.path}${Platform.pathSeparator}b.jpg',
).writeAsBytes(img.encodeJpg(_fixtureImage(width: 64, height: 48)));

await controller.addImagesFromFolder(
  secondDir.path,
  detector: const DummyDetector(),
);

expect(controller.project!.images, hasLength(2));
```

- [ ] **Step 3: Run all tests and collect remaining compile failures**

Run: `flutter test -r compact`

Expected: FAIL if any fixtures still use `relativePath`, `imageFolderPath`, or removed reconnect APIs.

- [ ] **Step 4: Mechanical fixture rewrite**

For each failing fixture, replace:

```dart
AnnotatedImage(
  id: 1,
  relativePath: 'a.jpg',
  width: 100,
  height: 80,
  status: ImageStatus.needsReview,
)
```

with:

```dart
AnnotatedImage(
  id: 1,
  sourcePath: r'C:\images\a.jpg',
  displayName: 'a.jpg',
  width: 100,
  height: 80,
  status: ImageStatus.needsReview,
)
```

Remove project-level:

```dart
imageFolderPath: r'C:\images',
```

- [ ] **Step 5: Run full test suite**

Run: `flutter test -r compact`

Expected: PASS.

---

### Task 8: Full Verification And Build

**Files:**
- No new source files.
- Verify all modified Dart files.

**Interfaces:**
- Consumes completed Tasks 1-7.
- Produces verified build.

- [ ] **Step 1: Format**

Run: `dart format --set-exit-if-changed .`

Expected: exit code 0.

- [ ] **Step 2: Analyze**

Run: `flutter analyze`

Expected: exit code 0 with no analyzer errors.

- [ ] **Step 3: Test**

Run: `flutter test`

Expected: exit code 0.

- [ ] **Step 4: Build Windows**

Run: `flutter build windows`

Expected: exit code 0 and release executable under `build\windows\x64\runner\Release\bbox_labeler.exe`.

- [ ] **Step 5: Manual QA**

Run the Windows app and verify:

1. Create a new project.
2. Click `이미지 추가`.
3. Add `C:\workspace\bbox\qa_samples\images` as a folder.
4. Add one image file from another folder.
5. Confirm the list appends instead of replacing.
6. Add the same folder again and confirm duplicates are skipped.
7. Select an image and confirm viewer loading appears briefly or the image loads without layout shift.
8. Remove one image from the project and confirm the original file still exists.
9. Label one box, confirm the image, export COCO JSON.
10. Reopen the project and confirm source-path images and annotations are restored.

---

## Self Review

Spec coverage:

- Reference-managed manifest: Tasks 1, 2, 4, 7.
- No folder 1:1 project link: Tasks 1, 3, 6.
- Add files and folders: Tasks 2, 4, 6.
- Append import and duplicate skip: Tasks 4, 6, 7.
- Remove from project without source deletion: Tasks 4, 6.
- Loading states: Tasks 4, 6.
- Missing source handling: Task 4.
- COCO file name collision and source manifest export: Task 5.
- 6000-image performance posture: Tasks 4, 6, 8.
- No migration: Task 1 sets schema 2 only.

Completion-marker scan:

- No unfinished markers or unspecified implementation steps remain.

Type consistency:

- `AnnotatedImage.sourcePath`, `displayName`, and `importedFrom` are introduced in Task 1 and used consistently afterward.
- `ImageScanner.scanFiles` and `scanFolder` return `ScannedImage` values with the fields consumed by `AppController`.
- `ProjectActivity`, `ImageImportProgress`, and `ImageViewLoadState` are introduced before UI tasks consume them.
