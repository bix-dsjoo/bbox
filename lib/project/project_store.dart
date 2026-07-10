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

  static const int currentSchemaVersion = 2;

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
    final version = json['schemaVersion'] as int? ?? 0;
    if (version != currentSchemaVersion) {
      throw UnsupportedProjectVersionException(version);
    }
    return AnnotationProject.fromJson(
      json,
    ).copyWith(projectFilePath: projectFilePath);
  }
}
