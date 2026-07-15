// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workbench_test_support.dart';

void main() {
  group('WorkbenchScreen', () {
    testWidgets('proposal boxes keep confirm disabled until labeled', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));

      expect(controller.canConfirmSelectedImage, isFalse);
      final confirmButton = tester.widget<ElevatedButton>(
        find.byKey(const ValueKey('confirm-image')),
      );
      expect(confirmButton.onPressed, isNull);
    });

    testWidgets('complete and next advances to the next work image', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(
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
      await tapVisible(tester, find.byKey(const ValueKey('confirm-image')));

      expect(controller.project!.images.first.status, ImageStatus.confirmed);
      expect(controller.selectedImageId, 2);
      expect(find.text(WorkbenchCopy.completeNoObjectAndNext), findsOneWidget);
    });

    testWidgets('disabled completion action shows blocker reason', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));

      expect(find.text(WorkbenchCopy.unlabeledBoxCount(1)), findsOneWidget);
      final confirmButton = tester.widget<ElevatedButton>(
        find.byKey(const ValueKey('confirm-image')),
      );
      expect(confirmButton.onPressed, isNull);
    });

    testWidgets('ctrl enter completes and advances', (tester) async {
      final controller = AppController();
      controller.loadProject(
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
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(find.text(WorkbenchCopy.completeAndNextShortcut), findsOneWidget);
      expect(controller.project!.images.first.status, ImageStatus.confirmed);
      expect(controller.selectedImageId, 2);
    });

    testWidgets('enter alone does not complete or advance', (tester) async {
      final controller = AppController();
      controller.loadProject(
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
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(controller.project!.images.first.status, ImageStatus.needsReview);
      expect(controller.selectedImageId, 1);
    });

    testWidgets('ctrl enter does not complete when a text input has focus', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(
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
      await tapVisible(
        tester,
        find.byKey(const ValueKey('open-label-management')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('label-name-input')));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(controller.project!.images.first.status, ImageStatus.needsReview);
      expect(controller.selectedImageId, 1);
    });

    testWidgets('enter does not complete when a text input has focus', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(
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
      await tapVisible(
        tester,
        find.byKey(const ValueKey('open-label-management')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('label-name-input')));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(controller.project!.images.first.status, ImageStatus.needsReview);
      expect(controller.selectedImageId, 1);
    });

    testWidgets('empty images can be confirmed as object none', (tester) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));
      controller.selectImage(2);
      await tester.pump();
      await tapVisible(tester, find.byKey(const ValueKey('confirm-image')));

      expect(controller.project!.images.last.status, ImageStatus.confirmed);
      expect(controller.selectedImageId, 1);
      expect(find.text(WorkbenchCopy.confirmed), findsWidgets);
    });

    testWidgets('export button shows warnings for unfinished work', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(projectWithError());

      await tester.pumpWidget(app(controller));
      await tester.tap(find.byKey(const ValueKey('export-coco')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('COCO 내보내기 경고'), findsOneWidget);
      expect(find.text('검토 필요 이미지: 2'), findsOneWidget);
      expect(
        find.text(WorkbenchCopy.exportUnclassifiedBoxes(1)),
        findsOneWidget,
      );
      expect(find.text('문제 있는 이미지: 1'), findsOneWidget);
      await tester.tap(find.text(WorkbenchCopy.close));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
