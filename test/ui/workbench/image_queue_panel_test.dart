// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workbench_test_support.dart';

void main() {
  group('WorkbenchScreen', () {
    testWidgets('selecting an image updates the box list', (tester) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));
      controller.selectImage(2);
      await tester.pump();

      expect(controller.selectedImage?.displayName, 'empty.jpg');
      expect(find.text('box-1'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              widget.data == WorkbenchCopy.boxesNone &&
              widget.style != null,
        ),
        findsOneWidget,
      );
    });

    testWidgets('desktop workbench gives queue and inspector more room', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(controller));

      expect(
        tester.getSize(find.byKey(const ValueKey('image-queue-panel'))).width,
        320,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('inspector-panel'))).width,
        400,
      );
    });

    testWidgets('image queue rows use restrained desktop radius', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));

      final rowMaterial = tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(const ValueKey('image-row-1')),
              matching: find.byType(Material),
            )
            .first,
      );
      final borderRadius = rowMaterial.borderRadius! as BorderRadius;
      expect(borderRadius.topLeft.x, 6);
      expect(borderRadius.topRight.x, 6);
      expect(borderRadius.bottomLeft.x, 6);
      expect(borderRadius.bottomRight.x, 6);
    });

    testWidgets('medium workbench keeps compact side panel widths', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.binding.setSurfaceSize(const Size(920, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(controller));

      expect(
        tester.getSize(find.byKey(const ValueKey('image-queue-panel'))).width,
        260,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('inspector-panel'))).width,
        340,
      );
    });

    testWidgets('image queue summarizes review progress', (tester) async {
      final controller = AppController();
      controller.loadProject(
        project().copyWith(
          images: [
            project().images.first.copyWith(status: ImageStatus.confirmed),
            project().images.last,
            const AnnotatedImage(
              id: 3,
              sourcePath: 'broken.jpg',
              displayName: 'broken.jpg',
              width: 0,
              height: 0,
              status: ImageStatus.error,
              errorMessage: 'decode failed',
            ),
          ],
        ),
      );

      await tester.pumpWidget(app(controller));

      expect(find.byKey(const ValueKey('image-queue-panel')), findsOneWidget);
      expect(find.text(WorkbenchCopy.images), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              widget.data != null &&
              widget.data!.contains('3') &&
              widget.data!.contains('1') &&
              widget.data!.contains(WorkbenchCopy.confirmed) &&
              widget.data!.contains('문제'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('image list shows all images without status filters', (
      tester,
    ) async {
      final controller = AppController();
      final queueProject = project().copyWith(
        images: [
          project().images.first.copyWith(status: ImageStatus.confirmed),
          project().images.last,
        ],
      );
      controller.loadProject(queueProject);

      await tester.pumpWidget(app(controller));

      expect(find.byKey(const ValueKey('filter-all')), findsNothing);
      expect(find.byKey(const ValueKey('filter-needs-review')), findsNothing);
      expect(find.byKey(const ValueKey('filter-confirmed')), findsNothing);
      expect(find.byKey(const ValueKey('filter-error')), findsNothing);
      expect(find.byKey(const ValueKey('filter-unlabeled')), findsNothing);
      expect(find.byKey(const ValueKey('image-row-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('image-row-2')), findsOneWidget);
    });
  });
}
