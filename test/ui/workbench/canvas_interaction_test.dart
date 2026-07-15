// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image/image.dart' as img;

import 'workbench_test_support.dart';

void main() {
  group('WorkbenchScreen', () {
    testWidgets('canvas toolbar exposes select draw and pan tools', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));

      expect(find.byKey(const ValueKey('canvas-tool-select')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('canvas-tool-draw-box')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('canvas-tool-pan')), findsOneWidget);
      expect(find.text(WorkbenchCopy.selectMoveTool), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('canvas-tool-draw-box')));
      await tester.pump();

      expect(find.text(WorkbenchCopy.drawBoxTool), findsOneWidget);

      await tester.ensureVisible(find.byKey(const ValueKey('canvas-tool-pan')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('canvas-tool-pan')));
      await tester.pump();

      expect(find.text(WorkbenchCopy.panTool), findsOneWidget);
    });

    testWidgets('selected canvas tool uses orange selected styling', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));

      final selectedButton = tester.widget<TextButton>(
        find.widgetWithText(TextButton, WorkbenchCopy.selectMoveTool),
      );
      final style = selectedButton.style!;
      expect(
        style.backgroundColor?.resolve(<WidgetState>{}),
        WorkbenchPalette.accent,
      );
      expect(style.foregroundColor?.resolve(<WidgetState>{}), Colors.white);
    });

    testWidgets('keyboard switches canvas tools predictably', (tester) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));

      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.pump();

      expect(find.text(WorkbenchCopy.drawBoxTool), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(find.text(WorkbenchCopy.selectMoveTool), findsOneWidget);
    });

    testWidgets('default background drag pans instead of creating a box', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());
      final initialCount = controller.selectedImage!.boxCount;

      await tester.pumpWidget(app(controller));
      await tester.drag(
        find.byKey(const ValueKey('image-canvas')),
        const Offset(80, 60),
        warnIfMissed: false,
      );
      await tester.pump();

      expect(controller.selectedImage!.boxCount, initialCount);
      expect(find.text(WorkbenchCopy.selectMoveTool), findsOneWidget);
    });

    testWidgets('draw tool creates one box and stays in draw mode', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());
      final initialCount = controller.selectedImage!.boxCount;

      await tester.pumpWidget(app(controller));
      await tester.tap(find.byKey(const ValueKey('canvas-tool-draw-box')));
      await tester.pump();
      expect(find.text(WorkbenchCopy.drawBoxTool), findsOneWidget);

      await tester.drag(
        find.byKey(const ValueKey('image-canvas')),
        const Offset(80, 60),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(controller.selectedImage!.boxCount, initialCount + 1);
      expect(controller.selectedBoxId, startsWith('manual-'));

      await tester.drag(
        find.byKey(const ValueKey('image-canvas')),
        const Offset(-60, -40),
        warnIfMissed: false,
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(controller.selectedImage!.boxCount, initialCount + 2);
    });

    testWidgets('draw tool creates a box over an existing box after zooming', (
      tester,
    ) async {
      final tempDir = Directory.systemTemp.createTempSync(
        'bbox_zoom_draw_over_box',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final controller = AppController()
        ..loadProject(projectWithRenderedImage(tempDir));
      final initialCount = controller.selectedImage!.boxCount;

      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(controller));
      await tapVisible(tester, find.byKey(const ValueKey('zoom-in')));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('canvas-tool-draw-box')),
      );

      final existingBoxRect = tester.getRect(
        find.byKey(const ValueKey('box-box-1')),
      );
      await tester.dragFrom(existingBoxRect.center, const Offset(90, 70));
      await tester.pump(const Duration(milliseconds: 300));

      expect(controller.selectedImage!.boxCount, initialCount + 1);
      final drawn = controller.selectedBox!;
      expect(drawn.id, startsWith('manual-'));
      expect(drawn.width, greaterThan(0));
      expect(drawn.height, greaterThan(0));
    });

    testWidgets(
      'draw tool works across the zoomed viewport, not only canvas hit area',
      (tester) async {
        final tempDir = Directory.systemTemp.createTempSync(
          'bbox_zoom_draw_viewport_edge',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final controller = AppController()
          ..loadProject(projectWithRenderedImage(tempDir));
        final initialCount = controller.selectedImage!.boxCount;

        await tester.binding.setSurfaceSize(const Size(1440, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(app(controller));
        for (var index = 0; index < 7; index++) {
          await tapVisible(tester, find.byKey(const ValueKey('zoom-in')));
        }
        await tapVisible(
          tester,
          find.byKey(const ValueKey('canvas-tool-draw-box')),
        );

        final panelRect = tester.getRect(
          find.byKey(const ValueKey('annotation-canvas-panel')),
        );
        final start = Offset(panelRect.left + 52, panelRect.center.dy);
        await tester.dragFrom(start, const Offset(80, 60));
        await tester.pump(const Duration(milliseconds: 300));

        expect(controller.selectedImage!.boxCount, initialCount + 1);
        expect(controller.selectedBox!.id, startsWith('manual-'));
      },
    );

    testWidgets('pan tool never creates boxes from background drag', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());
      final initialCount = controller.selectedImage!.boxCount;

      await tester.pumpWidget(app(controller));
      await tester.ensureVisible(find.byKey(const ValueKey('canvas-tool-pan')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('canvas-tool-pan')));
      await tester.pump();

      await tester.drag(
        find.byKey(const ValueKey('image-canvas')),
        const Offset(80, 60),
      );
      await tester.pump();

      expect(controller.selectedImage!.boxCount, initialCount);
      expect(find.text(WorkbenchCopy.panTool), findsOneWidget);
    });

    testWidgets('select tool empty-space drag pans the zoomed image', (
      tester,
    ) async {
      final tempDir = Directory.systemTemp.createTempSync('bbox_select_pan');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final controller = AppController()
        ..loadProject(projectWithRenderedImage(tempDir));

      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(controller));
      for (var index = 0; index < 4; index++) {
        await tapVisible(tester, find.byKey(const ValueKey('zoom-in')));
      }
      final before = tester.getRect(find.byKey(const ValueKey('canvas-image')));

      await tester.dragFrom(before.center, const Offset(80, 40));
      await tester.pump();

      final after = tester.getRect(find.byKey(const ValueKey('canvas-image')));
      expect(after.left, greaterThan(before.left));
      expect(after.top, greaterThan(before.top));
      expect(controller.selectedImage!.boxes.single.x, 10);
      expect(controller.selectedImage!.boxes.single.y, 10);
    });

    testWidgets(
      'pan tool drag over a box pans without selecting or moving it',
      (tester) async {
        final tempDir = Directory.systemTemp.createTempSync(
          'bbox_pan_over_box',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final project = projectWithRenderedImage(tempDir);
        final controller = AppController()
          ..loadProject(
            project.copyWith(
              images: [
                project.images.first.copyWith(
                  boxes: const [
                    BoundingBox(
                      id: 'box-1',
                      x: 40,
                      y: 30,
                      width: 20,
                      height: 20,
                      status: BoxStatus.proposal,
                    ),
                  ],
                ),
                project.images.last,
              ],
            ),
          );
        controller.selectBox(null);
        final beforeBox = controller.selectedImage!.boxes.single;

        await tester.binding.setSurfaceSize(const Size(1440, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(app(controller));
        for (var index = 0; index < 4; index++) {
          await tapVisible(tester, find.byKey(const ValueKey('zoom-in')));
        }
        await tapVisible(tester, find.byKey(const ValueKey('canvas-tool-pan')));
        final beforeImage = tester.getRect(
          find.byKey(const ValueKey('canvas-image')),
        );

        await tester.drag(
          find.byKey(const ValueKey('box-box-1')),
          const Offset(90, 30),
        );
        await tester.pump(const Duration(milliseconds: 300));

        final afterImage = tester.getRect(
          find.byKey(const ValueKey('canvas-image')),
        );
        final afterBox = controller.selectedImage!.boxes.single;
        expect(afterImage.left, greaterThan(beforeImage.left));
        expect(afterImage.top, greaterThan(beforeImage.top));
        expect(controller.selectedBoxId, isNull);
        expect(afterBox.x, beforeBox.x);
        expect(afterBox.y, beforeBox.y);
      },
    );

    testWidgets('mouse wheel zoom changes scale and keeps cursor anchor', (
      tester,
    ) async {
      final tempDir = Directory.systemTemp.createTempSync('bbox_wheel_zoom');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final controller = AppController()
        ..loadProject(projectWithRenderedImage(tempDir));

      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(controller));

      final before = tester.getRect(find.byKey(const ValueKey('canvas-image')));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: before.center,
          scrollDelta: const Offset(0, -120),
        ),
      );
      await tester.pump();

      final after = tester.getRect(find.byKey(const ValueKey('canvas-image')));
      expect(after.width, greaterThan(before.width));
      expect(after.center.dx, closeTo(before.center.dx, 1));
      expect(after.center.dy, closeTo(before.center.dy, 1));
    });

    testWidgets('mouse wheel zoom works from empty viewport space', (
      tester,
    ) async {
      final tempDir = Directory.systemTemp.createTempSync(
        'bbox_wheel_viewport_space',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final controller = AppController()
        ..loadProject(projectWithRenderedImage(tempDir));

      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(controller));
      await tapVisible(tester, find.byKey(const ValueKey('zoom-actual')));

      final imageRect = tester.getRect(
        find.byKey(const ValueKey('canvas-image')),
      );
      final panelRect = tester.getRect(
        find.byKey(const ValueKey('annotation-canvas-panel')),
      );
      final wheelPosition = Offset(
        (imageRect.left - 40).clamp(panelRect.left + 20, imageRect.left - 1),
        imageRect.center.dy,
      );

      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: wheelPosition,
          scrollDelta: const Offset(0, -120),
        ),
      );
      await tester.pump();

      final after = tester.getRect(find.byKey(const ValueKey('canvas-image')));
      expect(after.width, greaterThan(imageRect.width));
    });

    testWidgets('space temporarily prioritizes panning while in draw mode', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());
      final initialCount = controller.selectedImage!.boxCount;

      await tester.pumpWidget(app(controller));
      await tester.tap(find.byKey(const ValueKey('canvas-tool-draw-box')));
      await tester.pump();
      expect(find.text(WorkbenchCopy.drawBoxTool), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(find.text(WorkbenchCopy.panTool), findsOneWidget);

      await tester.drag(
        find.byKey(const ValueKey('image-canvas')),
        const Offset(80, 60),
      );
      await tester.pump();

      expect(controller.selectedImage!.boxCount, initialCount);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(find.text(WorkbenchCopy.drawBoxTool), findsOneWidget);
    });

    testWidgets('dragging a selected box moves the box', (tester) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));
      controller.selectBox('box-1');
      await tester.pump();

      final before = controller.selectedImage!.boxes.single;
      await tester.drag(
        find.byKey(const ValueKey('selected-box-box-1')),
        const Offset(12, 8),
      );
      await tester.pump(const Duration(milliseconds: 300));

      final after = controller.selectedImage!.boxes.single;
      expect(after.x, greaterThan(before.x));
      expect(after.y, greaterThan(before.y));
      expect(after.width, before.width);
      expect(after.height, before.height);
    });

    testWidgets('zoomed selected box drag moves less in original pixels', (
      tester,
    ) async {
      final unzoomedController = AppController()..loadProject(project());
      unzoomedController.selectBox('box-1');

      await tester.pumpWidget(app(unzoomedController));
      final unzoomedBefore = unzoomedController.selectedImage!.boxes.single;
      await tester.drag(
        find.byKey(const ValueKey('selected-box-box-1')),
        const Offset(20, 0),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final unzoomedAfter = unzoomedController.selectedImage!.boxes.single;
      final unzoomedDelta = unzoomedAfter.x - unzoomedBefore.x;

      final zoomedController = AppController()..loadProject(project());
      zoomedController.selectBox('box-1');

      await tester.pumpWidget(app(zoomedController));
      await tapVisible(tester, find.byKey(const ValueKey('zoom-in')));
      final zoomedBefore = zoomedController.selectedImage!.boxes.single;
      await tester.drag(
        find.byKey(const ValueKey('selected-box-box-1')),
        const Offset(20, 0),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final zoomedAfter = zoomedController.selectedImage!.boxes.single;
      final zoomedDelta = zoomedAfter.x - zoomedBefore.x;

      expect(zoomedDelta, greaterThan(0));
      expect(zoomedDelta, lessThan(unzoomedDelta));
    });

    testWidgets('zoom keeps overlay box aligned with the rendered image', (
      tester,
    ) async {
      final tempDir = Directory.systemTemp.createTempSync(
        'bbox_zoom_overlay_alignment',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final imageFile = File('${tempDir.path}${Platform.pathSeparator}a.png');
      imageFile.writeAsBytesSync(img.encodePng(fixtureImage(100, 80)));
      final controller = AppController()
        ..loadProject(
          project().copyWith(
            images: [
              project().images.first.copyWith(sourcePath: imageFile.path),
              project().images.last,
            ],
          ),
        );
      controller.selectBox('box-1');

      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(controller));
      for (var index = 0; index < 7; index++) {
        await tapVisible(tester, find.byKey(const ValueKey('zoom-in')));
      }

      final imageRect = tester.getRect(
        find.byKey(const ValueKey('canvas-image')),
      );
      final boxRect = tester.getRect(
        find.byKey(const ValueKey('selected-box-box-1')),
      );

      expect(
        boxRect.width / imageRect.width,
        closeTo(
          controller.selectedBox!.width / controller.selectedImage!.width,
          0.01,
        ),
      );
      expect(
        boxRect.height / imageRect.height,
        closeTo(
          controller.selectedBox!.height / controller.selectedImage!.height,
          0.01,
        ),
      );
    });

    testWidgets('actual size and fit use different image scales', (
      tester,
    ) async {
      final tempDir = Directory.systemTemp.createTempSync(
        'bbox_zoom_actual_fit',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final imageFile = File('${tempDir.path}${Platform.pathSeparator}a.png');
      imageFile.writeAsBytesSync(img.encodePng(fixtureImage(100, 80)));
      final controller = AppController()
        ..loadProject(
          project().copyWith(
            images: [
              project().images.first.copyWith(sourcePath: imageFile.path),
              project().images.last,
            ],
          ),
        );

      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(controller));

      final fittedWidth = tester
          .getRect(find.byKey(const ValueKey('canvas-image')))
          .width;

      await tapVisible(tester, find.byKey(const ValueKey('zoom-actual')));
      final actualWidth = tester
          .getRect(find.byKey(const ValueKey('canvas-image')))
          .width;

      await tapVisible(tester, find.byKey(const ValueKey('zoom-fit')));
      final refittedWidth = tester
          .getRect(find.byKey(const ValueKey('canvas-image')))
          .width;

      expect(fittedWidth, greaterThan(100));
      expect(actualWidth, closeTo(100, 0.1));
      expect(refittedWidth, closeTo(fittedWidth, 0.1));
    });

    testWidgets(
      'box hit testing stays aligned after actual size zoom out fit and zoom in',
      (tester) async {
        final tempDir = Directory.systemTemp.createTempSync(
          'bbox_viewport_hit_alignment',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final controller = AppController()
          ..loadProject(projectWithRenderedImage(tempDir));

        await tester.binding.setSurfaceSize(const Size(1440, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(app(controller));
        await tapVisible(tester, find.byKey(const ValueKey('zoom-actual')));
        await tapVisible(tester, find.byKey(const ValueKey('zoom-out')));
        await tapVisible(tester, find.byKey(const ValueKey('zoom-fit')));
        await tapVisible(tester, find.byKey(const ValueKey('zoom-in')));

        controller.selectBox(null);
        await tester.pump();

        final visibleBoxCenter = tester.getCenter(
          find.byKey(const ValueKey('box-box-1')),
        );
        await tester.tapAt(visibleBoxCenter);
        await tester.pump();

        expect(controller.selectedBoxId, 'box-1');
      },
    );

    testWidgets(
      'move draw and resize use the same viewport transform after zoom mode changes',
      (tester) async {
        final tempDir = Directory.systemTemp.createTempSync(
          'bbox_viewport_edit_alignment',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final controller = AppController()
          ..loadProject(projectWithRenderedImage(tempDir));

        await tester.binding.setSurfaceSize(const Size(1440, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(app(controller));
        await tapVisible(tester, find.byKey(const ValueKey('zoom-actual')));
        await tapVisible(tester, find.byKey(const ValueKey('zoom-out')));
        await tapVisible(tester, find.byKey(const ValueKey('zoom-fit')));
        await tapVisible(tester, find.byKey(const ValueKey('zoom-in')));

        final initialBox = controller.selectedImage!.boxes.single;
        final boxCenter = tester.getCenter(
          find.byKey(const ValueKey('box-box-1')),
        );
        await tester.tapAt(boxCenter);
        await tester.pump();
        await tester.dragFrom(boxCenter, const Offset(24, 18));
        await tester.pump(const Duration(milliseconds: 300));

        final movedBox = controller.selectedImage!.boxes.single;
        expect(movedBox.x, greaterThan(initialBox.x));
        expect(movedBox.y, greaterThan(initialBox.y));

        final bottomRight = tester.getCenter(
          find.byKey(const ValueKey('resize-handle-box-1-bottomRight')),
        );
        await tester.dragFrom(bottomRight, const Offset(18, 12));
        await tester.pump(const Duration(milliseconds: 300));

        final resizedBox = controller.selectedImage!.boxes.single;
        expect(resizedBox.width, greaterThan(movedBox.width));
        expect(resizedBox.height, greaterThan(movedBox.height));

        final countBeforeDraw = controller.selectedImage!.boxCount;
        await tapVisible(
          tester,
          find.byKey(const ValueKey('canvas-tool-draw-box')),
        );
        final drawStart = tester.getCenter(
          find.byKey(const ValueKey('selected-box-box-1')),
        );
        await tester.dragFrom(drawStart, const Offset(48, 36));
        await tester.pump(const Duration(milliseconds: 300));

        expect(controller.selectedImage!.boxCount, countBeforeDraw + 1);
        expect(controller.selectedBox!.width, greaterThan(0));
        expect(controller.selectedBox!.height, greaterThan(0));
      },
    );

    testWidgets('dragging the resize handle changes box size only', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));
      controller.selectBox('box-1');
      await tester.pump();

      final before = controller.selectedImage!.boxes.single;
      await tester.drag(
        find.byKey(const ValueKey('resize-handle-box-1-bottomRight')),
        const Offset(14, 10),
      );
      await tester.pump(const Duration(milliseconds: 300));

      final after = controller.selectedImage!.boxes.single;
      expect(after.x, before.x);
      expect(after.y, before.y);
      expect(after.width, greaterThan(before.width));
      expect(after.height, greaterThan(before.height));
    });
  });
}
