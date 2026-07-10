part of 'workbench_screen.dart';

class _ImageCanvas extends StatefulWidget {
  const _ImageCanvas({
    required this.controller,
    required this.project,
    required this.image,
    required this.zoom,
    required this.showActualSize,
    required this.panOffset,
    required this.tool,
    required this.editingLocked,
    required this.onPanOffsetChanged,
    required this.onViewportChanged,
    required this.onDrawingComplete,
  });

  final AppController controller;
  final AnnotationProject project;
  final AnnotatedImage image;
  final double zoom;
  final bool showActualSize;
  final Offset panOffset;
  final CanvasTool tool;
  final bool editingLocked;
  final ValueChanged<Offset> onPanOffsetChanged;
  final void Function({
    required double zoom,
    required bool showActualSize,
    required Offset panOffset,
  })
  onViewportChanged;
  final VoidCallback onDrawingComplete;

  @override
  State<_ImageCanvas> createState() => _ImageCanvasState();
}

class _ImageCanvasState extends State<_ImageCanvas> {
  CanvasPointerActionKind _activeAction = CanvasPointerActionKind.idle;
  CanvasHitTarget _activeHitTarget = CanvasHitTarget.background;
  Offset? _lastViewportPoint;
  Offset? _editStartPointerOriginal;
  Rect? _editStartOriginalRect;
  Rect? _editPreviewOriginalRect;
  Offset? _drawStartOriginal;
  Offset? _drawCurrentOriginal;
  bool _pointerMoved = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(
          math.max(1.0, constraints.maxWidth),
          math.max(1.0, constraints.maxHeight),
        );
        final unclampedTransform = _viewportTransformFor(
          viewportSize: viewportSize,
          panOffset: widget.panOffset,
        );
        final clampedPanOffset = _clampPanOffset(
          viewportSize: viewportSize,
          canvasSize: unclampedTransform.renderedImageSize,
          requested: widget.panOffset,
        );
        final transform = _viewportTransformFor(
          viewportSize: viewportSize,
          panOffset: clampedPanOffset,
        );
        final imageRect = Rect.fromLTWH(
          transform.imageOrigin.dx,
          transform.imageOrigin.dy,
          transform.renderedImageSize.width,
          transform.renderedImageSize.height,
        );
        final sourceImageFile = File(widget.image.sourcePath);
        final sourceImageExists = sourceImageFile.existsSync();
        final selectedBoxId = widget.controller.selectedBoxId;
        final boxDisplayNumbers = _boxDisplayNumbers(widget.image);
        final projections = _boxProjections(transform);
        final selected = <BoundingBox>[];
        final unselected = <BoundingBox>[];
        for (final box in widget.image.visibleBoxes) {
          if (box.id == selectedBoxId) {
            selected.add(box);
          } else {
            unselected.add(box);
          }
        }
        Rect? projectedRectFor(BoundingBox box) {
          for (final projection in projections) {
            if (projection.box.id == box.id) {
              return projection.screenRect;
            }
          }
          return null;
        }

        return Listener(
          key: const ValueKey('image-viewport'),
          behavior: HitTestBehavior.opaque,
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              _zoomFromWheel(
                event: event,
                viewportSize: viewportSize,
                transform: transform,
              );
            }
          },
          onPointerDown: widget.editingLocked
              ? null
              : (event) => _handlePointerDown(
                  event: event,
                  viewportSize: viewportSize,
                  transform: transform,
                  projections: projections,
                ),
          onPointerMove: widget.editingLocked
              ? null
              : (event) => _handlePointerMove(
                  event: event,
                  viewportSize: viewportSize,
                  transform: transform,
                ),
          onPointerUp: widget.editingLocked
              ? null
              : (event) => _handlePointerEnd(commit: true),
          onPointerCancel: widget.editingLocked
              ? null
              : (event) => _handlePointerEnd(commit: false),
          child: ClipRect(
            child: ClipRect(
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned.fromRect(
                    rect: imageRect,
                    child: Listener(
                      key: const ValueKey('image-canvas'),
                      behavior: HitTestBehavior.translucent,
                      child: SizedBox.expand(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surface,
                                border: Border.all(
                                  color: Theme.of(context).dividerColor,
                                ),
                              ),
                            ),
                            if (sourceImageExists)
                              Image.file(
                                sourceImageFile,
                                key: const ValueKey('canvas-image'),
                                fit: BoxFit.fill,
                                gaplessPlayback: true,
                                filterQuality: FilterQuality.medium,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  for (final box in unselected)
                    _BoxOverlay(
                      project: widget.project,
                      box: box,
                      displayNumber: _boxDisplayNumber(boxDisplayNumbers, box),
                      screenRect: projectedRectFor(box) ?? Rect.zero,
                      selected: false,
                      canEdit:
                          widget.tool == CanvasTool.select &&
                          !widget.editingLocked,
                    ),
                  for (final box in selected)
                    _BoxOverlay(
                      project: widget.project,
                      box: box,
                      displayNumber: _boxDisplayNumber(boxDisplayNumbers, box),
                      screenRect: projectedRectFor(box) ?? Rect.zero,
                      selected: true,
                      canEdit:
                          widget.tool == CanvasTool.select &&
                          !widget.editingLocked,
                    ),
                  if (_drawStartOriginal != null &&
                      _drawCurrentOriginal != null)
                    _DrawPreview(
                      start: transform.originalToScreen(_drawStartOriginal!),
                      end: transform.originalToScreen(_drawCurrentOriginal!),
                    ),
                  if (widget.editingLocked)
                    const Positioned(
                      top: 12,
                      left: 12,
                      child: _AutomationEditingLockedBadge(),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  ViewportTransform _viewportTransformFor({
    required Size viewportSize,
    required Offset panOffset,
  }) {
    final imageSize = Size(
      widget.image.width.toDouble(),
      widget.image.height.toDouble(),
    );
    final safeWidth = math.max(1.0, viewportSize.width - 24);
    final safeHeight = math.max(1.0, viewportSize.height - 24);
    final fitScale = math.min(
      safeWidth / math.max(1.0, imageSize.width),
      safeHeight / math.max(1.0, imageSize.height),
    );
    return ViewportTransform(
      imageSize: imageSize,
      viewportSize: viewportSize,
      baseScale: widget.showActualSize ? 1.0 : fitScale,
      zoom: widget.zoom,
      pan: panOffset,
    );
  }

  List<_CanvasBoxProjection> _boxProjections(ViewportTransform transform) {
    return [
      for (final box in widget.image.visibleBoxes)
        _CanvasBoxProjection(
          box: box,
          screenRect: transform.originalRectToScreen(_rectForBox(box)),
        ),
    ];
  }

  Rect _rectForBox(BoundingBox box) {
    if (_editPreviewOriginalRect != null &&
        box.id == widget.controller.selectedBoxId) {
      return _editPreviewOriginalRect!;
    }
    return Rect.fromLTWH(box.x, box.y, box.width, box.height);
  }

  void _handlePointerDown({
    required PointerDownEvent event,
    required Size viewportSize,
    required ViewportTransform transform,
    required List<_CanvasBoxProjection> projections,
  }) {
    if (event.buttons != kPrimaryMouseButton) {
      return;
    }
    final hitTarget = hitTestCanvas(
      canvasPoint: event.localPosition,
      boxes: [
        for (final projection in projections)
          CanvasBoxHitArea(
            id: projection.box.id,
            screenRect: projection.screenRect,
          ),
      ],
      selectedBoxId: widget.controller.selectedBoxId,
      handleSize: _resizeHandleHitSize,
    );
    final action = resolveCanvasPointerAction(
      tool: widget.tool,
      spacePressed: HardwareKeyboard.instance.logicalKeysPressed.contains(
        LogicalKeyboardKey.space,
      ),
      selectedBoxId: widget.controller.selectedBoxId,
      hitTarget: hitTarget,
    );

    _activeAction = action;
    _activeHitTarget = hitTarget;
    _lastViewportPoint = event.localPosition;
    _pointerMoved = false;

    final originalPoint = transform.clampOriginalPoint(
      transform.screenToOriginal(event.localPosition),
    );
    if (action == CanvasPointerActionKind.selectingBox) {
      widget.controller.selectBox(hitTarget.boxId);
    } else if (action == CanvasPointerActionKind.movingBox ||
        action == CanvasPointerActionKind.resizingBox) {
      final box = widget.controller.selectedBox;
      if (box == null) {
        _clearPointerState();
        return;
      }
      _editStartPointerOriginal = originalPoint;
      _editStartOriginalRect = Rect.fromLTWH(
        box.x,
        box.y,
        box.width,
        box.height,
      );
      _editPreviewOriginalRect = _editStartOriginalRect;
    } else if (action == CanvasPointerActionKind.drawingBox) {
      setState(() {
        _drawStartOriginal = originalPoint;
        _drawCurrentOriginal = originalPoint;
      });
    }
  }

  void _handlePointerMove({
    required PointerMoveEvent event,
    required Size viewportSize,
    required ViewportTransform transform,
  }) {
    if (_activeAction == CanvasPointerActionKind.idle) {
      return;
    }
    final previousPoint = _lastViewportPoint;
    if (previousPoint == null) {
      return;
    }
    final viewportDelta = event.localPosition - previousPoint;
    if (viewportDelta.distance > 0) {
      _pointerMoved = true;
    }
    _lastViewportPoint = event.localPosition;

    switch (_activeAction) {
      case CanvasPointerActionKind.panningCanvas:
        widget.onPanOffsetChanged(
          _clampPanOffset(
            viewportSize: viewportSize,
            canvasSize: transform.renderedImageSize,
            requested: transform.pan + viewportDelta,
          ),
        );
      case CanvasPointerActionKind.drawingBox:
        setState(() {
          _drawCurrentOriginal = transform.clampOriginalPoint(
            transform.screenToOriginal(event.localPosition),
          );
        });
      case CanvasPointerActionKind.movingBox:
        final startRect = _editStartOriginalRect;
        final startPoint = _editStartPointerOriginal;
        if (startRect == null || startPoint == null) {
          return;
        }
        final current = transform.clampOriginalPoint(
          transform.screenToOriginal(event.localPosition),
        );
        final delta = current - startPoint;
        setState(() {
          _editPreviewOriginalRect = _clampOriginalRect(
            Rect.fromLTWH(
              startRect.left + delta.dx,
              startRect.top + delta.dy,
              startRect.width,
              startRect.height,
            ),
          );
        });
      case CanvasPointerActionKind.resizingBox:
        final startRect = _editStartOriginalRect;
        final startPoint = _editStartPointerOriginal;
        final handle = _activeHitTarget.resizeHandle;
        if (startRect == null || startPoint == null || handle == null) {
          return;
        }
        final current = transform.clampOriginalPoint(
          transform.screenToOriginal(event.localPosition),
        );
        setState(() {
          _editPreviewOriginalRect = resizeOriginalRect(
            startRect: startRect,
            originalDelta: current - startPoint,
            handle: handle,
            imageSize: transform.imageSize,
          );
        });
      case CanvasPointerActionKind.selectingBox:
      case CanvasPointerActionKind.idle:
        return;
    }
  }

  void _handlePointerEnd({required bool commit}) {
    if (!commit) {
      _clearPointerState();
      return;
    }

    if (_activeAction == CanvasPointerActionKind.panningCanvas &&
        !_pointerMoved &&
        widget.tool == CanvasTool.select &&
        _activeHitTarget.type == CanvasHitTargetType.background) {
      widget.controller.selectBox(null);
    } else if (_activeAction == CanvasPointerActionKind.drawingBox) {
      _finishDrawing();
    } else if ((_activeAction == CanvasPointerActionKind.movingBox ||
            _activeAction == CanvasPointerActionKind.resizingBox) &&
        _editPreviewOriginalRect != null) {
      final rect = _editPreviewOriginalRect!;
      widget.controller.setSelectedBoxGeometry(
        x: rect.left,
        y: rect.top,
        width: rect.width,
        height: rect.height,
      );
    }

    _clearPointerState();
  }

  void _finishDrawing() {
    final start = _drawStartOriginal;
    final end = _drawCurrentOriginal;
    if (start == null || end == null) {
      return;
    }

    final normalized = _clampOriginalRect(Rect.fromPoints(start, end));

    widget.controller.addBox(
      x: normalized.left,
      y: normalized.top,
      width: normalized.width,
      height: normalized.height,
    );
    _clearDrawing();
    widget.onDrawingComplete();
  }

  Rect _clampOriginalRect(Rect rect) {
    final box = AnnotationRules.clampBox(
      BoundingBox(
        id: 'preview',
        x: rect.left,
        y: rect.top,
        width: rect.width,
        height: rect.height,
        status: BoxStatus.proposal,
      ),
      imageWidth: widget.image.width,
      imageHeight: widget.image.height,
      minSize: 2,
    );
    return Rect.fromLTWH(box.x, box.y, box.width, box.height);
  }

  void _clearDrawing() {
    _drawStartOriginal = null;
    _drawCurrentOriginal = null;
  }

  void _clearPointerState() {
    setState(() {
      _activeAction = CanvasPointerActionKind.idle;
      _activeHitTarget = CanvasHitTarget.background;
      _lastViewportPoint = null;
      _editStartPointerOriginal = null;
      _editStartOriginalRect = null;
      _editPreviewOriginalRect = null;
      _drawStartOriginal = null;
      _drawCurrentOriginal = null;
      _pointerMoved = false;
    });
  }

  void _zoomFromWheel({
    required PointerScrollEvent event,
    required Size viewportSize,
    required ViewportTransform transform,
  }) {
    final zoomFactor = event.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1;
    final nextZoom = (widget.zoom * zoomFactor).clamp(0.1, 8.0).toDouble();
    if (nextZoom == widget.zoom) {
      return;
    }
    final originalAnchor = transform.screenToOriginal(event.localPosition);
    final nextTransform = ViewportTransform(
      imageSize: transform.imageSize,
      viewportSize: viewportSize,
      baseScale: transform.baseScale,
      zoom: nextZoom,
      pan: Offset.zero,
    );
    final desiredOrigin =
        event.localPosition - originalAnchor * nextTransform.scale;
    final centeredOrigin = Offset(
      (viewportSize.width - nextTransform.renderedImageSize.width) / 2,
      (viewportSize.height - nextTransform.renderedImageSize.height) / 2,
    );
    final requestedPanOffset = desiredOrigin - centeredOrigin;
    widget.onViewportChanged(
      zoom: nextZoom,
      showActualSize: widget.showActualSize,
      panOffset: _clampPanOffset(
        viewportSize: viewportSize,
        canvasSize: nextTransform.renderedImageSize,
        requested: requestedPanOffset,
      ),
    );
  }

  Offset _clampPanOffset({
    required Size viewportSize,
    required Size canvasSize,
    required Offset requested,
  }) {
    final maxDx = math.max(0.0, (canvasSize.width - viewportSize.width) / 2);
    final maxDy = math.max(0.0, (canvasSize.height - viewportSize.height) / 2);
    return Offset(
      requested.dx.clamp(-maxDx, maxDx).toDouble(),
      requested.dy.clamp(-maxDy, maxDy).toDouble(),
    );
  }
}

class _CanvasBoxProjection {
  const _CanvasBoxProjection({required this.box, required this.screenRect});

  final BoundingBox box;
  final Rect screenRect;
}

class _DrawPreview extends StatelessWidget {
  const _DrawPreview({required this.start, required this.end});

  final Offset start;
  final Offset end;

  @override
  Widget build(BuildContext context) {
    final left = math.min(start.dx, end.dx);
    final top = math.min(start.dy, end.dy);
    final width = (start.dx - end.dx).abs();
    final height = (start.dy - end.dy).abs();
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.primary,
              width: 1.5,
            ),
            color: Theme.of(context).colorScheme.primary.withAlpha(24),
          ),
        ),
      ),
    );
  }
}

class _AutomationEditingLockedBadge extends StatelessWidget {
  const _AutomationEditingLockedBadge();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        key: const ValueKey('automation-editing-locked-overlay'),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface.withAlpha(230),
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(AppRadii.badge),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            WorkbenchCopy.automationEditingLocked,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _BoxOverlay extends StatelessWidget {
  const _BoxOverlay({
    required this.project,
    required this.box,
    required this.displayNumber,
    required this.screenRect,
    required this.selected,
    required this.canEdit,
  });

  final AnnotationProject project;
  final BoundingBox box;
  final int displayNumber;
  final Rect screenRect;
  final bool selected;
  final bool canEdit;

  @override
  Widget build(BuildContext context) {
    final label = _labelFor(project, box.labelId);
    final boxScreenWidth = screenRect.width;
    final boxScreenHeight = screenRect.height;
    final displayLabel = label?.name ?? WorkbenchCopy.unlabeledBox;
    final overlayLabel = label == null
        ? (selected
              ? WorkbenchCopy.boxDisplayTitle(
                  displayNumber,
                  WorkbenchCopy.unlabeledBox,
                )
              : WorkbenchCopy.boxDisplayNumber(displayNumber))
        : _boxOverlayDisplayLabel(
            displayNumber: displayNumber,
            label: label.name,
            boxScreenWidth: boxScreenWidth,
            textDirection: Directionality.of(context),
          );
    final semanticLabel = WorkbenchCopy.boxSemanticLabel(
      number: displayNumber,
      label: displayLabel,
      selected: selected,
    );
    final color = box.status == BoxStatus.proposal
        ? _automaticBoxColor
        : Color(label?.color ?? 0xffd32f2f);
    final fillAlpha = box.status == BoxStatus.proposal
        ? (selected ? _automaticBoxSelectedFillAlpha : _automaticBoxFillAlpha)
        : (selected ? _selectedBoxAlphaLabeled : 32);
    final handleHitSize = _resizeHandleHitSize;
    final overlayMargin = selected ? handleHitSize / 2 : 0.0;

    return Positioned(
      left: screenRect.left - overlayMargin,
      top: screenRect.top - overlayMargin,
      width: boxScreenWidth + overlayMargin * 2,
      height: boxScreenHeight + overlayMargin * 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: overlayMargin,
            top: overlayMargin,
            width: boxScreenWidth,
            height: boxScreenHeight,
            child: Semantics(
              container: true,
              label: semanticLabel,
              button: true,
              selected: selected,
              child: MouseRegion(
                cursor: selected && canEdit
                    ? SystemMouseCursors.move
                    : canEdit
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.basic,
                child: Container(
                  key: ValueKey(
                    selected ? 'selected-box-${box.id}' : 'box-${box.id}',
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: color, width: selected ? 3 : 2),
                    color: color.withAlpha(fillAlpha),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: overlayMargin,
            top: overlayMargin,
            child: IgnorePointer(
              child: CustomPaint(
                key: ValueKey('overlay-label-${box.id}'),
                size: _overlayBadgeSize(
                  overlayLabel,
                  Directionality.of(context),
                ),
                painter: _OverlayBadgePainter(
                  label: overlayLabel,
                  textColor: color,
                  backgroundColor: Colors.white.withAlpha(220),
                  textDirection: Directionality.of(context),
                ),
              ),
            ),
          ),
          if (selected)
            for (final handle in CanvasResizeHandle.values)
              if (canEdit)
                _ResizeHandle(
                  boxId: box.id,
                  handle: handle,
                  boxLeft: overlayMargin,
                  boxTop: overlayMargin,
                  boxWidth: boxScreenWidth,
                  boxHeight: boxScreenHeight,
                  hitSize: handleHitSize,
                  visualSize: _resizeHandleVisualSize,
                  color: color,
                ),
        ],
      ),
    );
  }
}

class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({
    required this.boxId,
    required this.handle,
    required this.boxLeft,
    required this.boxTop,
    required this.boxWidth,
    required this.boxHeight,
    required this.hitSize,
    required this.visualSize,
    required this.color,
  });

  final String boxId;
  final CanvasResizeHandle handle;
  final double boxLeft;
  final double boxTop;
  final double boxWidth;
  final double boxHeight;
  final double hitSize;
  final double visualSize;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final center = _centerForHandle(handle);
    return Positioned(
      left: center.dx - hitSize / 2,
      top: center.dy - hitSize / 2,
      width: hitSize,
      height: hitSize,
      child: MouseRegion(
        key: ValueKey('resize-handle-$boxId-${handle.name}'),
        cursor: _cursorForHandle(handle),
        child: Center(
          child: Container(
            key: ValueKey('resize-handle-visual-$boxId-${handle.name}'),
            width: visualSize,
            height: visualSize,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(_resizeHandleRadius),
              border: Border.all(color: color, width: 1.5),
            ),
          ),
        ),
      ),
    );
  }

  Offset _centerForHandle(CanvasResizeHandle handle) {
    return switch (handle) {
      CanvasResizeHandle.topLeft => Offset(boxLeft, boxTop),
      CanvasResizeHandle.top => Offset(boxLeft + boxWidth / 2, boxTop),
      CanvasResizeHandle.topRight => Offset(boxLeft + boxWidth, boxTop),
      CanvasResizeHandle.left => Offset(boxLeft, boxTop + boxHeight / 2),
      CanvasResizeHandle.right => Offset(
        boxLeft + boxWidth,
        boxTop + boxHeight / 2,
      ),
      CanvasResizeHandle.bottomLeft => Offset(boxLeft, boxTop + boxHeight),
      CanvasResizeHandle.bottom => Offset(
        boxLeft + boxWidth / 2,
        boxTop + boxHeight,
      ),
      CanvasResizeHandle.bottomRight => Offset(
        boxLeft + boxWidth,
        boxTop + boxHeight,
      ),
    };
  }

  MouseCursor _cursorForHandle(CanvasResizeHandle handle) {
    return switch (handle) {
      CanvasResizeHandle.topLeft || CanvasResizeHandle.bottomRight =>
        SystemMouseCursors.resizeUpLeftDownRight,
      CanvasResizeHandle.topRight ||
      CanvasResizeHandle.bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
      CanvasResizeHandle.top ||
      CanvasResizeHandle.bottom => SystemMouseCursors.resizeUpDown,
      CanvasResizeHandle.left ||
      CanvasResizeHandle.right => SystemMouseCursors.resizeLeftRight,
    };
  }
}

class _OverlayBadgePainter extends CustomPainter {
  const _OverlayBadgePainter({
    required this.label,
    required this.textColor,
    required this.backgroundColor,
    required this.textDirection,
  });

  final String label;
  final Color textColor;
  final Color backgroundColor;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final backgroundPaint = Paint()..color = backgroundColor;
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      backgroundPaint,
    );

    const textStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      height: 1,
    );
    final textPainter = TextPainter(
      text: TextSpan(
        style: textStyle.copyWith(color: textColor),
        text: label,
      ),
      textDirection: textDirection,
      maxLines: 1,
    )..layout(maxWidth: math.max(0.0, size.width - 8));
    textPainter.paint(canvas, const Offset(4, 2));
  }

  @override
  bool shouldRepaint(covariant _OverlayBadgePainter oldDelegate) {
    return oldDelegate.label != label ||
        oldDelegate.textColor != textColor ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.textDirection != textDirection;
  }
}
