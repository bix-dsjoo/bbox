import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../annotation/default_labels.dart';
import '../annotation/models.dart';
import 'project_store.dart';

typedef Clock = DateTime Function();
typedef ProjectIdGenerator = String Function(String name, DateTime timestamp);
typedef ProjectLibraryOperationHook = Future<void> Function(String operation);
typedef ProjectIndexWriteHook = Future<void> Function();
typedef ProjectIndexBackupDelete = Future<void> Function(File backup);
typedef ProjectTombstoneDelete = Future<void> Function(Directory tombstone);
typedef ProjectFileExistsProbe = Future<bool> Function(File file);
typedef ProjectDirectoryExistsProbe =
    Future<bool> Function(Directory directory);
typedef ProjectDirectoryListProbe =
    Stream<FileSystemEntity> Function(Directory directory);

abstract final class ProjectLibraryOperation {
  static const create = 'create';
  static const importProject = 'import';
  static const rename = 'rename';
  static const delete = 'delete';
  static const refreshIndex = 'refresh-index';
  static const rebuildIndex = 'rebuild-index';
}

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
    this.imageCount = 0,
    this.confirmedImageCount = 0,
    this.errorImageCount = 0,
  });

  final String id;
  final String name;
  final String projectFilePath;
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
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      imageCount: json['imageCount'] as int? ?? 0,
      confirmedImageCount: json['confirmedImageCount'] as int? ?? 0,
      errorImageCount: json['errorImageCount'] as int? ?? 0,
    );
  }
}

class ProjectLibrary {
  ProjectLibrary({
    required this.rootPath,
    Clock? clock,
    ProjectIdGenerator? idGenerator,
    this.beforeOperation,
    this.beforeIndexWrite,
    ProjectIndexBackupDelete? deleteIndexBackup,
    ProjectTombstoneDelete? deleteTombstone,
    ProjectFileExistsProbe? indexBackupExists,
    ProjectDirectoryExistsProbe? indexBackupRootExists,
    ProjectDirectoryListProbe? indexBackupRootList,
    ProjectDirectoryExistsProbe? tombstoneExists,
  }) : _clock = clock ?? DateTime.now,
       _idGenerator = idGenerator ?? _defaultProjectId,
       _deleteIndexBackup = deleteIndexBackup ?? _deleteFile,
       _deleteTombstone = deleteTombstone ?? _deleteDirectory,
       _indexBackupExists = indexBackupExists ?? _fileExists,
       _indexBackupRootExists = indexBackupRootExists ?? _directoryExists,
       _indexBackupRootList = indexBackupRootList ?? _listDirectory,
       _tombstoneExists = tombstoneExists ?? _directoryExists;

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
  final ProjectLibraryOperationHook? beforeOperation;
  final ProjectIndexWriteHook? beforeIndexWrite;
  final ProjectIndexBackupDelete _deleteIndexBackup;
  final ProjectTombstoneDelete _deleteTombstone;
  final ProjectFileExistsProbe _indexBackupExists;
  final ProjectDirectoryExistsProbe _indexBackupRootExists;
  final ProjectDirectoryListProbe _indexBackupRootList;
  final ProjectDirectoryExistsProbe _tombstoneExists;
  Future<void> _operationTail = Future<void>.value();

  String get projectsRootPath => p.join(rootPath, 'projects');
  String get indexFilePath => p.join(projectsRootPath, 'index.json');

  Future<List<ProjectLibraryEntry>> listProjects() =>
      _serialize(null, _listProjectsUnlocked);

  Future<List<ProjectLibraryEntry>> _listProjectsUnlocked() async {
    try {
      final entries = await _readIndex();
      return _sorted(entries);
    } on FormatException {
      return _rebuildIndexUnlocked();
    } on FileSystemException {
      return _rebuildIndexUnlocked();
    } on TypeError {
      return _rebuildIndexUnlocked();
    }
  }

  Future<AnnotationProject> createProject(String name) => _serialize(
    ProjectLibraryOperation.create,
    () => _createProjectUnlocked(name),
  );

  Future<AnnotationProject> _createProjectUnlocked(String name) async {
    final timestamp = _clock().toUtc();
    final id = await _uniqueProjectId(name, timestamp);
    final projectFilePath = p.join(projectsRootPath, id, 'project.bbox.json');
    final projectDirectory = _checkedProjectDirectory(id, projectFilePath);
    try {
      final project = AnnotationProject.empty(name: _normalizeName(name))
          .copyWith(
            projectFilePath: projectFilePath,
            status: ProjectStatus.ready,
            labels: createDefaultLabels(),
          );
      final saved = await ProjectStore.save(project, projectFilePath);
      await _refreshEntryUnlocked(
        saved,
        createdAt: timestamp,
        updatedAt: timestamp,
      );
      return saved;
    } catch (_) {
      await _deleteProjectDirectoryIfPresent(id, projectDirectory);
      rethrow;
    }
  }

  Future<AnnotationProject> importProject(AnnotationProject source) =>
      _serialize(
        ProjectLibraryOperation.importProject,
        () => _importProjectUnlocked(source),
      );

  Future<AnnotationProject> _importProjectUnlocked(
    AnnotationProject source,
  ) async {
    final timestamp = _clock().toUtc();
    final id = await _uniqueProjectId(source.name, timestamp);
    final targetPath = p.join(projectsRootPath, id, 'project.bbox.json');
    final projectDirectory = _checkedProjectDirectory(id, targetPath);
    final imported = source.copyWith(
      projectFilePath: targetPath,
      status: ProjectStatus.ready,
    );
    try {
      final saved = await ProjectStore.save(imported, targetPath);
      await _refreshEntryUnlocked(
        saved,
        createdAt: timestamp,
        updatedAt: timestamp,
      );
      return saved;
    } catch (_) {
      await _deleteProjectDirectoryIfPresent(id, projectDirectory);
      rethrow;
    }
  }

  Future<AnnotationProject> openProject(String id) =>
      _serialize(null, () => _openProjectUnlocked(id));

  Future<AnnotationProject> _openProjectUnlocked(String id) async {
    final entries = await _listProjectsUnlocked();
    final entry = entries.firstWhere(
      (entry) => entry.id == id,
      orElse: () => throw StateError('Project not found: $id'),
    );
    final projectFilePath = _checkedProjectFilePath(
      entry.id,
      entry.projectFilePath,
    );
    return ProjectStore.load(projectFilePath);
  }

  Future<AnnotationProject> renameProject(String id, String name) => _serialize(
    ProjectLibraryOperation.rename,
    () => _renameProjectUnlocked(id, name),
  );

  Future<AnnotationProject> _renameProjectUnlocked(
    String id,
    String name,
  ) async {
    final project = await _openProjectUnlocked(id);
    final projectFilePath = project.projectFilePath!;
    _checkedProjectDirectory(id, projectFilePath);
    final projectFile = File(projectFilePath);
    final originalBytes = await projectFile.readAsBytes();
    final renamed = project.copyWith(name: _normalizeName(name));
    try {
      final saved = await ProjectStore.save(renamed, projectFilePath);
      await _refreshEntryUnlocked(saved);
      return saved;
    } catch (_) {
      await projectFile.writeAsBytes(originalBytes, flush: true);
      rethrow;
    }
  }

  Future<void> deleteProject(String id) => _serialize(
    ProjectLibraryOperation.delete,
    () => _deleteProjectUnlocked(id),
  );

  Future<void> _deleteProjectUnlocked(String id) async {
    final entries = await _listProjectsUnlocked();
    final entry = entries.firstWhere(
      (entry) => entry.id == id,
      orElse: () => throw StateError('Project not found: $id'),
    );
    final projectDir = _checkedProjectDirectory(
      entry.id,
      entry.projectFilePath,
    );
    Directory? tombstone;
    if (await projectDir.exists()) {
      tombstone = await _nextTombstone(projectDir);
      await projectDir.rename(tombstone.path);
    }
    try {
      await _writeIndex(entries.where((entry) => entry.id != id).toList());
    } catch (_) {
      if (tombstone != null &&
          await tombstone.exists() &&
          !await projectDir.exists()) {
        await tombstone.rename(projectDir.path);
      }
      rethrow;
    }
    if (tombstone != null) await _deleteTombstoneBestEffort(tombstone);
  }

  Future<void> refreshEntry(
    AnnotationProject project, {
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => _serialize(
    ProjectLibraryOperation.refreshIndex,
    () => _refreshEntryUnlocked(
      project,
      createdAt: createdAt,
      updatedAt: updatedAt,
    ),
  );

  Future<void> _refreshEntryUnlocked(
    AnnotationProject project, {
    DateTime? createdAt,
    DateTime? updatedAt,
  }) async {
    final projectFilePath = project.projectFilePath;
    if (projectFilePath == null) {
      throw StateError('Project file path is required.');
    }
    final id = p.basename(p.dirname(projectFilePath));
    _checkedProjectFilePath(id, projectFilePath);
    final entries = await _listProjectsUnlocked();
    for (final entry in entries) {
      _checkedProjectFilePath(entry.id, entry.projectFilePath);
    }
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

  Future<List<ProjectLibraryEntry>> rebuildIndex() =>
      _serialize(ProjectLibraryOperation.rebuildIndex, _rebuildIndexUnlocked);

  Future<List<ProjectLibraryEntry>> _rebuildIndexUnlocked() async {
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
      if (_isTombstoneDirectory(entity)) {
        await _deleteTombstoneBestEffort(entity);
        continue;
      }
      final projectFile = File(p.join(entity.path, 'project.bbox.json'));
      if (!await projectFile.exists()) {
        continue;
      }
      try {
        final project = await ProjectStore.load(projectFile.path);
        final timestamp = project.lastSavedAt?.toUtc() ?? _clock().toUtc();
        final id = p.basename(entity.path);
        _checkedProjectFilePath(id, project.projectFilePath!);
        entries.add(
          _entryFromProject(
            id: id,
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
    await beforeIndexWrite?.call();
    final file = File(indexFilePath);
    await file.parent.create(recursive: true);
    await _cleanupStaleIndexBackupsBestEffort();
    const encoder = JsonEncoder.withIndent('  ');
    final temp = File(
      '$indexFilePath.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    final backup = File(
      '$indexFilePath.bak-${DateTime.now().microsecondsSinceEpoch}',
    );
    var movedExisting = false;
    try {
      await temp.writeAsString(
        encoder.convert({
          'schemaVersion': currentIndexSchemaVersion,
          'projects': _sorted(entries).map((entry) => entry.toJson()).toList(),
        }),
        encoding: utf8,
        flush: true,
      );
      if (await file.exists()) {
        await file.rename(backup.path);
        movedExisting = true;
      }
      await temp.rename(file.path);
    } catch (error, stackTrace) {
      if (movedExisting && !await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      await _deleteFileBestEffort(temp);
      Error.throwWithStackTrace(error, stackTrace);
    }
    await _deleteIndexBackupBestEffort(backup);
    await _cleanupStaleIndexBackupsBestEffort();
  }

  Future<T> _serialize<T>(String? operation, Future<T> Function() action) {
    final result = _operationTail.then((_) async {
      if (operation != null) await beforeOperation?.call(operation);
      return action();
    });
    _operationTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  String _checkedProjectFilePath(String id, String projectFilePath) {
    final root = p.normalize(Directory(projectsRootPath).absolute.path);
    final expected = p.normalize(
      File(p.join(projectsRootPath, id, 'project.bbox.json')).absolute.path,
    );
    final normalizedPath = p.normalize(File(projectFilePath).absolute.path);
    final expectedDirectory = p.dirname(expected);
    if (!p.isWithin(root, expectedDirectory) ||
        !p.equals(normalizedPath, expected)) {
      throw StateError('Refusing to mutate outside the project library.');
    }
    return normalizedPath;
  }

  Directory _checkedProjectDirectory(String id, String projectFilePath) {
    return Directory(p.dirname(_checkedProjectFilePath(id, projectFilePath)));
  }

  Future<void> _deleteProjectDirectoryIfPresent(
    String id,
    Directory directory,
  ) async {
    _checkedProjectDirectory(id, p.join(directory.path, 'project.bbox.json'));
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<Directory> _nextTombstone(Directory projectDirectory) async {
    final baseName = p.basename(projectDirectory.path);
    var suffix = DateTime.now().microsecondsSinceEpoch;
    while (true) {
      final candidate = Directory(
        p.join(projectsRootPath, '$baseName.deleting-$suffix'),
      ).absolute;
      _checkedLibraryDirectory(candidate);
      if (!await candidate.exists()) return candidate;
      suffix += 1;
    }
  }

  Directory _checkedLibraryDirectory(Directory directory) {
    final root = p.normalize(Directory(projectsRootPath).absolute.path);
    final normalized = p.normalize(directory.absolute.path);
    if (!p.isWithin(root, normalized)) {
      throw StateError('Refusing to mutate outside the project library.');
    }
    return Directory(normalized);
  }

  bool _isTombstoneDirectory(Directory directory) =>
      p.basename(directory.path).contains('.deleting-');

  Future<void> _deleteFileBestEffort(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A failed cleanup must not change an already committed index write.
    }
  }

  Future<void> _deleteIndexBackupBestEffort(File backup) async {
    try {
      if (await _indexBackupExists(backup)) await _deleteIndexBackup(backup);
    } catch (_) {
      // Stale backups are retried by later index writes.
    }
  }

  Future<void> _cleanupStaleIndexBackupsBestEffort() async {
    final root = Directory(projectsRootPath);
    try {
      if (!await _indexBackupRootExists(root)) return;
      final prefix = '${p.basename(indexFilePath)}.bak-';
      await for (final entity in _indexBackupRootList(root)) {
        if (entity is File && p.basename(entity.path).startsWith(prefix)) {
          await _deleteIndexBackupBestEffort(entity);
        }
      }
    } catch (_) {
      // Index writes do not depend on cleanup of older unique backup files.
    }
  }

  Future<void> _deleteTombstoneBestEffort(Directory tombstone) async {
    try {
      if (await _tombstoneExists(tombstone)) {
        await _deleteTombstone(tombstone);
      }
    } catch (_) {
      // Tombstones are excluded from rebuilds and may be cleaned up later.
    }
  }

  static Future<void> _deleteFile(File file) => file.delete();

  static Future<void> _deleteDirectory(Directory directory) =>
      directory.delete(recursive: true);

  static Future<bool> _fileExists(File file) => file.exists();

  static Future<bool> _directoryExists(Directory directory) =>
      directory.exists();

  static Stream<FileSystemEntity> _listDirectory(Directory directory) =>
      directory.list(followLinks: false);

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
