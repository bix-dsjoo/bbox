import 'models.dart';

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

class DuplicateLabelException implements Exception {
  DuplicateLabelException(this.name);

  final String name;

  @override
  String toString() => 'Duplicate label name: $name';
}

class LabelInUseException implements Exception {
  LabelInUseException(this.labelId);

  final int labelId;

  @override
  String toString() => 'Label is still used by boxes: $labelId';
}

class AnnotationValidationException implements Exception {
  AnnotationValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AnnotationRules {
  const AnnotationRules._();

  static bool isBoxValid(
    BoundingBox box, {
    required int imageWidth,
    required int imageHeight,
  }) {
    if (box.isDeleted) {
      return true;
    }
    if (box.width <= 0 || box.height <= 0) {
      return false;
    }
    if (box.x < 0 || box.y < 0) {
      return false;
    }
    if (box.x + box.width > imageWidth) {
      return false;
    }
    if (box.y + box.height > imageHeight) {
      return false;
    }
    return true;
  }

  static BoundingBox clampBox(
    BoundingBox box, {
    required int imageWidth,
    required int imageHeight,
    double minSize = 2,
  }) {
    final safeImageWidth = imageWidth.toDouble().clamp(1, double.infinity);
    final safeImageHeight = imageHeight.toDouble().clamp(1, double.infinity);
    final safeMinWidth = minSize.clamp(1, safeImageWidth);
    final safeMinHeight = minSize.clamp(1, safeImageHeight);
    final width = box.width.clamp(safeMinWidth, safeImageWidth).toDouble();
    final height = box.height.clamp(safeMinHeight, safeImageHeight).toDouble();
    final x = box.x.clamp(0, safeImageWidth - width).toDouble();
    final y = box.y.clamp(0, safeImageHeight - height).toDouble();

    return box.copyWith(x: x, y: y, width: width, height: height);
  }

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

  static AnnotationProject updateLabel(
    AnnotationProject project, {
    required int labelId,
    required String name,
    required int color,
    String? shortcut,
  }) {
    final existingLabel = project.labels.where((label) => label.id == labelId);
    if (existingLabel.isEmpty) {
      throw AnnotationValidationException('Label not found: $labelId');
    }
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

  static AnnotationProject renameLabel(
    AnnotationProject project, {
    required int labelId,
    required String name,
  }) {
    final trimmed = _normalizeDisplayName(name);
    _ensureUniqueLabelName(
      project.labels.where((label) => label.id != labelId),
      trimmed,
    );
    return project.copyWith(
      labels: [
        for (final label in project.labels)
          if (label.id == labelId) label.copyWith(name: trimmed) else label,
      ],
    );
  }

  static AnnotationProject deleteLabel(
    AnnotationProject project, {
    required int labelId,
  }) {
    final inUse = project.images.any(
      (image) => image.visibleBoxes.any(
        (box) => box.status == BoxStatus.labeled && box.labelId == labelId,
      ),
    );
    if (inUse) {
      throw LabelInUseException(labelId);
    }
    return project.copyWith(
      labels: project.labels.where((label) => label.id != labelId).toList(),
    );
  }

  static AnnotatedImage assignLabel(
    AnnotatedImage image, {
    required String boxId,
    required int labelId,
  }) {
    var found = false;
    final boxes = [
      for (final box in image.boxes)
        if (box.id == boxId)
          () {
            found = true;
            return box.copyWith(
              status: BoxStatus.labeled,
              labelId: labelId,
              labelSource: LabelSource.user,
              automation: box.automation?.copyWith(
                suggestedLabelId: null,
                reviewReasons: const [],
              ),
            );
          }()
        else
          box,
    ];
    if (!found) {
      throw AnnotationValidationException('Box not found: $boxId');
    }
    return image.copyWith(boxes: boxes);
  }

  static AnnotatedImage acceptSuggestedLabel(
    AnnotatedImage image, {
    required String boxId,
  }) {
    final matches = image.boxes.where((box) => box.id == boxId);
    if (matches.isEmpty) {
      throw AnnotationValidationException('Box not found: $boxId');
    }
    final suggestion = matches.single.automation?.suggestedLabelId;
    if (suggestion == null || !matches.single.requiresLabelReview) {
      throw AnnotationValidationException('Box has no reviewable suggestion.');
    }
    return assignLabel(image, boxId: boxId, labelId: suggestion);
  }

  static AnnotatedImage deleteBox(
    AnnotatedImage image, {
    required String boxId,
  }) {
    return image.copyWith(
      boxes: [
        for (final box in image.boxes)
          if (box.id == boxId)
            box.copyWith(
              status: BoxStatus.deleted,
              labelId: null,
              labelSource: null,
              automation: null,
            )
          else
            box,
      ],
    );
  }

  static bool canConfirm(AnnotatedImage image) {
    if (image.status == ImageStatus.error ||
        image.width <= 0 ||
        image.height <= 0) {
      return false;
    }
    for (final box in image.visibleBoxes) {
      if (!isBoxValid(
        box,
        imageWidth: image.width,
        imageHeight: image.height,
      )) {
        return false;
      }
      if (box.status != BoxStatus.labeled || box.labelId == null) {
        return false;
      }
    }
    return true;
  }

  static AnnotatedImage confirmImage(AnnotatedImage image) {
    if (!canConfirm(image)) {
      throw AnnotationValidationException('Image cannot be confirmed.');
    }
    return image.copyWith(status: ImageStatus.confirmed);
  }

  static String _normalizeDisplayName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw AnnotationValidationException('Label name is required.');
    }
    return trimmed;
  }

  static String _labelKey(String name) => name.trim().toLowerCase();

  static void _ensureUniqueLabelName(Iterable<LabelClass> labels, String name) {
    final key = _labelKey(name);
    final exists = labels.any((label) => _labelKey(label.name) == key);
    if (exists) {
      throw DuplicateLabelException(name);
    }
  }

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
}
