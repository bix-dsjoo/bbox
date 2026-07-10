import 'package:bbox_labeler/ui/canvas_interaction.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveCanvasPointerAction', () {
    test('select tool resize handle has priority over moving', () {
      final action = resolveCanvasPointerAction(
        tool: CanvasTool.select,
        spacePressed: false,
        selectedBoxId: 'box-1',
        hitTarget: const CanvasHitTarget.resizeHandle('box-1'),
      );

      expect(action, CanvasPointerActionKind.resizingBox);
    });

    test('selected box drag moves the box', () {
      final action = resolveCanvasPointerAction(
        tool: CanvasTool.select,
        spacePressed: false,
        selectedBoxId: 'box-1',
        hitTarget: const CanvasHitTarget.box('box-1'),
      );

      expect(action, CanvasPointerActionKind.movingBox);
    });

    test('unselected box click selects the box', () {
      final action = resolveCanvasPointerAction(
        tool: CanvasTool.select,
        spacePressed: false,
        selectedBoxId: 'box-1',
        hitTarget: const CanvasHitTarget.box('box-2'),
      );

      expect(action, CanvasPointerActionKind.selectingBox);
    });

    test('space pressed forces canvas panning over drawing', () {
      final action = resolveCanvasPointerAction(
        tool: CanvasTool.drawBox,
        spacePressed: true,
        selectedBoxId: null,
        hitTarget: CanvasHitTarget.background,
      );

      expect(action, CanvasPointerActionKind.panningCanvas);
    });

    test('draw tool draws even when the pointer starts on a box', () {
      final action = resolveCanvasPointerAction(
        tool: CanvasTool.drawBox,
        spacePressed: false,
        selectedBoxId: null,
        hitTarget: const CanvasHitTarget.box('box-1'),
      );

      expect(action, CanvasPointerActionKind.drawingBox);
    });

    test('pan tool pans even when the pointer starts on a box', () {
      final action = resolveCanvasPointerAction(
        tool: CanvasTool.pan,
        spacePressed: false,
        selectedBoxId: 'box-1',
        hitTarget: const CanvasHitTarget.box('box-1'),
      );

      expect(action, CanvasPointerActionKind.panningCanvas);
    });

    test(
      'space pressed pans even when the pointer starts on a resize handle',
      () {
        final action = resolveCanvasPointerAction(
          tool: CanvasTool.select,
          spacePressed: true,
          selectedBoxId: 'box-1',
          hitTarget: const CanvasHitTarget.resizeHandle(
            'box-1',
            CanvasResizeHandle.bottomRight,
          ),
        );

        expect(action, CanvasPointerActionKind.panningCanvas);
      },
    );

    test('select tool background drag pans instead of drawing', () {
      final action = resolveCanvasPointerAction(
        tool: CanvasTool.select,
        spacePressed: false,
        selectedBoxId: null,
        hitTarget: CanvasHitTarget.background,
      );

      expect(action, CanvasPointerActionKind.panningCanvas);
    });
  });

  group('hitTestCanvas', () {
    test('selected box resize handle wins over box body', () {
      final hit = hitTestCanvas(
        canvasPoint: const Offset(100, 80),
        boxes: const [
          CanvasBoxHitArea(
            id: 'box-1',
            screenRect: Rect.fromLTWH(40, 40, 60, 40),
          ),
        ],
        selectedBoxId: 'box-1',
        handleSize: 14,
      );

      expect(hit, const CanvasHitTarget.resizeHandle('box-1'));
    });

    test('selected box top left resize handle is detected', () {
      final hit = hitTestCanvas(
        canvasPoint: const Offset(40, 40),
        boxes: const [
          CanvasBoxHitArea(
            id: 'box-1',
            screenRect: Rect.fromLTWH(40, 40, 60, 40),
          ),
        ],
        selectedBoxId: 'box-1',
        handleSize: 14,
      );

      expect(
        hit,
        const CanvasHitTarget.resizeHandle('box-1', CanvasResizeHandle.topLeft),
      );
    });

    test('topmost box is selected first when boxes overlap', () {
      final hit = hitTestCanvas(
        canvasPoint: const Offset(50, 50),
        boxes: const [
          CanvasBoxHitArea(
            id: 'bottom',
            screenRect: Rect.fromLTWH(10, 10, 80, 80),
          ),
          CanvasBoxHitArea(
            id: 'top',
            screenRect: Rect.fromLTWH(20, 20, 80, 80),
          ),
        ],
        selectedBoxId: null,
        handleSize: 14,
      );

      expect(hit, const CanvasHitTarget.box('top'));
    });

    test('background is returned when no box contains the point', () {
      final hit = hitTestCanvas(
        canvasPoint: const Offset(4, 4),
        boxes: const [
          CanvasBoxHitArea(
            id: 'box-1',
            screenRect: Rect.fromLTWH(20, 20, 80, 80),
          ),
        ],
        selectedBoxId: null,
        handleSize: 14,
      );

      expect(hit, CanvasHitTarget.background);
    });
  });

  group('normalizedImageRectFromCanvasDrag', () {
    test('converts canvas drag to normalized original image coordinates', () {
      final rect = normalizedImageRectFromCanvasDrag(
        start: const Offset(80, 60),
        end: const Offset(20, 10),
        scale: 2,
      );

      expect(rect.left, 10);
      expect(rect.top, 5);
      expect(rect.width, 30);
      expect(rect.height, 25);
    });
  });

  group('box resize geometry', () {
    test('screen deltas are divided by display scale and zoom', () {
      expect(
        originalDeltaFromScreenDelta(screenDelta: 20, displayScale: 2, zoom: 1),
        10,
      );
      expect(
        originalDeltaFromScreenDelta(screenDelta: 20, displayScale: 2, zoom: 4),
        2.5,
      );
    });

    test(
      'topLeft resize moves top and left while keeping bottom right fixed',
      () {
        final rect = resizeOriginalRect(
          startRect: const Rect.fromLTWH(20, 20, 40, 30),
          originalDelta: const Offset(5, 6),
          handle: CanvasResizeHandle.topLeft,
          imageSize: const Size(100, 100),
        );

        expect(rect, const Rect.fromLTWH(25, 26, 35, 24));
      },
    );

    test('right resize changes only the right side', () {
      final rect = resizeOriginalRect(
        startRect: const Rect.fromLTWH(20, 20, 40, 30),
        originalDelta: const Offset(10, 7),
        handle: CanvasResizeHandle.right,
        imageSize: const Size(100, 100),
      );

      expect(rect, const Rect.fromLTWH(20, 20, 50, 30));
    });

    test('resize clamps at minimum size instead of flipping', () {
      final rect = resizeOriginalRect(
        startRect: const Rect.fromLTWH(20, 20, 40, 30),
        originalDelta: const Offset(100, 100),
        handle: CanvasResizeHandle.topLeft,
        imageSize: const Size(100, 100),
        minSize: 2,
      );

      expect(rect.left, 58);
      expect(rect.top, 48);
      expect(rect.width, 2);
      expect(rect.height, 2);
    });
  });
}
