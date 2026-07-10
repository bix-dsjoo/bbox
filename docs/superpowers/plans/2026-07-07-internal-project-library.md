# Internal Project Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an AppData-backed internal project library so users create, save, list, open, rename, delete, and reconnect projects inside the app without direct project-file picker workflows.

**Architecture:** Keep `ProjectStore` as the single-project JSON serializer. Add `ProjectLibrary` as the AppData catalog layer with `index.json`, then route `AppController` and the start screen through library-aware methods. Source images remain external references; reconnect updates only `imageFolderPath` while preserving image-relative annotation paths.

**Tech Stack:** Flutter desktop, Dart 3.12.2, Material widgets, `dart:io`, `dart:convert`, existing `path` package, existing `ChangeNotifier` controller, `flutter_test`.

## Global Constraints

- Windows desktop is the MVP target.
- Store project data under `%APPDATA%\BBoxLabeler\projects`.
- Do not copy, modify, or delete original source images.
- Keep `project.bbox.json` as UTF-8 JSON and keep project schema version `1`.
- Keep COCO export as a separate user-selected output file flow.
- Preserve original-image-pixel annotation coordinates.
- Widgets must call controller actions and must not write project JSON or index files directly.
- Current workspace has no `.git` directory and `git` is not on PATH; run the conditional commit command in each task and accept the explicit skip output in this workspace.

---

## File Structure

- Create `lib/project/project_library.dart`: AppData root resolution, project ID generation, `index.json` read/write, list/create/open/rename/delete/refresh methods, image-folder status helpers, reconnect support.
- Modify `lib/ui/app_controller.dart`: inject `ProjectLibrary`, expose library entries/loading state, add library-aware project actions, refresh index after saves and autosaves, add reconnect action.
- Modify `lib/ui/start_screen.dart`: replace file-open start flow with internal project home, project list, create, open, rename, delete.
- Modify `lib/ui/workbench_screen.dart`: save internally without save dialog, show missing image folder banner, add reconnect action.
- Modify `lib/ui/bbox_app.dart`: default controller uses default library; tests may still pass injected controllers.
- Test `test/project/project_library_test.dart`: focused unit coverage for library storage and index behavior.
- Test `test/ui/project_home_widget_test.dart`: project home widget behavior.
- Modify `test/widget_test.dart`: update app smoke test for internal project creation.
- Modify `test/ui/workbench_widget_test.dart`: adjust save/reconnect expectations as needed.
- Modify `test/integration/mvp_flow_test.dart`: add internal-library reopen flow.

---

### Task 1: Project Library Persistence

**Files:**
- Create: `lib/project/project_library.dart`
- Create: `test/project/project_library_test.dart`
- Existing reference: `lib/project/project_store.dart`
- Existing reference: `lib/annotation/models.dart`

**Interfaces:**
- Consumes: `ProjectStore.save(AnnotationProject project, String projectFilePath)`, `ProjectStore.load(String projectFilePath)`, `AnnotationProject.copyWith(...)`.
- Produces:
  - `class ProjectLibraryEntry`
  - `class ProjectLibrary`
  - `class ReconnectImageFolderResult`
  - `ProjectLibrary({required String rootPath, Clock? clock, ProjectIdGenerator? idGenerator})`
  - `factory ProjectLibrary.appData({Map<String, String>? environment})`
  - `Future<List<ProjectLibraryEntry>> listProjects()`
  - `Future<AnnotationProject> createProject(String name)`
  - `Future<AnnotationProject> openProject(String id)`
  - `Future<AnnotationProject> renameProject(String id, String name)`
  - `Future<void> deleteProject(String id)`
  - `Future<void> refreshEntry(AnnotationProject project)`
  - `Future<List<ProjectLibraryEntry>> rebuildIndex()`
  - `bool isImageFolderMissing(AnnotationProject project)`
  - `Future<ReconnectImageFolderResult> reconnectImageFolder(AnnotationProject project, String folderPath)`

- [ ] **Step 1: Write failing project library tests**

Create `test/project/project_library_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/project/project_library.dart';
import 'package:bbox_labeler/project/project_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('ProjectLibrary', () {
    late Directory tempDir;
    late DateTime now;
    late ProjectLibrary library;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('bbox_project_library');
      now = DateTime.utc(2026, 7, 7, 5, 30, 12);
      library = ProjectLibrary(
        rootPath: tempDir.path,
        clock: () => now,
        idGenerator: (name, timestamp) => 'fixed-project',
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('creates a project inside the internal projects folder', () async {
      final project = await library.createProject('Demo Project');

      final expectedPath = p.join(
        tempDir.path,
        'projects',
        'fixed-project',
        'project.bbox.json',
      );
      expect(project.name, 'Demo Project');
      expect(project.projectFilePath, expectedPath);
      expect(project.status, ProjectStatus.ready);
      expect(await File(expectedPath).exists(), isTrue);

      final entries = await library.listProjects();
      expect(entries, hasLength(1));
      expect(entries.single.id, 'fixed-project');
      expect(entries.single.name, 'Demo Project');
      expect(entries.single.projectFilePath, expectedPath);
      expect(entries.single.imageCount, 0);
      expect(entries.single.confirmedImageCount, 0);
      expect(entries.single.errorImageCount, 0);
    });

    test('lists projects sorted by updatedAt descending', () async {
      final first = ProjectLibrary(
        rootPath: tempDir.path,
        clock: () => DateTime.utc(2026, 7, 7, 5, 0),
        idGenerator: (name, timestamp) => 'first',
      );
      final second = ProjectLibrary(
        rootPath: tempDir.path,
        clock: () => DateTime.utc(2026, 7, 7, 6, 0),
        idGenerator: (name, timestamp) => 'second',
      );

      await first.createProject('First');
      await second.createProject('Second');

      final entries = await library.listProjects();
      expect(entries.map((entry) => entry.id), ['second', 'first']);
    });

    test('opens and renames a project without changing the id', () async {
      await library.createProject('Before');

      final renamed = await library.renameProject('fixed-project', 'After');
      final opened = await library.openProject('fixed-project');
      final entries = await library.listProjects();

      expect(renamed.name, 'After');
      expect(opened.name, 'After');
      expect(entries.single.id, 'fixed-project');
      expect(entries.single.name, 'After');
      expect(p.basename(p.dirname(opened.projectFilePath!)), 'fixed-project');
    });

    test('refreshes index metadata from saved project state', () async {
      final created = await library.createProject('Dataset');
      final updated = created.copyWith(
        imageFolderPath: p.join(tempDir.path, 'images'),
        images: const [
          AnnotatedImage(
            id: 1,
            relativePath: 'a.jpg',
            width: 100,
            height: 80,
            status: ImageStatus.confirmed,
          ),
          AnnotatedImage(
            id: 2,
            relativePath: 'broken.jpg',
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
      expect(entry.imageFolderPath, updated.imageFolderPath);
      expect(entry.imageCount, 2);
      expect(entry.confirmedImageCount, 1);
      expect(entry.errorImageCount, 1);
    });

    test('rebuilds index from project directories when index is corrupted', () async {
      await library.createProject('Recoverable');
      final indexFile = File(p.join(tempDir.path, 'projects', 'index.json'));
      await indexFile.writeAsString('{broken', encoding: utf8);

      final entries = await library.listProjects();

      expect(entries, hasLength(1));
      expect(entries.single.name, 'Recoverable');
      final raw = jsonDecode(await indexFile.readAsString(encoding: utf8))
          as Map<String, Object?>;
      expect(raw['schemaVersion'], ProjectLibrary.currentIndexSchemaVersion);
    });

    test('deletes only the internal project directory', () async {
      final imageDir = Directory(p.join(tempDir.path, 'external-images'));
      await imageDir.create();
      final imageFile = File(p.join(imageDir.path, 'a.jpg'));
      await imageFile.writeAsString('source image bytes');

      final created = await library.createProject('Delete Me');
      final projectWithImages = created.copyWith(imageFolderPath: imageDir.path);
      await ProjectStore.save(projectWithImages, created.projectFilePath!);
      await library.refreshEntry(projectWithImages);

      await library.deleteProject('fixed-project');

      expect(await File(created.projectFilePath!).exists(), isFalse);
      expect(await imageFile.exists(), isTrue);
      expect(await library.listProjects(), isEmpty);
    });

    test('detects and reconnects a missing image folder', () async {
      final created = await library.createProject('Reconnect');
      final oldFolder = p.join(tempDir.path, 'old-images');
      final newFolder = Directory(p.join(tempDir.path, 'new-images'));
      await newFolder.create();
      await File(p.join(newFolder.path, 'a.jpg')).writeAsString('image');

      final project = created.copyWith(
        imageFolderPath: oldFolder,
        images: const [
          AnnotatedImage(
            id: 1,
            relativePath: 'a.jpg',
            width: 100,
            height: 80,
            status: ImageStatus.needsReview,
          ),
          AnnotatedImage(
            id: 2,
            relativePath: 'missing.jpg',
            width: 100,
            height: 80,
            status: ImageStatus.needsReview,
          ),
        ],
      );
      await ProjectStore.save(project, project.projectFilePath!);

      expect(library.isImageFolderMissing(project), isTrue);

      final result = await library.reconnectImageFolder(project, newFolder.path);

      expect(result.project.imageFolderPath, newFolder.path);
      expect(result.project.images.map((image) => image.relativePath), [
        'a.jpg',
        'missing.jpg',
      ]);
      expect(result.missingRelativePaths, ['missing.jpg']);
      expect(library.isImageFolderMissing(result.project), isFalse);
    });

    test('resolves AppData root from the provided environment', () {
      final appDataRoot = p.join(tempDir.path, 'Roaming');

      final appDataLibrary = ProjectLibrary.appData(
        environment: {'APPDATA': appDataRoot},
      );

      expect(appDataLibrary.rootPath, p.join(appDataRoot, 'BBoxLabeler'));
      expect(appDataLibrary.projectsRootPath, p.join(appDataRoot, 'BBoxLabeler', 'projects'));
    });
  });
}
```

- [ ] **Step 2: Run the failing tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\project\project_library_test.dart
```

Expected: FAIL with errors that `project_library.dart`, `ProjectLibrary`, and `ProjectLibraryEntry` do not exist.

- [ ] **Step 3: Implement `ProjectLibrary`**

Create `lib/project/project_library.dart` with this implementation shape:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../annotation/models.dart';
import 'project_store.dart';

typedef Clock = DateTime Function();
typedef ProjectIdGenerator = String Function(String name, DateTime timestamp);

class UnsupportedProjectIndexVersionException implements Exception {
  UnsupportedProjectIndexVersionException(this.version);

  final int version;

  @override
  String toString() => 'Unsupported project index schema version: $version';
}

class ProjectLibraryEntry {
  const ProjectLibraryEntry({
    required this.id,
    required this.name,
    required this.projectFilePath,
    required this.createdAt,
    required this.updatedAt,
    this.imageFolderPath,
    this.imageCount = 0,
    this.confirmedImageCount = 0,
    this.errorImageCount = 0,
  });

  final String id;
  final String name;
  final String projectFilePath;
  final String? imageFolderPath;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int imageCount;
  final int confirmedImageCount;
  final int errorImageCount;

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'projectFilePath': projectFilePath,
      'imageFolderPath': imageFolderPath,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'imageCount': imageCount,
      'confirmedImageCount': confirmedImageCount,
      'errorImageCount': errorImageCount,
    };
  }

  factory ProjectLibraryEntry.fromJson(Map<String, Object?> json) {
    return ProjectLibraryEntry(
      id: json['id'] as String,
      name: json['name'] as String,
      projectFilePath: json['projectFilePath'] as String,
      imageFolderPath: json['imageFolderPath'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      imageCount: json['imageCount'] as int? ?? 0,
      confirmedImageCount: json['confirmedImageCount'] as int? ?? 0,
      errorImageCount: json['errorImageCount'] as int? ?? 0,
    );
  }
}

class ReconnectImageFolderResult {
  const ReconnectImageFolderResult({
    required this.project,
    required this.missingRelativePaths,
  });

  final AnnotationProject project;
  final List<String> missingRelativePaths;
}

class ProjectLibrary {
  ProjectLibrary({
    required this.rootPath,
    Clock? clock,
    ProjectIdGenerator? idGenerator,
  }) : _clock = clock ?? DateTime.now,
       _idGenerator = idGenerator ?? _defaultProjectId;

  factory ProjectLibrary.appData({Map<String, String>? environment}) {
    final appData = environment?['APPDATA'] ?? Platform.environment['APPDATA'];
    if (appData == null || appData.trim().isEmpty) {
      throw StateError('APPDATA is not available.');
    }
    return ProjectLibrary(rootPath: p.join(appData, 'BBoxLabeler'));
  }

  static const int currentIndexSchemaVersion = 1;

  final String rootPath;
  final Clock _clock;
  final ProjectIdGenerator _idGenerator;

  String get projectsRootPath => p.join(rootPath, 'projects');
  String get indexFilePath => p.join(projectsRootPath, 'index.json');

  Future<List<ProjectLibraryEntry>> listProjects() async {
    try {
      final entries = await _readIndex();
      return _sorted(entries);
    } on FormatException {
      return rebuildIndex();
    } on FileSystemException {
      return rebuildIndex();
    } on TypeError {
      return rebuildIndex();
    }
  }

  Future<AnnotationProject> createProject(String name) async {
    final timestamp = _clock().toUtc();
    final id = await _uniqueProjectId(name, timestamp);
    final projectFilePath = p.join(projectsRootPath, id, 'project.bbox.json');
    final project = AnnotationProject.empty(name: _normalizeName(name))
        .copyWith(projectFilePath: projectFilePath, status: ProjectStatus.ready);
    final saved = await ProjectStore.save(project, projectFilePath);
    await refreshEntry(saved, createdAt: timestamp, updatedAt: timestamp);
    return saved;
  }

  Future<AnnotationProject> openProject(String id) async {
    final entries = await listProjects();
    final entry = entries.firstWhere(
      (entry) => entry.id == id,
      orElse: () => throw StateError('Project not found: $id'),
    );
    return ProjectStore.load(entry.projectFilePath);
  }

  Future<AnnotationProject> renameProject(String id, String name) async {
    final project = await openProject(id);
    final renamed = project.copyWith(name: _normalizeName(name));
    final saved = await ProjectStore.save(renamed, project.projectFilePath!);
    await refreshEntry(saved);
    return saved;
  }

  Future<void> deleteProject(String id) async {
    final entries = await listProjects();
    final entry = entries.firstWhere(
      (entry) => entry.id == id,
      orElse: () => throw StateError('Project not found: $id'),
    );
    final projectDir = Directory(p.dirname(entry.projectFilePath));
    final normalizedRoot = p.normalize(Directory(projectsRootPath).absolute.path);
    final normalizedDir = p.normalize(projectDir.absolute.path);
    if (!p.isWithin(normalizedRoot, normalizedDir)) {
      throw StateError('Refusing to delete outside the project library.');
    }
    if (await projectDir.exists()) {
      await projectDir.delete(recursive: true);
    }
    await _writeIndex(entries.where((entry) => entry.id != id).toList());
  }

  Future<void> refreshEntry(
    AnnotationProject project, {
    DateTime? createdAt,
    DateTime? updatedAt,
  }) async {
    final projectFilePath = project.projectFilePath;
    if (projectFilePath == null) {
      throw StateError('Project file path is required.');
    }
    final id = p.basename(p.dirname(projectFilePath));
    final entries = await listProjects();
    ProjectLibraryEntry? existing;
    for (final entry in entries) {
      if (entry.id == id) {
        existing = entry;
        break;
      }
    }
    final timestamp = (updatedAt ?? project.lastSavedAt ?? _clock()).toUtc();
    final entry = _entryFromProject(
      id: id,
      project: project,
      createdAt: createdAt ?? existing?.createdAt ?? timestamp,
      updatedAt: timestamp,
    );
    await _writeIndex([
      for (final current in entries)
        if (current.id != id) current,
      entry,
    ]);
  }

  Future<List<ProjectLibraryEntry>> rebuildIndex() async {
    final root = Directory(projectsRootPath);
    if (!await root.exists()) {
      await _writeIndex(const []);
      return const [];
    }
    final entries = <ProjectLibraryEntry>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final projectFile = File(p.join(entity.path, 'project.bbox.json'));
      if (!await projectFile.exists()) {
        continue;
      }
      try {
        final project = await ProjectStore.load(projectFile.path);
        final timestamp = project.lastSavedAt?.toUtc() ?? _clock().toUtc();
        entries.add(
          _entryFromProject(
            id: p.basename(entity.path),
            project: project,
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
      } catch (_) {
        continue;
      }
    }
    await _writeIndex(entries);
    return _sorted(entries);
  }

  bool isImageFolderMissing(AnnotationProject project) {
    final imageFolderPath = project.imageFolderPath;
    if (imageFolderPath == null || imageFolderPath.trim().isEmpty) {
      return false;
    }
    return !Directory(imageFolderPath).existsSync();
  }

  Future<ReconnectImageFolderResult> reconnectImageFolder(
    AnnotationProject project,
    String folderPath,
  ) async {
    final updated = project.copyWith(imageFolderPath: folderPath);
    final missing = <String>[];
    for (final image in updated.images) {
      final file = File(p.joinAll([folderPath, ...image.relativePath.split('/')]));
      if (!await file.exists()) {
        missing.add(image.relativePath);
      }
    }
    final saved = await ProjectStore.save(updated, updated.projectFilePath!);
    await refreshEntry(saved);
    return ReconnectImageFolderResult(
      project: saved,
      missingRelativePaths: List.unmodifiable(missing),
    );
  }

  Future<String> _uniqueProjectId(String name, DateTime timestamp) async {
    final baseId = _idGenerator(name, timestamp);
    var id = baseId;
    var suffix = 2;
    while (await Directory(p.join(projectsRootPath, id)).exists()) {
      id = '$baseId-$suffix';
      suffix += 1;
    }
    return id;
  }

  Future<List<ProjectLibraryEntry>> _readIndex() async {
    final file = File(indexFilePath);
    if (!await file.exists()) {
      return const [];
    }
    final raw = await file.readAsString(encoding: utf8);
    final json = jsonDecode(raw) as Map<String, Object?>;
    final version = json['schemaVersion'] as int? ?? 0;
    if (version != currentIndexSchemaVersion) {
      throw UnsupportedProjectIndexVersionException(version);
    }
    final projectsJson = json['projects'] as List<Object?>? ?? const [];
    return projectsJson
        .cast<Map<String, Object?>>()
        .map(ProjectLibraryEntry.fromJson)
        .toList(growable: false);
  }

  Future<void> _writeIndex(List<ProjectLibraryEntry> entries) async {
    final file = File(indexFilePath);
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(
      encoder.convert({
        'schemaVersion': currentIndexSchemaVersion,
        'projects': _sorted(entries).map((entry) => entry.toJson()).toList(),
      }),
      encoding: utf8,
      flush: true,
    );
  }

  static List<ProjectLibraryEntry> _sorted(List<ProjectLibraryEntry> entries) {
    return [...entries]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  static ProjectLibraryEntry _entryFromProject({
    required String id,
    required AnnotationProject project,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) {
    return ProjectLibraryEntry(
      id: id,
      name: project.name,
      projectFilePath: project.projectFilePath!,
      imageFolderPath: project.imageFolderPath,
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
  }

  static String _normalizeName(String name) {
    final trimmed = name.trim();
    return trimmed.isEmpty ? 'BBox Project' : trimmed;
  }

  static String _defaultProjectId(String name, DateTime timestamp) {
    final stamp = timestamp
        .toUtc()
        .toIso8601String()
        .replaceAll('-', '')
        .replaceAll(':', '')
        .replaceAll('.', '')
        .replaceAll('Z', '');
    final slug = _normalizeName(name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return '$stamp-${slug.isEmpty ? 'project' : slug}';
  }
}
```

- [ ] **Step 4: Run project library tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\project\project_library_test.dart
```

Expected: PASS.

- [ ] **Step 5: Format and analyze touched project files**

Run:

```powershell
& 'C:\tools\flutter\bin\cache\dart-sdk\bin\dart.exe' format lib\project\project_library.dart test\project\project_library_test.dart
& 'C:\tools\flutter\bin\flutter.bat' analyze
```

Expected: `Formatted ...` or `Changed ...`, then `No issues found!`.

- [ ] **Step 6: Commit or record skip**

Run:

```powershell
if ((Test-Path .git) -and (Get-Command git -ErrorAction SilentlyContinue)) {
  git add lib/project/project_library.dart test/project/project_library_test.dart
  git commit -m "feat: add internal project library"
} else {
  Write-Output "Commit skipped: git repository or git executable unavailable"
}
```

Expected in this workspace: `Commit skipped: git repository or git executable unavailable`.

---

### Task 2: AppController Library Integration

**Files:**
- Modify: `lib/ui/app_controller.dart`
- Test: `test/ui/app_controller_library_test.dart`
- Uses: `lib/project/project_library.dart`

**Interfaces:**
- Consumes:
  - `ProjectLibrary.listProjects()`
  - `ProjectLibrary.createProject(String name)`
  - `ProjectLibrary.openProject(String id)`
  - `ProjectLibrary.renameProject(String id, String name)`
  - `ProjectLibrary.deleteProject(String id)`
  - `ProjectLibrary.refreshEntry(AnnotationProject project)`
  - `ProjectLibrary.isImageFolderMissing(AnnotationProject project)`
  - `ProjectLibrary.reconnectImageFolder(AnnotationProject project, String folderPath)`
- Produces:
  - `AppController({ProjectLibrary? projectLibrary})`
  - `List<ProjectLibraryEntry> get projectLibraryEntries`
  - `bool get isProjectLibraryLoading`
  - `bool get isSelectedProjectImageFolderMissing`
  - `Future<void> loadProjectLibrary()`
  - `Future<void> createLibraryProject(String name)`
  - `Future<void> openLibraryProject(String id)`
  - `Future<void> renameLibraryProject(String id, String name)`
  - `Future<void> deleteLibraryProject(String id)`
  - `Future<List<String>> reconnectSelectedProjectImageFolder(String folderPath)`

- [ ] **Step 1: Write failing controller tests**

Create `test/ui/app_controller_library_test.dart`:

```dart
import 'dart:io';

import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/project/project_library.dart';
import 'package:bbox_labeler/ui/app_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('AppController project library', () {
    late Directory tempDir;
    late ProjectLibrary library;
    late AppController controller;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('bbox_controller_library');
      library = ProjectLibrary(
        rootPath: tempDir.path,
        clock: () => DateTime.utc(2026, 7, 7, 5, 30),
        idGenerator: (name, timestamp) => 'controller-project',
      );
      controller = AppController(projectLibrary: library);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('loads library entries and creates a saved library project', () async {
      await controller.loadProjectLibrary();
      expect(controller.projectLibraryEntries, isEmpty);

      await controller.createLibraryProject('Demo');

      expect(controller.hasProject, isTrue);
      expect(controller.project!.name, 'Demo');
      expect(controller.project!.projectFilePath, isNotNull);
      expect(await File(controller.project!.projectFilePath!).exists(), isTrue);
      expect(controller.projectLibraryEntries.single.id, 'controller-project');
      expect(controller.projectLibraryEntries.single.name, 'Demo');
    });

    test('opens a project by library id and selects the first image', () async {
      final project = await library.createProject('Open Me');
      final saved = project.copyWith(
        images: const [
          AnnotatedImage(
            id: 7,
            relativePath: 'a.jpg',
            width: 100,
            height: 80,
            status: ImageStatus.needsReview,
          ),
        ],
      );
      await controller.loadProject(saved);
      await controller.saveProject(saved.projectFilePath);

      final reloaded = AppController(projectLibrary: library);
      await reloaded.loadProjectLibrary();
      await reloaded.openLibraryProject('controller-project');

      expect(reloaded.project!.name, 'Open Me');
      expect(reloaded.selectedImageId, 7);
    });

    test('refreshes the library index after autosaved annotation changes', () async {
      await controller.createLibraryProject('Autosave');
      final imageDir = Directory(p.join(tempDir.path, 'images'));
      await imageDir.create();

      await controller.importImagesFromFolder(imageDir.path);
      await controller.saveProject();
      await controller.loadProjectLibrary();

      expect(controller.projectLibraryEntries.single.imageFolderPath, imageDir.path);
      expect(controller.projectLibraryEntries.single.imageCount, 0);
    });

    test('renames and deletes projects through the library', () async {
      await controller.createLibraryProject('Before');
      final projectPath = controller.project!.projectFilePath!;

      await controller.renameLibraryProject('controller-project', 'After');
      expect(controller.project!.name, 'After');
      expect(controller.projectLibraryEntries.single.name, 'After');

      await controller.deleteLibraryProject('controller-project');
      expect(await File(projectPath).exists(), isFalse);
      expect(controller.projectLibraryEntries, isEmpty);
      expect(controller.hasProject, isFalse);
    });

    test('reconnects the selected project image folder', () async {
      await controller.createLibraryProject('Reconnect');
      final missingPath = p.join(tempDir.path, 'missing');
      controller.loadProject(
        controller.project!.copyWith(
          imageFolderPath: missingPath,
          images: const [
            AnnotatedImage(
              id: 1,
              relativePath: 'a.jpg',
              width: 100,
              height: 80,
              status: ImageStatus.needsReview,
            ),
          ],
        ),
      );
      await controller.saveProject();

      expect(controller.isSelectedProjectImageFolderMissing, isTrue);

      final newFolder = Directory(p.join(tempDir.path, 'new-images'));
      await newFolder.create();
      await File(p.join(newFolder.path, 'a.jpg')).writeAsString('image');

      final missing = await controller.reconnectSelectedProjectImageFolder(
        newFolder.path,
      );

      expect(missing, isEmpty);
      expect(controller.project!.imageFolderPath, newFolder.path);
      expect(controller.isSelectedProjectImageFolderMissing, isFalse);
    });
  });
}
```

- [ ] **Step 2: Run the failing controller tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\app_controller_library_test.dart
```

Expected: FAIL with missing constructor and missing controller methods.

- [ ] **Step 3: Update `AppController` constructor and state**

Modify `lib/ui/app_controller.dart` imports and fields:

```dart
import '../project/project_library.dart';
```

Inside `class AppController extends ChangeNotifier`:

```dart
  AppController({ProjectLibrary? projectLibrary})
    : _projectLibrary = projectLibrary ?? ProjectLibrary.appData();

  final ProjectLibrary _projectLibrary;
  List<ProjectLibraryEntry> _projectLibraryEntries = const [];
  bool _isProjectLibraryLoading = false;

  List<ProjectLibraryEntry> get projectLibraryEntries =>
      _projectLibraryEntries;

  bool get isProjectLibraryLoading => _isProjectLibraryLoading;

  bool get isSelectedProjectImageFolderMissing {
    final project = _project;
    return project != null && _projectLibrary.isImageFolderMissing(project);
  }
```

Keep all existing getters and existing direct `createProject`, `loadProject`, `openProject`, and `saveProject` methods for tests and compatibility.

- [ ] **Step 4: Add controller library actions**

Add these public methods to `AppController`:

```dart
  Future<void> loadProjectLibrary() async {
    _isProjectLibraryLoading = true;
    notifyListeners();
    try {
      _projectLibraryEntries = await _projectLibrary.listProjects();
    } finally {
      _isProjectLibraryLoading = false;
      notifyListeners();
    }
  }

  Future<void> createLibraryProject(String name) async {
    _undoStack.clear();
    _redoStack.clear();
    _project = await _projectLibrary.createProject(name);
    _selectedImageId = null;
    _selectedBoxId = null;
    _projectLibraryEntries = await _projectLibrary.listProjects();
    notifyListeners();
  }

  Future<void> openLibraryProject(String id) async {
    loadProject(await _projectLibrary.openProject(id));
    _projectLibraryEntries = await _projectLibrary.listProjects();
    notifyListeners();
  }

  Future<void> renameLibraryProject(String id, String name) async {
    final renamed = await _projectLibrary.renameProject(id, name);
    final currentPath = _project?.projectFilePath;
    if (currentPath == renamed.projectFilePath) {
      _project = renamed;
    }
    _projectLibraryEntries = await _projectLibrary.listProjects();
    notifyListeners();
  }

  Future<void> deleteLibraryProject(String id) async {
    final currentProjectId = _project?.projectFilePath == null
        ? null
        : p.basename(p.dirname(_project!.projectFilePath!));
    await _projectLibrary.deleteProject(id);
    _projectLibraryEntries = await _projectLibrary.listProjects();
    if (currentProjectId == id) {
      _project = null;
      _selectedImageId = null;
      _selectedBoxId = null;
      _undoStack.clear();
      _redoStack.clear();
    }
    notifyListeners();
  }

  Future<List<String>> reconnectSelectedProjectImageFolder(
    String folderPath,
  ) async {
    final result = await _projectLibrary.reconnectImageFolder(
      _requireProject(),
      folderPath,
    );
    _project = result.project;
    _projectLibraryEntries = await _projectLibrary.listProjects();
    notifyListeners();
    return result.missingRelativePaths;
  }
```

Also import `package:path/path.dart' as p;` at the top of `app_controller.dart`.

- [ ] **Step 5: Refresh index after explicit save and autosave**

In `saveProject`, after `ProjectStore.save`, refresh the entry:

```dart
    _project = await ProjectStore.save(_requireProject(), targetPath);
    await _projectLibrary.refreshEntry(_project!);
    _projectLibraryEntries = await _projectLibrary.listProjects();
    notifyListeners();
```

In `_scheduleAutoSave`, after `ProjectStore.save`, refresh the entry:

```dart
          _project = await ProjectStore.save(project, path);
          await _projectLibrary.refreshEntry(_project!);
          _projectLibraryEntries = await _projectLibrary.listProjects();
          notifyListeners();
```

In the `_scheduleAutoSave().catchError(...)` block, keep existing `lastError = error;` and add `notifyListeners();` so the UI can surface save errors.

- [ ] **Step 6: Run controller tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\app_controller_library_test.dart
```

Expected: PASS.

- [ ] **Step 7: Run regression tests for existing controller behavior**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\app_controller_test.dart test\integration\mvp_flow_test.dart
```

Expected: PASS. If `mvp_flow_test.dart` fails because `loadProject` is synchronous in existing tests, keep `loadProject` synchronous and do not convert it to `Future`.

- [ ] **Step 8: Format and analyze**

Run:

```powershell
& 'C:\tools\flutter\bin\cache\dart-sdk\bin\dart.exe' format lib\ui\app_controller.dart test\ui\app_controller_library_test.dart
& 'C:\tools\flutter\bin\flutter.bat' analyze
```

Expected: `No issues found!`.

- [ ] **Step 9: Commit or record skip**

Run:

```powershell
if ((Test-Path .git) -and (Get-Command git -ErrorAction SilentlyContinue)) {
  git add lib/ui/app_controller.dart test/ui/app_controller_library_test.dart
  git commit -m "feat: connect controller to project library"
} else {
  Write-Output "Commit skipped: git repository or git executable unavailable"
}
```

Expected in this workspace: `Commit skipped: git repository or git executable unavailable`.

---

### Task 3: Project Home Start Screen

**Files:**
- Modify: `lib/ui/start_screen.dart`
- Modify: `lib/ui/bbox_app.dart`
- Test: `test/ui/project_home_widget_test.dart`
- Modify: `test/widget_test.dart`

**Interfaces:**
- Consumes:
  - `AppController.loadProjectLibrary()`
  - `AppController.createLibraryProject(String name)`
  - `AppController.openLibraryProject(String id)`
  - `AppController.projectLibraryEntries`
  - `AppController.isProjectLibraryLoading`
- Produces:
  - Start screen key `project-home`
  - Project list row key `project-entry-<id>`
  - Create action key `create-project`
  - Project name field key `new-project-name`

- [ ] **Step 1: Write failing project home widget tests**

Create `test/ui/project_home_widget_test.dart`:

```dart
import 'dart:io';

import 'package:bbox_labeler/project/project_library.dart';
import 'package:bbox_labeler/ui/app_controller.dart';
import 'package:bbox_labeler/ui/bbox_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Project home', () {
    late Directory tempDir;
    late ProjectLibrary library;
    late AppController controller;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('bbox_project_home');
      library = ProjectLibrary(
        rootPath: tempDir.path,
        clock: () => DateTime.utc(2026, 7, 7, 5, 30),
        idGenerator: (name, timestamp) => 'home-project',
      );
      controller = AppController(projectLibrary: library);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    testWidgets('first launch shows an empty project home', (tester) async {
      await tester.pumpWidget(BboxApp(controller: controller));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('project-home')), findsOneWidget);
      expect(find.byKey(const ValueKey('new-project-name')), findsOneWidget);
      expect(find.byKey(const ValueKey('create-project')), findsOneWidget);
      expect(find.text('No projects yet'), findsOneWidget);
    });

    testWidgets('creating a project opens the workbench', (tester) async {
      await tester.pumpWidget(BboxApp(controller: controller));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('new-project-name')),
        'Demo Project',
      );
      await tester.tap(find.byKey(const ValueKey('create-project')));
      await tester.pumpAndSettle();

      expect(controller.hasProject, isTrue);
      expect(controller.project!.projectFilePath, isNotNull);
      expect(find.text('Demo Project'), findsOneWidget);
      expect(find.byKey(const ValueKey('choose-image-folder')), findsOneWidget);
    });

    testWidgets('returning launch lists and opens saved projects', (
      tester,
    ) async {
      await library.createProject('Saved Project');

      await tester.pumpWidget(BboxApp(controller: controller));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('project-entry-home-project')), findsOneWidget);
      expect(find.text('Saved Project'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('project-entry-home-project')));
      await tester.pumpAndSettle();

      expect(controller.hasProject, isTrue);
      expect(controller.project!.name, 'Saved Project');
      expect(find.byKey(const ValueKey('choose-image-folder')), findsOneWidget);
    });
  });
}
```

Modify `test/widget_test.dart` to use a temp library instead of `const BboxApp()`:

```dart
import 'dart:io';

import 'package:bbox_labeler/project/project_library.dart';
import 'package:bbox_labeler/ui/app_controller.dart';
import 'package:bbox_labeler/ui/bbox_app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('project home creates a new project and opens the workbench', (
    tester,
  ) async {
    final tempDir = await Directory.systemTemp.createTemp('bbox_widget_test');
    addTearDown(() => tempDir.delete(recursive: true));
    final controller = AppController(
      projectLibrary: ProjectLibrary(
        rootPath: tempDir.path,
        idGenerator: (name, timestamp) => 'widget-project',
      ),
    );

    await tester.pumpWidget(BboxApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Bounding Box Labeler'), findsOneWidget);
    expect(find.byKey(const ValueKey('new-project-name')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('new-project-name')),
      'Demo Project',
    );
    await tester.tap(find.byKey(const ValueKey('create-project')));
    await tester.pumpAndSettle();

    expect(find.text('Demo Project'), findsOneWidget);
    expect(find.byKey(const ValueKey('choose-image-folder')), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run failing widget tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\project_home_widget_test.dart test\widget_test.dart
```

Expected: FAIL because `StartScreen` still opens file dialogs and does not load/list library projects.

- [ ] **Step 3: Update `StartScreen` to load library entries**

In `lib/ui/start_screen.dart`, keep it as a `StatefulWidget`. Add `initState`:

```dart
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.loadProjectLibrary();
    });
  }
```

Remove the existing `_openProject` file-dialog method and remove the `WindowsDialogService` import from this file.

- [ ] **Step 4: Replace start screen body with project home layout**

In `build`, use an `AnimatedBuilder` around `widget.controller` and this structure:

```dart
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            key: const ValueKey('project-home'),
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Bounding Box Labeler',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('new-project-name'),
                          controller: _nameController,
                          decoration: const InputDecoration(
                            labelText: 'Project name',
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _createProject(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        key: const ValueKey('create-project'),
                        onPressed: _createProject,
                        icon: const Icon(Icons.add),
                        label: const Text('New project'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (widget.controller.isProjectLibraryLoading)
                    const LinearProgressIndicator()
                  else if (widget.controller.projectLibraryEntries.isEmpty)
                    const Expanded(
                      child: Center(child: Text('No projects yet')),
                    )
                  else
                    Expanded(
                      child: ListView.separated(
                        itemCount:
                            widget.controller.projectLibraryEntries.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final entry =
                              widget.controller.projectLibraryEntries[index];
                          return ListTile(
                            key: ValueKey('project-entry-${entry.id}'),
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(entry.name),
                            subtitle: Text(
                              '${entry.imageCount} images - '
                              '${entry.confirmedImageCount} confirmed - '
                              '${entry.errorImageCount} errors',
                            ),
                            trailing: Text(_formatDate(entry.updatedAt)),
                            onTap: () => _openLibraryProject(entry.id),
                          );
                        },
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        'Project action failed. $_error',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
```

Add `_formatDate` helper:

```dart
String _formatDate(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
```

- [ ] **Step 5: Update start screen actions**

Replace `_createProject`:

```dart
  Future<void> _createProject() async {
    final name = _nameController.text.trim().isEmpty
        ? 'BBox Project'
        : _nameController.text.trim();
    try {
      await widget.controller.createLibraryProject(name);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error);
    }
  }
```

Add `_openLibraryProject`:

```dart
  Future<void> _openLibraryProject(String id) async {
    try {
      await widget.controller.openLibraryProject(id);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error);
    }
  }
```

- [ ] **Step 6: Ensure `BboxApp` remains injection-friendly**

Keep `lib/ui/bbox_app.dart` using:

```dart
  late final AppController _controller = widget.controller ?? AppController();
```

No further `BboxApp` changes are needed if Task 2 added the default `ProjectLibrary.appData()` constructor path inside `AppController`.

- [ ] **Step 7: Run project home tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\project_home_widget_test.dart test\widget_test.dart
```

Expected: PASS.

- [ ] **Step 8: Format and analyze**

Run:

```powershell
& 'C:\tools\flutter\bin\cache\dart-sdk\bin\dart.exe' format lib\ui\start_screen.dart lib\ui\bbox_app.dart test\ui\project_home_widget_test.dart test\widget_test.dart
& 'C:\tools\flutter\bin\flutter.bat' analyze
```

Expected: `No issues found!`.

- [ ] **Step 9: Commit or record skip**

Run:

```powershell
if ((Test-Path .git) -and (Get-Command git -ErrorAction SilentlyContinue)) {
  git add lib/ui/start_screen.dart lib/ui/bbox_app.dart test/ui/project_home_widget_test.dart test/widget_test.dart
  git commit -m "feat: add internal project home"
} else {
  Write-Output "Commit skipped: git repository or git executable unavailable"
}
```

Expected in this workspace: `Commit skipped: git repository or git executable unavailable`.

---

### Task 4: Missing Image Folder Reconnect UX

**Files:**
- Modify: `lib/ui/workbench_screen.dart`
- Test: `test/ui/workbench_widget_test.dart`

**Interfaces:**
- Consumes:
  - `AppController.isSelectedProjectImageFolderMissing`
  - `AppController.reconnectSelectedProjectImageFolder(String folderPath)`
  - Existing `ChooseImageFolderPath`
- Produces:
  - Banner key `missing-image-folder-banner`
  - Reconnect action key `reconnect-image-folder`

- [ ] **Step 1: Add failing reconnect widget tests**

Append to `test/ui/workbench_widget_test.dart`:

```dart
    testWidgets('shows reconnect action when image folder is missing', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(
        _project().copyWith(imageFolderPath: r'C:\folder-that-does-not-exist'),
      );

      await tester.pumpWidget(_app(controller));

      expect(
        find.byKey(const ValueKey('missing-image-folder-banner')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('reconnect-image-folder')), findsOneWidget);
    });

    testWidgets('reconnects a missing image folder and keeps annotations', (
      tester,
    ) async {
      final tempDir = Directory.systemTemp.createTempSync(
        'bbox_reconnect_images',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));
      File('${tempDir.path}${Platform.pathSeparator}a.jpg').writeAsBytesSync(
        <int>[1, 2, 3],
      );

      final projectDir = Directory.systemTemp.createTempSync(
        'bbox_reconnect_project',
      );
      addTearDown(() => projectDir.deleteSync(recursive: true));

      final controller = AppController();
      controller.loadProject(
        _project().copyWith(
          projectFilePath:
              '${projectDir.path}${Platform.pathSeparator}project.bbox.json',
          imageFolderPath: r'C:\folder-that-does-not-exist',
        ),
      );
      await controller.saveProject();

      await tester.pumpWidget(
        _app(
          controller,
          chooseImageFolderPath: (context, currentPath) async => tempDir.path,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('reconnect-image-folder')));
      await tester.pumpAndSettle();

      expect(controller.project!.imageFolderPath, tempDir.path);
      expect(controller.project!.images.first.relativePath, 'a.jpg');
      expect(controller.project!.images.first.boxes.single.id, 'box-1');
    });
```

If the existing `_project()` helper uses `r'C:\images'`, the first test is stable on Windows because that path does not exist in the test environment.

- [ ] **Step 2: Run failing reconnect widget tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart
```

Expected: FAIL because the banner and reconnect action are not present.

- [ ] **Step 3: Add missing folder banner to `WorkbenchScreen`**

In `lib/ui/workbench_screen.dart`, wrap the current `body` child with a `Column` when the project is open:

```dart
          body: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.delete):
                  controller.deleteSelectedBox,
              const SingleActivator(LogicalKeyboardKey.backspace):
                  controller.deleteSelectedBox,
              const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
                  controller.undo,
              const SingleActivator(LogicalKeyboardKey.keyY, control: true):
                  controller.redo,
            },
            child: Focus(
              autofocus: true,
              child: Column(
                children: [
                  if (controller.isSelectedProjectImageFolderMissing)
                    _MissingImageFolderBanner(
                      onReconnect: () => _reconnectImageFolder(context),
                    ),
                  Expanded(
                    child: Row(
                      children: [
                        SizedBox(
                          width: 270,
                          child: _ImageListPanel(
                            controller: controller,
                            project: project,
                          ),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: _ViewerPanel(
                            controller: controller,
                            project: project,
                          ),
                        ),
                        const VerticalDivider(width: 1),
                        SizedBox(
                          width: 330,
                          child: _InspectorPanel(
                            controller: controller,
                            project: project,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
```

Add `_MissingImageFolderBanner` near other private widgets:

```dart
class _MissingImageFolderBanner extends StatelessWidget {
  const _MissingImageFolderBanner({required this.onReconnect});

  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('missing-image-folder-banner'),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(
              Icons.folder_off_outlined,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Image folder not found.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
            FilledButton.tonalIcon(
              key: const ValueKey('reconnect-image-folder'),
              onPressed: onReconnect,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('Reconnect'),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Add reconnect action**

Add method to `WorkbenchScreen`:

```dart
  Future<void> _reconnectImageFolder(BuildContext context) async {
    try {
      final currentPath = controller.project?.imageFolderPath;
      final pathPrompt = chooseImageFolderPath;
      final folderPath = pathPrompt == null
          ? await _showImageFolderPathDialog(context, currentPath)
          : await pathPrompt(context, currentPath);
      if (!context.mounted || folderPath == null) {
        return;
      }
      final missing = await controller.reconnectSelectedProjectImageFolder(
        folderPath,
      );
      if (!context.mounted || missing.isEmpty) {
        return;
      }
      _showError(
        context,
        'Some image files are still missing: ${missing.length}',
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      _showError(context, 'Image folder reconnect failed. $error');
    }
  }
```

- [ ] **Step 5: Make save button internal-only**

Replace `_saveProject` in `WorkbenchScreen` with:

```dart
  Future<void> _saveProject(BuildContext context) async {
    try {
      await controller.saveProject();
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      _showError(context, 'Current changes could not be saved. $error');
    }
  }
```

Remove `WindowsDialogService.saveProjectFile()` usage from this file. Keep `WindowsDialogService.pickFolder` and `WindowsDialogService.saveCocoFile`.

- [ ] **Step 6: Run reconnect tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\workbench_widget_test.dart
```

Expected: PASS.

- [ ] **Step 7: Format and analyze**

Run:

```powershell
& 'C:\tools\flutter\bin\cache\dart-sdk\bin\dart.exe' format lib\ui\workbench_screen.dart test\ui\workbench_widget_test.dart
& 'C:\tools\flutter\bin\flutter.bat' analyze
```

Expected: `No issues found!`.

- [ ] **Step 8: Commit or record skip**

Run:

```powershell
if ((Test-Path .git) -and (Get-Command git -ErrorAction SilentlyContinue)) {
  git add lib/ui/workbench_screen.dart test/ui/workbench_widget_test.dart
  git commit -m "feat: add image folder reconnect flow"
} else {
  Write-Output "Commit skipped: git repository or git executable unavailable"
}
```

Expected in this workspace: `Commit skipped: git repository or git executable unavailable`.

---

### Task 5: Project Rename And Delete Actions In Project Home

**Files:**
- Modify: `lib/ui/start_screen.dart`
- Test: `test/ui/project_home_widget_test.dart`

**Interfaces:**
- Consumes:
  - `AppController.renameLibraryProject(String id, String name)`
  - `AppController.deleteLibraryProject(String id)`
- Produces:
  - Popup key `project-menu-<id>`
  - Rename action key `rename-project-<id>`
  - Delete action key `delete-project-<id>`
  - Rename field key `rename-project-name`
  - Confirm rename key `confirm-rename-project`
  - Confirm delete key `confirm-delete-project`

- [ ] **Step 1: Add failing rename and delete widget tests**

Append to `test/ui/project_home_widget_test.dart`:

```dart
    testWidgets('renames a saved project from the project home', (
      tester,
    ) async {
      await library.createProject('Before');

      await tester.pumpWidget(BboxApp(controller: controller));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('project-menu-home-project')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rename-project-home-project')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('rename-project-name')),
        'After',
      );
      await tester.tap(find.byKey(const ValueKey('confirm-rename-project')));
      await tester.pumpAndSettle();

      expect(find.text('After'), findsOneWidget);
      expect(controller.projectLibraryEntries.single.name, 'After');
    });

    testWidgets('deletes a saved project from the project home only after confirmation', (
      tester,
    ) async {
      await library.createProject('Delete Me');

      await tester.pumpWidget(BboxApp(controller: controller));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('project-menu-home-project')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete-project-home-project')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Source images will not be deleted'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('confirm-delete-project')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('project-entry-home-project')), findsNothing);
      expect(controller.projectLibraryEntries, isEmpty);
    });
```

- [ ] **Step 2: Run failing tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\project_home_widget_test.dart
```

Expected: FAIL because project menu actions are not present.

- [ ] **Step 3: Add row popup menu actions**

In the `ListTile` for each project in `start_screen.dart`, replace `trailing: Text(_formatDate(entry.updatedAt))` with:

```dart
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(_formatDate(entry.updatedAt)),
                                PopupMenuButton<String>(
                                  key: ValueKey('project-menu-${entry.id}'),
                                  tooltip: 'Project actions',
                                  onSelected: (value) {
                                    if (value == 'rename') {
                                      _renameProject(entry.id, entry.name);
                                    } else if (value == 'delete') {
                                      _deleteProject(entry.id, entry.name);
                                    }
                                  },
                                  itemBuilder: (context) => [
                                    PopupMenuItem(
                                      key: ValueKey('rename-project-${entry.id}'),
                                      value: 'rename',
                                      child: const Text('Rename'),
                                    ),
                                    PopupMenuItem(
                                      key: ValueKey('delete-project-${entry.id}'),
                                      value: 'delete',
                                      child: const Text('Delete'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
```

- [ ] **Step 4: Add rename dialog action**

Add to `_StartScreenState`:

```dart
  Future<void> _renameProject(String id, String currentName) async {
    final controller = TextEditingController(text: currentName);
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Rename project'),
            content: TextField(
              key: const ValueKey('rename-project-name'),
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Project name',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
              onSubmitted: (value) => Navigator.of(context).pop(value),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const ValueKey('confirm-rename-project'),
                onPressed: () => Navigator.of(context).pop(controller.text),
                child: const Text('Rename'),
              ),
            ],
          );
        },
      );
      if (!mounted || name == null || name.trim().isEmpty) {
        return;
      }
      await widget.controller.renameLibraryProject(id, name);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error);
    } finally {
      controller.dispose();
    }
  }
```

- [ ] **Step 5: Add delete confirmation action**

Add to `_StartScreenState`:

```dart
  Future<void> _deleteProject(String id, String name) async {
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: Text('Delete $name?'),
            content: const Text(
              'This removes the internal project data. Source images will not be deleted.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const ValueKey('confirm-delete-project'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Delete'),
              ),
            ],
          );
        },
      );
      if (!mounted || confirmed != true) {
        return;
      }
      await widget.controller.deleteLibraryProject(id);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error);
    }
  }
```

- [ ] **Step 6: Run project home tests**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\ui\project_home_widget_test.dart
```

Expected: PASS.

- [ ] **Step 7: Format and analyze**

Run:

```powershell
& 'C:\tools\flutter\bin\cache\dart-sdk\bin\dart.exe' format lib\ui\start_screen.dart test\ui\project_home_widget_test.dart
& 'C:\tools\flutter\bin\flutter.bat' analyze
```

Expected: `No issues found!`.

- [ ] **Step 8: Commit or record skip**

Run:

```powershell
if ((Test-Path .git) -and (Get-Command git -ErrorAction SilentlyContinue)) {
  git add lib/ui/start_screen.dart test/ui/project_home_widget_test.dart
  git commit -m "feat: manage projects from project home"
} else {
  Write-Output "Commit skipped: git repository or git executable unavailable"
}
```

Expected in this workspace: `Commit skipped: git repository or git executable unavailable`.

---

### Task 6: Internal Library Integration Flow And Final Verification

**Files:**
- Modify: `test/integration/mvp_flow_test.dart`
- Modify as needed: `test/ui/workbench_widget_test.dart`
- Modify as needed: `lib/ui/windows_dialog_service.dart`

**Interfaces:**
- Consumes all interfaces from Tasks 1-5.
- Produces full tested flow: create internal project, import image folder, label, confirm, autosave, return to home with a fresh controller, open saved project from internal list, verify restored state.

- [ ] **Step 1: Add internal project library integration test**

Append this test to `test/integration/mvp_flow_test.dart`:

```dart
  test('internal project library create save list and reopen flow', () async {
    final tempDir = await Directory.systemTemp.createTemp('bbox_library_flow');
    addTearDown(() => tempDir.delete(recursive: true));

    final imageDir = Directory('${tempDir.path}${Platform.pathSeparator}images');
    await imageDir.create();
    await File(
      '${imageDir.path}${Platform.pathSeparator}a.jpg',
    ).writeAsBytes(img.encodeJpg(img.Image(width: 100, height: 80)));

    final library = ProjectLibrary(
      rootPath: '${tempDir.path}${Platform.pathSeparator}appdata',
      clock: () => DateTime.utc(2026, 7, 7, 5, 30),
      idGenerator: (name, timestamp) => 'flow-project',
    );
    final controller = AppController(projectLibrary: library);

    await controller.createLibraryProject('Library Demo');
    await controller.importImagesFromFolder(imageDir.path);

    controller.selectBox(controller.selectedImage!.visibleBoxes.single.id);
    final label = controller.addLabel('Person', 0xffe64a19);
    controller.assignSelectedBoxLabel(label.id);
    controller.confirmSelectedImage();
    await controller.saveProject();

    final freshController = AppController(projectLibrary: library);
    await freshController.loadProjectLibrary();

    expect(freshController.projectLibraryEntries.single.id, 'flow-project');
    expect(freshController.projectLibraryEntries.single.imageCount, 1);
    expect(freshController.projectLibraryEntries.single.confirmedImageCount, 1);

    await freshController.openLibraryProject('flow-project');

    expect(freshController.project!.name, 'Library Demo');
    expect(freshController.project!.imageFolderPath, imageDir.path);
    expect(freshController.project!.labels.single.name, 'Person');
    expect(freshController.project!.images.single.status, ImageStatus.confirmed);
    expect(freshController.project!.images.single.boxes.single.labelId, label.id);
  });
```

Add missing imports to the top of `mvp_flow_test.dart`:

```dart
import 'package:bbox_labeler/project/project_library.dart';
```

- [ ] **Step 2: Run failing integration test if imports or APIs are incomplete**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test test\integration\mvp_flow_test.dart
```

Expected: PASS if Tasks 1-5 are complete. If it fails with missing import or API drift, update the exact signature in implementation to match this plan, then rerun.

- [ ] **Step 3: Remove primary external project open/save UI paths**

In `lib/ui/windows_dialog_service.dart`, keep:

```dart
static Future<String?> pickFolder({String title = 'Select folder'})
static Future<String?> saveCocoFile()
```

Remove unused `openProjectFile()` and `saveProjectFile()` only after `rg -n "openProjectFile|saveProjectFile" lib test` shows no references.

Run:

```powershell
rg -n "openProjectFile|saveProjectFile" lib test
```

Expected before deletion: no references outside `lib\ui\windows_dialog_service.dart`.

- [ ] **Step 4: Run the full test suite**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test
```

Expected: all tests PASS.

- [ ] **Step 5: Run formatter and analyzer**

Run:

```powershell
& 'C:\tools\flutter\bin\cache\dart-sdk\bin\dart.exe' format --set-exit-if-changed .
& 'C:\tools\flutter\bin\flutter.bat' analyze
```

Expected: formatter exits `0`, analyzer prints `No issues found!`.

- [ ] **Step 6: Build Windows app**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' build windows
```

Expected: build succeeds and produces `build\windows\x64\runner\Release\bbox_labeler.exe`.

- [ ] **Step 7: Manual QA**

Run the built app:

```powershell
Start-Process -FilePath 'C:\workspace\bbox\build\windows\x64\runner\Release\bbox_labeler.exe'
```

Verify manually:

- first launch shows project home
- create project without choosing a save file
- select `C:\workspace\bbox\qa_samples\images` as image folder
- confirm the app imports sample images
- create a label and assign it to a box
- confirm an image
- close and reopen the app
- saved project appears in the project list
- opening the project restores images, labels, boxes, and status
- COCO export still asks for an export JSON path
- deleting a project does not delete `qa_samples\images`

- [ ] **Step 8: Commit or record skip**

Run:

```powershell
if ((Test-Path .git) -and (Get-Command git -ErrorAction SilentlyContinue)) {
  git add lib test docs/superpowers/plans/2026-07-07-internal-project-library.md
  git commit -m "test: verify internal project library flow"
} else {
  Write-Output "Commit skipped: git repository or git executable unavailable"
}
```

Expected in this workspace: `Commit skipped: git repository or git executable unavailable`.

---

## Self Review

Spec coverage:

- AppData storage: Task 1 implements `ProjectLibrary.appData` and the `%APPDATA%\BBoxLabeler\projects` layout.
- Internal project list: Tasks 1 and 3 implement `index.json`, list loading, and project home display.
- Create without save dialog: Tasks 2 and 3 route creation through `createLibraryProject`.
- Autosave to internal project file: Task 2 refreshes library metadata after save and autosave.
- Rename and delete: Task 5 implements project home actions and confirmation.
- Missing image folder and reconnect: Tasks 1, 2, and 4 implement detection and reconnect.
- Do not copy or delete images: Task 1 deletion test and Task 6 manual QA verify source images remain untouched.
- COCO export remains separate: Task 4 keeps `saveCocoFile`; Task 6 manual QA verifies export still asks for an output path.
- Project JSON schema compatibility: Task 1 keeps `ProjectStore` unchanged and uses existing schema version `1`.

Incomplete marker scan:

- The plan contains no incomplete markers such as deferred work labels or undefined future implementation notes.
- All referenced new types and methods are introduced before later tasks consume them.

Type consistency:

- `ProjectLibraryEntry`, `ProjectLibrary`, and `ReconnectImageFolderResult` names are consistent across tasks.
- Controller method names match the widget and integration tests.
- Widget keys match the tests exactly.

