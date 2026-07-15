import 'dart:convert';
import 'dart:io';

import '../annotation/models.dart';

class UnsupportedProjectVersionException implements Exception {
  UnsupportedProjectVersionException(this.version);

  final int version;

  @override
  String toString() => 'Unsupported project schema version: $version';
}

class ProjectStore {
  const ProjectStore._();

  static const int currentSchemaVersion = 3;

  static Future<AnnotationProject> save(
    AnnotationProject project,
    String projectFilePath,
  ) async {
    final savedProject = project.copyWith(
      schemaVersion: currentSchemaVersion,
      projectFilePath: projectFilePath,
      lastSavedAt: DateTime.now().toUtc(),
    );
    final file = File(projectFilePath);
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(
      encoder.convert(savedProject.toJson()),
      encoding: utf8,
      flush: true,
    );
    return savedProject;
  }

  static Future<AnnotationProject> load(String projectFilePath) async {
    final file = File(projectFilePath);
    final raw = await file.readAsString(encoding: utf8);
    final json = jsonDecode(raw) as Map<String, Object?>;
    return decodeJson(json, projectFilePath: projectFilePath);
  }

  static AnnotationProject decodeJson(
    Map<String, Object?> json, {
    String? projectFilePath,
  }) {
    final migrated = _migrateToCurrent(json);
    final decoded = AnnotationProject.fromJson(migrated);
    return projectFilePath == null
        ? decoded
        : decoded.copyWith(projectFilePath: projectFilePath);
  }

  static Map<String, Object?> _migrateToCurrent(Map<String, Object?> json) {
    final version = json['schemaVersion'] as int? ?? 0;
    if (version == currentSchemaVersion) {
      return json;
    }
    if (version != 2) {
      throw UnsupportedProjectVersionException(version);
    }
    final migrated = Map<String, Object?>.from(json)
      ..['schemaVersion'] = currentSchemaVersion;
    final images = migrated['images'] as List<Object?>? ?? const [];
    migrated['images'] = [
      for (final image in images.cast<Map<String, Object?>>())
        _migrateImageV2(image),
    ];
    return migrated;
  }

  static Map<String, Object?> _migrateImageV2(Map<String, Object?> image) {
    final migrated = Map<String, Object?>.from(image)..['contentSha256'] = null;
    final boxes = migrated['boxes'] as List<Object?>? ?? const [];
    migrated['boxes'] = [
      for (final box in boxes.cast<Map<String, Object?>>()) _migrateBoxV2(box),
    ];
    return migrated;
  }

  static Map<String, Object?> _migrateBoxV2(Map<String, Object?> box) {
    final migrated = Map<String, Object?>.from(box);
    final isLabeled =
        migrated['status'] == 'labeled' && migrated['labelId'] != null;
    migrated['labelSource'] = isLabeled ? 'user' : null;
    migrated['automation'] = null;
    return migrated;
  }
}
