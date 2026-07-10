import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../annotation/default_labels.dart';
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
        .copyWith(
          projectFilePath: projectFilePath,
          status: ProjectStatus.ready,
          labels: createDefaultLabels(),
        );
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
    final normalizedRoot = p.normalize(
      Directory(projectsRootPath).absolute.path,
    );
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
