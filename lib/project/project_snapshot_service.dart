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
    : this._(clock, _defaultRenameFile);

  ProjectSnapshotService.withFileRenamerForTesting({
    SnapshotClock? clock,
    required Future<File> Function(File source, String newPath) renameFile,
  }) : this._(clock, renameFile);

  ProjectSnapshotService._(SnapshotClock? clock, this._renameFile)
    : _clock = clock ?? DateTime.now;

  final SnapshotClock _clock;
  final Future<File> Function(File source, String newPath) _renameFile;

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
        await _renameFile(target, backup.path);
        targetMovedToBackup = true;
      }
      await _renameFile(temp, targetPath);
      if (await backup.exists()) {
        await backup.delete();
      }
    } catch (_) {
      if (targetMovedToBackup &&
          !await target.exists() &&
          await backup.exists()) {
        await _renameFile(backup, targetPath);
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

  static Future<File> _defaultRenameFile(File source, String newPath) {
    return source.rename(newPath);
  }

  Future<AnnotationProject> readSnapshot(String path) async {
    try {
      final rawText = await File(path).readAsString(encoding: utf8);
      final decoded = jsonDecode(rawText);
      if (decoded is! Map<String, Object?>) {
        throw const InvalidProjectSnapshotException(
          'the snapshot root must be a JSON object',
        );
      }
      _validateRawSnapshot(decoded);
      final loaded = await ProjectStore.load(path);
      final snapshot = loaded.copyWith(
        projectFilePath: null,
        status: ProjectStatus.ready,
      );
      _validate(snapshot);
      return snapshot;
    } on InvalidProjectSnapshotException {
      rethrow;
    } catch (error) {
      throw InvalidProjectSnapshotException('could not decode "$path": $error');
    }
  }

  void _validate(AnnotationProject project) {
    final labelIds = project.labels.map((label) => label.id).toSet();
    if (labelIds.length != project.labels.length) {
      throw const InvalidProjectSnapshotException('duplicate label id');
    }
    final labelNames = <String>{};
    final shortcuts = <String>{};
    for (final label in project.labels) {
      final normalizedName = label.name.trim().toLowerCase();
      if (!labelNames.add(normalizedName)) {
        throw InvalidProjectSnapshotException(
          'duplicate normalized label name "$normalizedName"',
        );
      }
      final shortcut = label.shortcut;
      if (shortcut != null) {
        final normalizedShortcut = shortcut.trim().toLowerCase();
        if (!shortcuts.add(normalizedShortcut)) {
          throw InvalidProjectSnapshotException(
            'duplicate label shortcut "$normalizedShortcut"',
          );
        }
      }
    }
    final imageIds = project.images.map((image) => image.id).toSet();
    if (imageIds.length != project.images.length) {
      throw const InvalidProjectSnapshotException('duplicate image id');
    }
    for (final image in project.images) {
      if (image.width <= 0) {
        throw InvalidProjectSnapshotException(
          'image ${image.id} width must be positive',
        );
      }
      if (image.height <= 0) {
        throw InvalidProjectSnapshotException(
          'image ${image.id} height must be positive',
        );
      }
      final boxIds = image.boxes.map((box) => box.id).toSet();
      if (boxIds.length != image.boxes.length) {
        throw InvalidProjectSnapshotException(
          'duplicate box id in image ${image.id}',
        );
      }
      for (final box in image.boxes) {
        if (!box.x.isFinite ||
            !box.y.isFinite ||
            !box.width.isFinite ||
            !box.height.isFinite) {
          throw InvalidProjectSnapshotException(
            'box ${box.id} in image ${image.id} must use finite coordinates',
          );
        }
        if (box.width <= 0 || box.height <= 0) {
          throw InvalidProjectSnapshotException(
            'box ${box.id} in image ${image.id} must have positive dimensions',
          );
        }
        if (box.x < 0 ||
            box.y < 0 ||
            box.x + box.width > image.width ||
            box.y + box.height > image.height) {
          throw InvalidProjectSnapshotException(
            'box ${box.id} in image ${image.id} must stay within image bounds',
          );
        }
        switch (box.status) {
          case BoxStatus.proposal:
            if (box.labelId != null || box.labelSource != null) {
              throw InvalidProjectSnapshotException(
                'proposal box ${box.id} must not have a label or label source',
              );
            }
          case BoxStatus.labeled:
            if (box.labelId == null || box.labelSource == null) {
              throw InvalidProjectSnapshotException(
                'labeled box ${box.id} requires a label and label source',
              );
            }
          case BoxStatus.deleted:
            if ((box.labelId == null) != (box.labelSource == null)) {
              throw InvalidProjectSnapshotException(
                'deleted box ${box.id} must keep label and label source together',
              );
            }
        }
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
        final candidateLabelIds = <int>{};
        for (final candidate
            in automation?.candidates ?? const <LabelCandidate>[]) {
          if (!candidateLabelIds.add(candidate.labelId)) {
            throw InvalidProjectSnapshotException(
              'duplicate candidate label ${candidate.labelId} for box ${box.id}',
            );
          }
          if (!labelIds.contains(candidate.labelId)) {
            throw InvalidProjectSnapshotException(
              'missing candidate label for box ${box.id}',
            );
          }
          if (!candidate.score.isFinite ||
              candidate.score < 0 ||
              candidate.score > 1) {
            throw InvalidProjectSnapshotException(
              'candidate score for label ${candidate.labelId} in box ${box.id} '
              'must be finite and between 0 and 1',
            );
          }
        }
        final confidence = box.confidence;
        if (confidence != null &&
            (!confidence.isFinite || confidence < 0 || confidence > 1)) {
          throw InvalidProjectSnapshotException(
            'confidence for box ${box.id} must be finite and between 0 and 1',
          );
        }
      }
    }
  }

  void _validateRawSnapshot(Map<String, Object?> raw) {
    final schemaVersion = _required<int>(raw, 'schemaVersion', r'$');
    if (schemaVersion != ProjectStore.currentSchemaVersion &&
        schemaVersion != 2) {
      throw InvalidProjectSnapshotException(
        'unsupported project schema version $schemaVersion',
      );
    }
    _required<String>(raw, 'name', r'$');
    _enumField(raw, 'status', r'$', {
      for (final value in ProjectStatus.values) value.name,
    });
    final labels = _requiredList(raw, 'labels', r'$');
    for (var labelIndex = 0; labelIndex < labels.length; labelIndex++) {
      final path = r'$.labels[' + '$labelIndex]';
      final label = _requiredObject(labels[labelIndex], path);
      _required<int>(label, 'id', path);
      _required<String>(label, 'name', path);
      _required<int>(label, 'color', path);
      _optional<String>(label, 'shortcut', path);
      _optional<String>(label, 'supercategory', path);
    }
    final images = _requiredList(raw, 'images', r'$');
    for (var imageIndex = 0; imageIndex < images.length; imageIndex++) {
      final path = r'$.images[' + '$imageIndex]';
      final image = _requiredObject(images[imageIndex], path);
      _required<int>(image, 'id', path);
      _required<String>(image, 'sourcePath', path);
      _required<String>(image, 'displayName', path);
      _required<int>(image, 'width', path);
      _required<int>(image, 'height', path);
      _enumField(image, 'status', path, {
        for (final value in ImageStatus.values) value.name,
      });
      final boxes = _requiredList(image, 'boxes', path);
      for (var boxIndex = 0; boxIndex < boxes.length; boxIndex++) {
        final boxPath = '$path.boxes[$boxIndex]';
        final box = _requiredObject(boxes[boxIndex], boxPath);
        _required<String>(box, 'id', boxPath);
        _required<num>(box, 'x', boxPath);
        _required<num>(box, 'y', boxPath);
        _required<num>(box, 'width', boxPath);
        _required<num>(box, 'height', boxPath);
        _enumField(box, 'status', boxPath, {
          for (final value in BoxStatus.values) value.name,
        });
        if (schemaVersion >= ProjectStore.currentSchemaVersion &&
            box['labelSource'] != null) {
          _enumField(box, 'labelSource', boxPath, {
            for (final value in LabelSource.values) value.name,
          });
        }
        _optional<int>(box, 'labelId', boxPath);
        _optional<num>(box, 'confidence', boxPath);
        final automationValue = box['automation'];
        if (automationValue != null) {
          final automation = _requiredObject(
            automationValue,
            '$boxPath.automation',
          );
          _required<String>(
            automation,
            'pipelineVersion',
            '$boxPath.automation',
          );
          _required<String>(automation, 'policyVersion', '$boxPath.automation');
          _required<String>(
            automation,
            'detectorSha256',
            '$boxPath.automation',
          );
          _optional<bool>(automation, 'embeddingUsed', '$boxPath.automation');
          final candidates = _requiredList(
            automation,
            'candidates',
            '$boxPath.automation',
          );
          for (
            var candidateIndex = 0;
            candidateIndex < candidates.length;
            candidateIndex++
          ) {
            final candidatePath =
                '$boxPath.automation.candidates[$candidateIndex]';
            final candidate = _requiredObject(
              candidates[candidateIndex],
              candidatePath,
            );
            _required<int>(candidate, 'labelId', candidatePath);
            _required<num>(candidate, 'score', candidatePath);
          }
        }
      }
    }
  }

  T _required<T>(Map<String, Object?> object, String key, String path) {
    final value = object[key];
    if (!object.containsKey(key) || value is! T) {
      throw InvalidProjectSnapshotException(
        '$path.$key must be ${_typeName<T>()}',
      );
    }
    return value;
  }

  void _optional<T>(Map<String, Object?> object, String key, String path) {
    final value = object[key];
    if (value != null && value is! T) {
      throw InvalidProjectSnapshotException(
        '$path.$key must be null or ${_typeName<T>()}',
      );
    }
  }

  List<Object?> _requiredList(
    Map<String, Object?> object,
    String key,
    String path,
  ) => _required<List<Object?>>(object, key, path);

  Map<String, Object?> _requiredObject(Object? value, String path) {
    if (value is! Map<String, Object?>) {
      throw InvalidProjectSnapshotException('$path must be a JSON object');
    }
    return value;
  }

  void _enumField(
    Map<String, Object?> object,
    String key,
    String path,
    Set<String> allowed,
  ) {
    final value = _required<String>(object, key, path);
    if (!allowed.contains(value)) {
      throw InvalidProjectSnapshotException(
        '$path.$key has unknown value "$value"; expected one of '
        '${allowed.join(', ')}',
      );
    }
  }

  String _typeName<T>() => T.toString();
}
