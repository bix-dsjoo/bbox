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
  ProjectSnapshotService({SnapshotClock? clock})
    : _clock = clock ?? DateTime.now;

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
    final temp = File(
      '$targetPath.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    final backup = File(
      '$targetPath.bak-${DateTime.now().microsecondsSinceEpoch}',
    );
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
      if (await backup.exists()) {
        await backup.delete();
      }
    } catch (_) {
      if (targetMovedToBackup &&
          !await target.exists() &&
          await backup.exists()) {
        await backup.rename(targetPath);
      }
      rethrow;
    } finally {
      if (await temp.exists()) {
        await temp.delete();
      }
      if (await backup.exists() && await target.exists()) {
        await backup.delete();
      }
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
        for (final candidate
            in automation?.candidates ?? const <LabelCandidate>[]) {
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
