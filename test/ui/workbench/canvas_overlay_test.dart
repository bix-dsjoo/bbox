// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image/image.dart' as img;

import 'workbench_test_support.dart';

void main() {
  group('WorkbenchScreen', () {
    testWidgets('canvas shows detector errors even when image file exists', (
      tester,
    ) async {
      final tempDir = Directory.systemTemp.createTempSync(
        'bbox_detector_error_visible',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final imageFile = File('${tempDir.path}${Platform.pathSeparator}a.png');
      imageFile.writeAsBytesSync(
        img.encodePng(img.Image(width: 80, height: 60)),
      );

      final controller = AppController();
      controller.loadProject(
        AnnotationProject.empty(name: 'demo').copyWith(
          status: ProjectStatus.ready,
          images: const [
            AnnotatedImage(
              id: 1,
              sourcePath: 'a.png',
              displayName: 'a.png',
              width: 80,
              height: 60,
              status: ImageStatus.error,
              errorMessage: '자동 박스 worker failed',
            ),
          ],
        ),
      );

      await tester.pumpWidget(app(controller));

      expect(find.text('자동 박스 worker failed'), findsWidgets);
    });

    testWidgets('canvas renders the selected source image behind boxes', (
      tester,
    ) async {
      final tempDir = Directory.systemTemp.createTempSync('bbox_canvas_image');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final imageFile = File('${tempDir.path}${Platform.pathSeparator}a.png');
      imageFile.writeAsBytesSync(img.encodePng(fixtureImage(100, 80)));

      final controller = AppController();
      controller.loadProject(
        project().copyWith(
          images: [
            project().images.first.copyWith(sourcePath: imageFile.path),
            project().images.last,
          ],
        ),
      );

      await tester.pumpWidget(app(controller));
      await tester.pump();

      final renderedImage = tester.widget<Image>(
        find.byKey(const ValueKey('canvas-image')),
      );
      expect(renderedImage.image, isA<FileImage>());
      expect(renderedImage.fit, BoxFit.fill);
    });

    testWidgets('selected box renders eight resize handles', (tester) async {
      final controller = AppController()..loadProject(project());
      controller.selectBox('box-1');

      await tester.pumpWidget(app(controller));

      for (final handle in [
        'topLeft',
        'top',
        'topRight',
        'left',
        'right',
        'bottomLeft',
        'bottom',
        'bottomRight',
      ]) {
        expect(
          find.byKey(ValueKey('resize-handle-box-1-$handle')),
          findsOneWidget,
        );
      }
    });

    testWidgets('selected resize handles are centered on box boundaries', (
      tester,
    ) async {
      final controller = AppController()..loadProject(project());
      controller.selectBox('box-1');

      await tester.pumpWidget(app(controller));

      final boxRect = tester.getRect(
        find.byKey(const ValueKey('selected-box-box-1')),
      );

      final topLeft = tester.getRect(
        find.byKey(const ValueKey('resize-handle-box-1-topLeft')),
      );
      final top = tester.getRect(
        find.byKey(const ValueKey('resize-handle-box-1-top')),
      );
      final right = tester.getRect(
        find.byKey(const ValueKey('resize-handle-box-1-right')),
      );
      final bottomRight = tester.getRect(
        find.byKey(const ValueKey('resize-handle-box-1-bottomRight')),
      );

      expect(topLeft.center.dx, closeTo(boxRect.left, 0.1));
      expect(topLeft.center.dy, closeTo(boxRect.top, 0.1));
      expect(top.center.dx, closeTo(boxRect.center.dx, 0.1));
      expect(top.center.dy, closeTo(boxRect.top, 0.1));
      expect(right.center.dx, closeTo(boxRect.right, 0.1));
      expect(right.center.dy, closeTo(boxRect.center.dy, 0.1));
      expect(bottomRight.center.dx, closeTo(boxRect.right, 0.1));
      expect(bottomRight.center.dy, closeTo(boxRect.bottom, 0.1));
    });

    testWidgets(
      'resize handle visual keeps the same screen size after zooming',
      (tester) async {
        final controller = AppController()..loadProject(project());
        controller.selectBox('box-1');

        await tester.pumpWidget(app(controller));
        final initialRect = tester.getRect(
          find.byKey(const ValueKey('resize-handle-visual-box-1-topLeft')),
        );

        await tapVisible(tester, find.byKey(const ValueKey('zoom-in')));

        final zoomedInRect = tester.getRect(
          find.byKey(const ValueKey('resize-handle-visual-box-1-topLeft')),
        );
        expect(zoomedInRect.width, closeTo(initialRect.width, 0.1));
        expect(zoomedInRect.height, closeTo(initialRect.height, 0.1));
        expect(
          smallestDownscalePaintTransform(
            tester,
            find.byKey(const ValueKey('resize-handle-visual-box-1-topLeft')),
          ),
          isNull,
        );

        final zoomOutController = AppController()..loadProject(project());
        zoomOutController.selectBox('box-1');

        await tester.pumpWidget(app(zoomOutController));
        final initialZoomOutRect = tester.getRect(
          find.byKey(const ValueKey('resize-handle-visual-box-1-topLeft')),
        );
        await tapVisible(tester, find.byKey(const ValueKey('zoom-out')));

        final zoomedOutRect = tester.getRect(
          find.byKey(const ValueKey('resize-handle-visual-box-1-topLeft')),
        );
        expect(zoomedOutRect.width, closeTo(initialZoomOutRect.width, 0.1));
        expect(zoomedOutRect.height, closeTo(initialZoomOutRect.height, 0.1));
        expect(
          smallestDownscalePaintTransform(
            tester,
            find.byKey(const ValueKey('resize-handle-visual-box-1-topLeft')),
          ),
          isNull,
        );
      },
    );

    testWidgets('selected resize handle uses a visible design surface', (
      tester,
    ) async {
      final controller = AppController()..loadProject(project());
      controller.selectBox('box-1');

      await tester.pumpWidget(app(controller));

      final visual = tester.widget<Container>(
        find.byKey(const ValueKey('resize-handle-visual-box-1-topLeft')),
      );
      final decoration = visual.decoration! as BoxDecoration;

      expect(decoration.color, Colors.white);
      expect(decoration.border!.top.color, const Color(0xff5f6772));
      expect(decoration.borderRadius, BorderRadius.circular(2));
    });

    testWidgets('overlay label position does not move when box is selected', (
      tester,
    ) async {
      final controller = AppController()..loadProject(project());

      await tester.pumpWidget(app(controller));
      final unselectedLabelTopLeft = tester.getTopLeft(
        find.byKey(const ValueKey('overlay-label-box-1')),
      );

      controller.selectBox('box-1');
      await tester.pump();

      final selectedLabelTopLeft = tester.getTopLeft(
        find.byKey(const ValueKey('overlay-label-box-1')),
      );

      expect(selectedLabelTopLeft.dx, closeTo(unselectedLabelTopLeft.dx, 0.1));
      expect(selectedLabelTopLeft.dy, closeTo(unselectedLabelTopLeft.dy, 0.1));
    });

    testWidgets('overlay label keeps screen size after zooming', (
      tester,
    ) async {
      final controller = AppController()..loadProject(project());
      controller.selectBox('box-1');

      await tester.pumpWidget(app(controller));
      final initialRect = tester.getRect(
        find.byKey(const ValueKey('overlay-label-box-1')),
      );

      for (var index = 0; index < 4; index++) {
        await tapVisible(tester, find.byKey(const ValueKey('zoom-in')));
      }

      final zoomedRect = tester.getRect(
        find.byKey(const ValueKey('overlay-label-box-1')),
      );

      expect(zoomedRect.width, closeTo(initialRect.width, 0.5));
      expect(zoomedRect.height, closeTo(initialRect.height, 0.5));
      expect(
        smallestDownscalePaintTransform(
          tester,
          find.byKey(const ValueKey('overlay-label-box-1')),
        ),
        isNull,
      );
    });

    testWidgets('unselected unlabeled canvas boxes use compact number badges', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(overlappingProject());

      await tester.pumpWidget(app(controller));

      expect(
        tester.getSize(find.byKey(const ValueKey('overlay-label-box-1'))).width,
        closeTo(badgeTextWidth('#1'), 0.1),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('overlay-label-box-2'))).width,
        closeTo(badgeTextWidth('#2'), 0.1),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('annotation-canvas-panel')),
          matching: find.text(WorkbenchCopy.unlabeledBox),
        ),
        findsNothing,
      );
    });

    testWidgets('selected unlabeled canvas box shows number and state', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(overlappingProject());
      controller.selectBox('box-2');

      await tester.pumpWidget(app(controller));

      expect(
        tester.getSize(find.byKey(const ValueKey('overlay-label-box-2'))).width,
        closeTo(badgeTextWidth('#2 ${WorkbenchCopy.unlabeledBox}'), 0.1),
      );
      final semantics = tester.getSemantics(
        find.byKey(const ValueKey('selected-box-box-2')),
      );
      expect(
        semantics.label,
        WorkbenchCopy.boxSemanticLabel(
          number: 2,
          label: WorkbenchCopy.unlabeledBox,
          selected: true,
        ),
      );
    });

    testWidgets('canvas boxes expose the selection semantics label', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(overlappingProject());
      controller.selectBox('box-2');

      await tester.pumpWidget(app(controller));
      final semantics = tester.getSemantics(
        find.byKey(const ValueKey('selected-box-box-2')),
      );

      expect(
        semantics.label,
        WorkbenchCopy.boxSemanticLabel(
          number: 2,
          label: WorkbenchCopy.unlabeled,
          selected: true,
        ),
      );
      expect(semantics.flagsCollection.isButton, isTrue);
      expect(semantics.flagsCollection.isSelected, Tristate.isTrue);
    });

    testWidgets(
      'narrow labeled canvas boxes use label-only text while wider boxes keep numbers',
      (tester) async {
        final controller = AppController();
        controller.loadProject(narrowLabelProject());

        await tester.pumpWidget(app(controller));

        final plainBadgeWidth = badgeTextWidth('Person');
        final numberedBadgeWidth = badgeTextWidth('#2 Person');
        final narrowBadgeSize = tester.getSize(
          find.byKey(const ValueKey('overlay-label-box-1')),
        );
        final wideBadgeSize = tester.getSize(
          find.byKey(const ValueKey('overlay-label-box-2')),
        );

        expect(narrowBadgeSize.width, closeTo(plainBadgeWidth, 0.1));
        expect(narrowBadgeSize.width, lessThan(numberedBadgeWidth));
        expect(wideBadgeSize.width, closeTo(numberedBadgeWidth, 0.1));
        expect(wideBadgeSize.width, greaterThan(narrowBadgeSize.width));
      },
    );

    testWidgets(
      'badge text stays out of semantics while the box label remains exposed',
      (tester) async {
        final controller = AppController();
        controller.loadProject(overlappingProject());
        controller.selectBox('box-2');

        await tester.pumpWidget(app(controller));
        final semantics = tester.ensureSemantics();

        final binding = tester.binding;
        final rootNode =
            binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;
        final nodes = <SemanticsNode>[];

        void collect(SemanticsNode node) {
          nodes.add(node);
          node.visitChildren((SemanticsNode child) {
            collect(child);
            return true;
          });
        }

        collect(rootNode);

        final mainBoxLabel = WorkbenchCopy.boxSemanticLabel(
          number: 2,
          label: WorkbenchCopy.unlabeledBox,
          selected: true,
        );
        final badgeLabel = WorkbenchCopy.boxDisplayTitle(
          2,
          WorkbenchCopy.unlabeledBox,
        );
        final mainNode = nodes.singleWhere(
          (node) => node.label == mainBoxLabel,
        );
        final parent = mainNode.parent;
        expect(parent, isNotNull);

        final siblingLabels = <String>[];
        parent!.visitChildren((SemanticsNode child) {
          siblingLabels.add(child.label);
          return true;
        });

        expect(mainNode.flagsCollection.isHidden, isFalse);
        expect(siblingLabels, isNot(contains(badgeLabel)));
        semantics.dispose();
      },
    );

    testWidgets('selected box is rendered after overlapping unselected boxes', (
      tester,
    ) async {
      final controller = AppController()..loadProject(overlappingProject());
      controller.selectBox('box-1');

      await tester.pumpWidget(app(controller));

      final widgets = tester.allWidgets.toList();
      final selectedIndex = widgets.indexWhere(
        (widget) => widget.key == const ValueKey('selected-box-box-1'),
      );
      final unselectedIndex = widgets.indexWhere(
        (widget) => widget.key == const ValueKey('box-box-2'),
      );

      expect(unselectedIndex, isNonNegative);
      expect(selectedIndex, isNonNegative);
      expect(selectedIndex, greaterThan(unselectedIndex));
    });

    testWidgets('selected automatic box keeps high contrast gray styling', (
      tester,
    ) async {
      final controller = AppController()..loadProject(project());
      controller.selectBox('box-1');

      await tester.pumpWidget(app(controller));

      final box = tester.widget<Container>(
        find.byKey(const ValueKey('selected-box-box-1')),
      );
      final decoration = box.decoration! as BoxDecoration;
      expect(decoration.border!.top.color, const Color(0xff5f6772));
      expect(decoration.color, const Color(0xff5f6772).withAlpha(58));
      expect(find.byKey(const ValueKey('box-contrast-box-1')), findsNothing);
    });

    testWidgets('contrast layer does not block box interaction', (
      tester,
    ) async {
      final controller = AppController()..loadProject(project());

      await tester.pumpWidget(app(controller));

      final interactionPoint = tester.getCenter(
        find.byKey(const ValueKey('box-box-1')),
      );
      await tester.tapAt(interactionPoint);
      await tester.pump();

      expect(controller.selectedBoxId, 'box-1');

      final before = controller.selectedImage!.boxes.single;
      final beforeX = before.x;
      final beforeY = before.y;
      await tester.dragFrom(interactionPoint, const Offset(14, 10));
      await tester.pump();

      final after = controller.selectedImage!.boxes.single;
      expect(after.x, greaterThan(beforeX));
      expect(after.y, greaterThan(beforeY));
    });

    testWidgets(
      'labeled box uses white outline and category-colored name badge',
      (tester) async {
        final controller = AppController()
          ..loadProject(
            project().copyWith(
              images: [
                project().images.first.copyWith(
                  boxes: const [
                    BoundingBox(
                      id: 'box-1',
                      x: 10,
                      y: 10,
                      width: 20,
                      height: 20,
                      status: BoxStatus.labeled,
                      labelId: 1,
                    ),
                  ],
                ),
                project().images.last,
              ],
            ),
          );

        await tester.pumpWidget(app(controller));

        final box = tester.widget<Container>(
          find.byKey(const ValueKey('box-box-1')),
        );
        final decoration = box.decoration! as BoxDecoration;
        expect(decoration.border!.top.color, Colors.white);
        final badge = tester.widget<CustomPaint>(
          find.byKey(const ValueKey('overlay-label-box-1')),
        );
        final dynamic painter = badge.painter;
        expect(painter.backgroundColor, const Color(0xffe64a19));
      },
    );

    testWidgets('review suggestion uses red outline and label-color badge', (
      tester,
    ) async {
      final reviewBox = project().images.first.boxes.single.copyWith(
        automation: const BoxAutomationMetadata(
          suggestedLabelId: 1,
          candidates: [LabelCandidate(labelId: 1, score: 0.58)],
          reviewReasons: ['low_margin'],
          pipelineVersion: 'test-v1',
          policyVersion: 'test-policy-v1',
          detectorSha256: 'detector-hash',
        ),
      );
      final controller = AppController()
        ..loadProject(
          project().copyWith(
            images: [
              project().images.first.copyWith(boxes: [reviewBox]),
              project().images.last,
            ],
          ),
        );

      await tester.pumpWidget(app(controller));

      final box = tester.widget<Container>(
        find.byKey(const ValueKey('box-box-1')),
      );
      final decoration = box.decoration! as BoxDecoration;
      expect(decoration.border!.top.color, WorkbenchPalette.danger);
      final badge = tester.widget<CustomPaint>(
        find.byKey(const ValueKey('overlay-label-box-1')),
      );
      final dynamic painter = badge.painter;
      expect(painter.backgroundColor, const Color(0xffe64a19));
    });

    testWidgets('shows loading state while selected image is loading', (
      tester,
    ) async {
      final tempDir = Directory.systemTemp.createTempSync('bbox_loading_state');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final imageFile = File('${tempDir.path}${Platform.pathSeparator}a.png');
      imageFile.writeAsBytesSync(img.encodePng(fixtureImage(100, 80)));

      final controller = AppController();
      final loadingProject = project().copyWith(
        images: [
          project().images.first.copyWith(sourcePath: imageFile.path),
          project().images.last,
        ],
      );
      controller.loadProject(loadingProject);
      controller.debugSetImageViewLoadState(
        const ImageViewLoadState(imageId: 1, isLoading: true),
      );

      await tester.pumpWidget(app(controller));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('viewer-loading-state')),
        findsOneWidget,
      );
    });
  });
}
