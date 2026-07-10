import 'package:flutter/widgets.dart';

enum CanvasTool { select, drawBox, pan }

enum CanvasPointerActionKind {
  idle,
  panningCanvas,
  drawingBox,
  movingBox,
  resizingBox,
  selectingBox,
}

enum CanvasHitTargetType { background, box, resizeHandle }

enum CanvasResizeHandle {
  topLeft,
  top,
  topRight,
  left,
  right,
  bottomLeft,
  bottom,
  bottomRight,
}

class CanvasHitTarget {
  const CanvasHitTarget._(this.type, this.boxId, this.resizeHandle);

  const CanvasHitTarget.box(String boxId)
    : this._(CanvasHitTargetType.box, boxId, null);

  const CanvasHitTarget.resizeHandle(
    String boxId, [
    CanvasResizeHandle resizeHandle = CanvasResizeHandle.bottomRight,
  ]) : this._(CanvasHitTargetType.resizeHandle, boxId, resizeHandle);

  static const background = CanvasHitTarget._(
    CanvasHitTargetType.background,
    null,
    null,
  );

  final CanvasHitTargetType type;
  final String? boxId;
  final CanvasResizeHandle? resizeHandle;

  @override
  bool operator ==(Object other) {
    return other is CanvasHitTarget &&
        other.type == type &&
        other.boxId == boxId &&
        other.resizeHandle == resizeHandle;
  }

  @override
  int get hashCode => Object.hash(type, boxId, resizeHandle);
}

class CanvasBoxHitArea {
  const CanvasBoxHitArea({required this.id, required this.screenRect});

  final String id;
  final Rect screenRect;
}

CanvasPointerActionKind resolveCanvasPointerAction({
  required CanvasTool tool,
  required bool spacePressed,
  required String? selectedBoxId,
  required CanvasHitTarget hitTarget,
}) {
  if (spacePressed || tool == CanvasTool.pan) {
    return CanvasPointerActionKind.panningCanvas;
  }
  if (tool == CanvasTool.drawBox) {
    return CanvasPointerActionKind.drawingBox;
  }
  if (hitTarget.type == CanvasHitTargetType.resizeHandle) {
    return CanvasPointerActionKind.resizingBox;
  }
  if (hitTarget.type == CanvasHitTargetType.box) {
    return hitTarget.boxId == selectedBoxId
        ? CanvasPointerActionKind.movingBox
        : CanvasPointerActionKind.selectingBox;
  }
  return CanvasPointerActionKind.panningCanvas;
}

CanvasHitTarget hitTestCanvas({
  required Offset canvasPoint,
  required Iterable<CanvasBoxHitArea> boxes,
  required String? selectedBoxId,
  required double handleSize,
}) {
  final selectedBox = _firstBoxOrNull(boxes, (box) => box.id == selectedBoxId);
  if (selectedBox != null) {
    for (final entry in resizeHandleRects(
      selectedBox.screenRect,
      handleSize,
    ).entries) {
      if (entry.value.contains(canvasPoint)) {
        return CanvasHitTarget.resizeHandle(selectedBox.id, entry.key);
      }
    }
  }

  for (final box in boxes.toList().reversed) {
    if (box.screenRect.contains(canvasPoint)) {
      return CanvasHitTarget.box(box.id);
    }
  }

  return CanvasHitTarget.background;
}

Rect normalizedImageRectFromCanvasDrag({
  required Offset start,
  required Offset end,
  required double scale,
}) {
  final rect = Rect.fromPoints(start, end);
  return Rect.fromLTWH(
    rect.left / scale,
    rect.top / scale,
    rect.width / scale,
    rect.height / scale,
  );
}

double originalDeltaFromScreenDelta({
  required double screenDelta,
  required double displayScale,
  required double zoom,
}) {
  final safeDisplayScale = displayScale <= 0 ? 1.0 : displayScale;
  final safeZoom = zoom <= 0 ? 1.0 : zoom;
  return screenDelta / (safeDisplayScale * safeZoom);
}

Rect resizeOriginalRect({
  required Rect startRect,
  required Offset originalDelta,
  required CanvasResizeHandle handle,
  required Size imageSize,
  double minSize = 2,
}) {
  final safeImageWidth = imageSize.width.clamp(1, double.infinity).toDouble();
  final safeImageHeight = imageSize.height.clamp(1, double.infinity).toDouble();
  final safeMinWidth = minSize.clamp(1, safeImageWidth).toDouble();
  final safeMinHeight = minSize.clamp(1, safeImageHeight).toDouble();

  var left = startRect.left.clamp(0, safeImageWidth).toDouble();
  var top = startRect.top.clamp(0, safeImageHeight).toDouble();
  var right = startRect.right.clamp(0, safeImageWidth).toDouble();
  var bottom = startRect.bottom.clamp(0, safeImageHeight).toDouble();

  switch (handle) {
    case CanvasResizeHandle.topLeft:
      left = (left + originalDelta.dx).clamp(0, right - safeMinWidth);
      top = (top + originalDelta.dy).clamp(0, bottom - safeMinHeight);
    case CanvasResizeHandle.top:
      top = (top + originalDelta.dy).clamp(0, bottom - safeMinHeight);
    case CanvasResizeHandle.topRight:
      right = (right + originalDelta.dx).clamp(
        left + safeMinWidth,
        safeImageWidth,
      );
      top = (top + originalDelta.dy).clamp(0, bottom - safeMinHeight);
    case CanvasResizeHandle.left:
      left = (left + originalDelta.dx).clamp(0, right - safeMinWidth);
    case CanvasResizeHandle.right:
      right = (right + originalDelta.dx).clamp(
        left + safeMinWidth,
        safeImageWidth,
      );
    case CanvasResizeHandle.bottomLeft:
      left = (left + originalDelta.dx).clamp(0, right - safeMinWidth);
      bottom = (bottom + originalDelta.dy).clamp(
        top + safeMinHeight,
        safeImageHeight,
      );
    case CanvasResizeHandle.bottom:
      bottom = (bottom + originalDelta.dy).clamp(
        top + safeMinHeight,
        safeImageHeight,
      );
    case CanvasResizeHandle.bottomRight:
      right = (right + originalDelta.dx).clamp(
        left + safeMinWidth,
        safeImageWidth,
      );
      bottom = (bottom + originalDelta.dy).clamp(
        top + safeMinHeight,
        safeImageHeight,
      );
  }

  return Rect.fromLTRB(left, top, right, bottom);
}

Map<CanvasResizeHandle, Rect> resizeHandleRects(
  Rect boxRect,
  double handleSize,
) {
  Rect handleRect(Offset center) {
    return Rect.fromCenter(
      center: center,
      width: handleSize,
      height: handleSize,
    );
  }

  final centerX = boxRect.left + boxRect.width / 2;
  final centerY = boxRect.top + boxRect.height / 2;
  return {
    CanvasResizeHandle.topLeft: handleRect(boxRect.topLeft),
    CanvasResizeHandle.top: handleRect(Offset(centerX, boxRect.top)),
    CanvasResizeHandle.topRight: handleRect(boxRect.topRight),
    CanvasResizeHandle.left: handleRect(Offset(boxRect.left, centerY)),
    CanvasResizeHandle.right: handleRect(Offset(boxRect.right, centerY)),
    CanvasResizeHandle.bottomLeft: handleRect(boxRect.bottomLeft),
    CanvasResizeHandle.bottom: handleRect(Offset(centerX, boxRect.bottom)),
    CanvasResizeHandle.bottomRight: handleRect(boxRect.bottomRight),
  };
}

CanvasBoxHitArea? _firstBoxOrNull(
  Iterable<CanvasBoxHitArea> boxes,
  bool Function(CanvasBoxHitArea box) test,
) {
  for (final box in boxes) {
    if (test(box)) {
      return box;
    }
  }
  return null;
}
