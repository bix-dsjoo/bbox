import 'dart:math' as math;

import 'models.dart';

class BoxDisplayOrder {
  const BoxDisplayOrder._();

  static List<BoundingBox> sorted(AnnotatedImage image) {
    final indexed = <_IndexedBox>[
      for (var index = 0; index < image.boxes.length; index++)
        if (!image.boxes[index].isDeleted)
          _IndexedBox(image.boxes[index], index),
    ]..sort(_compareInitial);

    final rows = <_VisualRow>[];
    for (final item in indexed) {
      if (rows.isEmpty || !rows.last.accepts(item.box)) {
        rows.add(_VisualRow(item));
      } else {
        rows.last.items.add(item);
      }
    }

    return [
      for (final row in rows)
        ...([...row.items]..sort(_compareWithinRow)).map((item) => item.box),
    ];
  }

  static Map<String, int> numbers(AnnotatedImage image) {
    final ordered = sorted(image);
    return {
      for (var index = 0; index < ordered.length; index++)
        ordered[index].id: index + 1,
    };
  }

  static int _compareInitial(_IndexedBox a, _IndexedBox b) {
    final y = a.box.y.compareTo(b.box.y);
    if (y != 0) return y;
    final x = a.box.x.compareTo(b.box.x);
    if (x != 0) return x;
    return _stableTieBreak(a, b);
  }

  static int _compareWithinRow(_IndexedBox a, _IndexedBox b) {
    final x = a.box.x.compareTo(b.box.x);
    if (x != 0) return x;
    final y = a.box.y.compareTo(b.box.y);
    if (y != 0) return y;
    return _stableTieBreak(a, b);
  }

  static int _stableTieBreak(_IndexedBox a, _IndexedBox b) {
    final original = a.originalIndex.compareTo(b.originalIndex);
    return original != 0 ? original : a.box.id.compareTo(b.box.id);
  }
}

class _IndexedBox {
  const _IndexedBox(this.box, this.originalIndex);

  final BoundingBox box;
  final int originalIndex;
}

class _VisualRow {
  _VisualRow(_IndexedBox anchor)
    : anchorY = anchor.box.y,
      anchorHeight = anchor.box.height,
      items = [anchor];

  final double anchorY;
  final double anchorHeight;
  final List<_IndexedBox> items;

  bool accepts(BoundingBox box) {
    final tolerance = math.max(4.0, math.min(anchorHeight, box.height) * 0.5);
    return (box.y - anchorY).abs() <= tolerance;
  }
}
