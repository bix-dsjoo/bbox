part of 'workbench_screen.dart';

bool _keyboardModifierPressed() {
  final keyboard = HardwareKeyboard.instance;
  return keyboard.isControlPressed ||
      keyboard.isMetaPressed ||
      keyboard.isAltPressed;
}

String _imageWorkSummary(AnnotatedImage image) {
  if (image.boxCount == 0) {
    return WorkbenchCopy.boxesNone;
  }
  if (image.unlabeledBoxCount > 0) {
    return '박스 ${image.boxCount}개 · 라벨 필요 ${image.unlabeledBoxCount}개';
  }
  return '박스 ${image.boxCount}개 · ${WorkbenchCopy.boxesLabeledComplete}';
}

String _boxOverlayDisplayLabel({
  required int displayNumber,
  required String label,
  required double boxScreenWidth,
  required TextDirection textDirection,
}) {
  const style = TextStyle(fontSize: 11, fontWeight: FontWeight.w700, height: 1);
  final numberedLabel = WorkbenchCopy.boxDisplayTitle(displayNumber, label);
  final textPainter = TextPainter(
    text: TextSpan(style: style, text: numberedLabel),
    textDirection: textDirection,
    maxLines: 1,
  );
  textPainter.layout();

  final badgeWidth = textPainter.width + 8;
  if (badgeWidth <= boxScreenWidth) {
    return numberedLabel;
  }
  return label;
}

Size _overlayBadgeSize(String label, TextDirection textDirection) {
  const style = TextStyle(fontSize: 11, fontWeight: FontWeight.w700, height: 1);
  final textPainter = TextPainter(
    text: TextSpan(style: style, text: label),
    textDirection: textDirection,
    maxLines: 1,
  )..layout();
  return Size(textPainter.width + 8, textPainter.height + 4);
}

Map<String, int> _boxDisplayNumbers(AnnotatedImage image) {
  final visibleBoxes = image.visibleBoxes.toList(growable: false);
  final originalOrder = <String, int>{};
  for (var index = 0; index < visibleBoxes.length; index++) {
    originalOrder[visibleBoxes[index].id] = index;
  }
  final sortedBoxes = visibleBoxes.toList(growable: false)
    ..sort((a, b) {
      if (!_sameVisualRow(a, b)) {
        return a.y.compareTo(b.y);
      }
      final leftComparison = a.x.compareTo(b.x);
      if (leftComparison != 0) {
        return leftComparison;
      }
      final topComparison = a.y.compareTo(b.y);
      if (topComparison != 0) {
        return topComparison;
      }
      return (originalOrder[a.id] ?? 0).compareTo(originalOrder[b.id] ?? 0);
    });

  final numbers = <String, int>{};
  var index = 1;
  for (final box in sortedBoxes) {
    numbers[box.id] = index;
    index += 1;
  }
  return numbers;
}

bool _sameVisualRow(BoundingBox a, BoundingBox b) {
  final rowTolerance = math.max(4.0, math.min(a.height, b.height) * 0.5);
  return (a.y - b.y).abs() <= rowTolerance;
}

int _boxDisplayNumber(Map<String, int> boxDisplayNumbers, BoundingBox box) {
  return boxDisplayNumbers[box.id] ?? 0;
}

LabelClass? _labelFor(AnnotationProject project, int? labelId) {
  if (labelId == null) {
    return null;
  }
  for (final label in project.labels) {
    if (label.id == labelId) {
      return label;
    }
  }
  return null;
}

LabelClass? _labelForShortcut(AnnotationProject project, String shortcut) {
  for (final label in project.labels) {
    if (label.shortcut == shortcut) {
      return label;
    }
  }
  return null;
}

String? _shortcutForKey(LogicalKeyboardKey key) {
  for (var index = 0; index < _quickLabelShortcutKeys.length; index++) {
    if (_quickLabelShortcutKeys[index] == key) {
      return _quickLabelShortcutLabels[index];
    }
  }
  return null;
}

_SidebarBoxGroups _sidebarBoxGroups(AnnotatedImage image) {
  final unlabeled = <BoundingBox>[];
  final labeled = <BoundingBox>[];
  final invalid = <BoundingBox>[];
  for (final box in image.visibleBoxes) {
    if (_boxIsInvalid(image, box)) {
      invalid.add(box);
    } else if (_boxNeedsLabel(box)) {
      unlabeled.add(box);
    } else {
      labeled.add(box);
    }
  }
  return _SidebarBoxGroups(
    unlabeled: unlabeled,
    labeled: labeled,
    invalid: invalid,
  );
}

bool _boxNeedsLabel(BoundingBox box) {
  return box.status != BoxStatus.labeled || box.labelId == null;
}

bool _boxIsInvalid(AnnotatedImage image, BoundingBox box) {
  return !AnnotationRules.isBoxValid(
    box,
    imageWidth: image.width,
    imageHeight: image.height,
  );
}
