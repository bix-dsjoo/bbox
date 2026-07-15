// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bbox_labeler/detector/auto_box_service.dart';

import '../../support/fake_auto_box_runtime.dart';
import 'workbench_test_support.dart';

void main() {
  group('WorkbenchScreen', () {
    testWidgets('starting shows disabled model preparation action', (
      tester,
    ) async {
      final runtime = FakeAutoBoxRuntime(state: AutoBoxState.starting);
      final controller = AppController(autoBoxRuntime: runtime)
        ..loadProject(project());
      addTearDown(controller.dispose);

      await tester.pumpWidget(app(controller));

      expect(find.text('모델 준비 중'), findsOneWidget);
      expect(_autoBoxesButton(tester).onPressed, isNull);
    });

    testWidgets('ready shows enabled automatic box action', (tester) async {
      final runtime = FakeAutoBoxRuntime();
      final controller = AppController(autoBoxRuntime: runtime)
        ..loadProject(project());
      addTearDown(controller.dispose);

      await tester.pumpWidget(app(controller));

      expect(find.text('자동 박스'), findsWidgets);
      expect(_autoBoxesButton(tester).onPressed, isNotNull);
    });

    testWidgets('running shows disabled detection action', (tester) async {
      final runtime = FakeAutoBoxRuntime(state: AutoBoxState.running);
      final controller = AppController(autoBoxRuntime: runtime)
        ..loadProject(project());
      addTearDown(controller.dispose);

      await tester.pumpWidget(app(controller));

      expect(find.text('자동 박스 찾는 중'), findsOneWidget);
      expect(_autoBoxesButton(tester).onPressed, isNull);
    });

    testWidgets('restarting shows disabled restart action', (tester) async {
      final runtime = FakeAutoBoxRuntime(state: AutoBoxState.restarting);
      final controller = AppController(autoBoxRuntime: runtime)
        ..loadProject(project());
      addTearDown(controller.dispose);

      await tester.pumpWidget(app(controller));

      expect(find.text('모델 다시 시작 중'), findsOneWidget);
      expect(_autoBoxesButton(tester).onPressed, isNull);
    });

    testWidgets('failed shows enabled retry action', (tester) async {
      final runtime = FakeAutoBoxRuntime(state: AutoBoxState.failed);
      final controller = AppController(autoBoxRuntime: runtime)
        ..loadProject(project());
      addTearDown(controller.dispose);

      await tester.pumpWidget(app(controller));

      expect(find.text('자동 박스 다시 시도'), findsOneWidget);
      expect(_autoBoxesButton(tester).onPressed, isNotNull);

      await tapVisible(
        tester,
        find.byKey(const ValueKey('auto-boxes-current-image')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-auto-box-replace')));
      await tester.pumpAndSettle();

      expect(runtime.detectCount, 1);
    });

    testWidgets('ctrl b follows automatic box availability', (tester) async {
      final runtime = FakeAutoBoxRuntime(state: AutoBoxState.starting);
      final controller = AppController(autoBoxRuntime: runtime)
        ..loadProject(project());
      addTearDown(controller.dispose);

      await tester.pumpWidget(app(controller));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(runtime.detectCount, 0);
    });

    testWidgets('center toolbar separates automation editing and view groups', (
      tester,
    ) async {
      final controller = AppController()..loadProject(project());

      await tester.pumpWidget(app(controller));

      expect(
        find.byKey(const ValueKey('center-automation-toolbar')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('center-edit-toolbar')), findsOneWidget);
      expect(find.byKey(const ValueKey('center-view-toolbar')), findsOneWidget);
      expect(find.text(WorkbenchCopy.autoBoxesShortcut), findsOneWidget);
    });

    testWidgets('center toolbar groups align to a stable grid', (tester) async {
      final controller = AppController()..loadProject(project());

      await tester.binding.setSurfaceSize(const Size(1920, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(controller));

      final automationRect = tester.getRect(
        find.byKey(const ValueKey('center-automation-toolbar')),
      );
      final editRect = tester.getRect(
        find.byKey(const ValueKey('center-edit-toolbar')),
      );
      final viewRect = tester.getRect(
        find.byKey(const ValueKey('center-view-toolbar')),
      );
      final railRect = tester.getRect(
        find.byKey(const ValueKey('center-toolbar-rail')),
      );

      expect(editRect.height, closeTo(viewRect.height, 0.1));
      expect(automationRect.height, closeTo(editRect.height, 0.1));
      for (final rect in [automationRect, editRect, viewRect]) {
        expect(rect.left, greaterThanOrEqualTo(railRect.left));
        expect(rect.right, lessThanOrEqualTo(railRect.right));
        expect(rect.top, greaterThanOrEqualTo(railRect.top));
        expect(rect.bottom, lessThanOrEqualTo(railRect.bottom));
      }
    });

    testWidgets('center toolbar wraps instead of clipping on desktop width', (
      tester,
    ) async {
      final controller = AppController()..loadProject(project());

      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(controller));

      final panelRect = tester.getRect(
        find.byKey(const ValueKey('annotation-canvas-panel')),
      );
      final clearButtonRect = tester.getRect(
        find.byKey(const ValueKey('clear-current-image-boxes')),
      );

      expect(clearButtonRect.right, lessThanOrEqualTo(panelRect.right));
      expect(clearButtonRect.left, greaterThanOrEqualTo(panelRect.left));
    });

    testWidgets('center controls render as one toolbar rail', (tester) async {
      final controller = AppController()..loadProject(project());

      await tester.pumpWidget(app(controller));

      final rail = find.byKey(const ValueKey('center-toolbar-rail'));
      expect(rail, findsOneWidget);
      expect(
        find.descendant(
          of: rail,
          matching: find.byKey(const ValueKey('center-automation-toolbar')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: rail,
          matching: find.byKey(const ValueKey('center-edit-toolbar')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: rail,
          matching: find.byKey(const ValueKey('center-view-toolbar')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: rail,
          matching: find.byKey(const ValueKey('center-toolbar-separator-1')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: rail,
          matching: find.byKey(const ValueKey('center-toolbar-separator-2')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('clear all boxes is directly available in automation tools', (
      tester,
    ) async {
      final controller = AppController()..loadProject(project());

      await tester.pumpWidget(app(controller));

      expect(
        find.byKey(const ValueKey('auto-boxes-current-image')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('clear-current-image-boxes')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('center-automation-more-menu')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('proposal-count-toggle')), findsNothing);
      expect(find.byKey(const ValueKey('proposal-count-input')), findsNothing);
    });

    testWidgets('clear all boxes asks for confirmation from direct action', (
      tester,
    ) async {
      final controller = AppController()..loadProject(project());

      await tester.pumpWidget(app(controller));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('clear-current-image-boxes')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('confirm-clear-current-image-boxes')),
        findsOneWidget,
      );
      expect(
        find.text(WorkbenchCopy.clearBoxesCountMessage(1)),
        findsOneWidget,
      );

      await tester.tap(find.text(WorkbenchCopy.cancel));
      await tester.pumpAndSettle();

      expect(controller.selectedImage!.visibleBoxes, hasLength(1));
    });

    testWidgets('clear all boxes confirm path clears visible boxes', (
      tester,
    ) async {
      final controller = AppController()..loadProject(project());

      await tester.pumpWidget(app(controller));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('clear-current-image-boxes')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('confirm-clear-current-image-boxes')),
      );
      await tester.pumpAndSettle();

      expect(controller.selectedImage!.visibleBoxes, isEmpty);
    });

    testWidgets('auto boxes feedback uses the unified activity bar', (
      tester,
    ) async {
      final controller = AppController()..loadProject(project());
      controller.lastUserMessage = WorkbenchCopy.autoBoxesCreated(1);

      await tester.pumpWidget(app(controller));

      expect(
        find.byKey(const ValueKey('workbench-activity-bar')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('auto-boxes-feedback')), findsNothing);
      expect(find.byKey(const ValueKey('image-import-progress')), findsNothing);
      expect(find.text(WorkbenchCopy.autoBoxesCreated(1)), findsOneWidget);
    });

    testWidgets('typed auto box error shows actionable activity copy', (
      tester,
    ) async {
      final controller = AppController(
        autoBoxRuntime: FakeAutoBoxRuntime(
          detectionError: const FileSystemException('secret NAS detail'),
        ),
      )..loadProject(project());
      addTearDown(controller.dispose);

      await tester.pumpWidget(app(controller));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('auto-boxes-current-image')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-auto-box-replace')));
      await tester.pumpAndSettle();

      expect(find.text(WorkbenchCopy.autoBoxesFileUnavailable), findsOneWidget);
      expect(find.textContaining('secret NAS detail'), findsNothing);
    });

    testWidgets('ctrl b runs auto boxes for the current image', (tester) async {
      final controller = AppController(
        autoBoxRuntime: FakeAutoBoxRuntime(
          detectionResult: const DetectionResult(
            detectorName: 'toolbar-auto-boxes',
            boxes: [
              BoundingBox(
                id: 'det-1-1',
                x: 20,
                y: 16,
                width: 60,
                height: 48,
                status: BoxStatus.proposal,
              ),
            ],
          ),
        ),
      )..loadProject(project());

      await tester.pumpWidget(app(controller));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-auto-box-replace')));
      await tester.pumpAndSettle();

      expect(controller.selectedImage!.visibleBoxes, hasLength(1));
      expect(controller.selectedImage!.visibleBoxes.single.id, 'det-1-1');
      expect(controller.lastUserMessage, WorkbenchCopy.autoBoxesCreated(1));
    });

    testWidgets('ctrl b does not run auto boxes when a text input has focus', (
      tester,
    ) async {
      final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime())
        ..loadProject(project());

      await tester.pumpWidget(app(controller));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('open-label-management')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('label-name-input')));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(controller.selectedImage!.visibleBoxes, hasLength(1));
      expect(controller.selectedImage!.visibleBoxes.single.id, 'box-1');
    });

    testWidgets('arrow down then enter applies the selected review candidate', (
      tester,
    ) async {
      final suggestedBox = project().images.first.boxes.single.copyWith(
        automation: const BoxAutomationMetadata(
          suggestedLabelId: 1,
          candidates: [
            LabelCandidate(labelId: 1, score: 0.58),
            LabelCandidate(labelId: 2, score: 0.42),
          ],
          reviewReasons: ['low_margin'],
          pipelineVersion: 'test-v1',
          policyVersion: 'test-policy-v1',
          detectorSha256: 'detector-hash',
        ),
      );
      final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime())
        ..loadProject(
          project().copyWith(
            labels: const [
              LabelClass(
                id: 1,
                name: 'Person',
                color: 0xffe64a19,
                shortcut: '1',
              ),
              LabelClass(
                id: 2,
                name: 'Pastry',
                color: 0xff006699,
                shortcut: '2',
              ),
            ],
            images: [
              project().images.first.copyWith(boxes: [suggestedBox]),
              project().images.last,
            ],
          ),
        )
        ..selectBox('box-1');
      addTearDown(controller.dispose);

      await tester.pumpWidget(app(controller));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(controller.selectedReviewCandidateLabelId, 2);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(controller.selectedReviewCandidateLabelId, 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(controller.selectedReviewCandidateLabelId, 2);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(controller.selectedBox!.status, BoxStatus.labeled);
      expect(controller.selectedBox!.labelId, 2);
      expect(controller.selectedBox!.labelSource, LabelSource.user);
    });

    testWidgets('review keys do not apply while a text input has focus', (
      tester,
    ) async {
      final suggestedBox = project().images.first.boxes.single.copyWith(
        automation: const BoxAutomationMetadata(
          suggestedLabelId: 1,
          candidates: [LabelCandidate(labelId: 1, score: 1)],
          reviewReasons: ['low_margin'],
          pipelineVersion: 'test-v1',
          policyVersion: 'test-policy-v1',
          detectorSha256: 'detector-hash',
        ),
      );
      final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime())
        ..loadProject(
          project().copyWith(
            images: [
              project().images.first.copyWith(boxes: [suggestedBox]),
              project().images.last,
            ],
          ),
        )
        ..selectBox('box-1');
      addTearDown(controller.dispose);

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

      expect(controller.selectedBox!.status, BoxStatus.proposal);
      expect(controller.selectedBox!.labelId, isNull);
    });

    testWidgets(
      'automation running locks editing while keeping view controls',
      (tester) async {
        final completer = Completer<DetectionResult>();
        final controller = AppController(
          autoBoxRuntime: FakeAutoBoxRuntime(detectionCompleter: completer),
        )..loadProject(project());
        controller.selectBox('box-1');

        await tester.pumpWidget(app(controller));
        await tapVisible(
          tester,
          find.byKey(const ValueKey('auto-boxes-current-image')),
        );
        await tester.tap(
          find.byKey(const ValueKey('confirm-auto-box-replace')),
        );
        await tester.pump();

        expect(controller.isAutomationRunning, isTrue);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('auto-boxes-current-image')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('clear-current-image-boxes')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('delete-selected-box-toolbar')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<TextButton>(find.byKey(const ValueKey('export-coco')))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<TextButton>(
                find.byKey(const ValueKey('remove-image-from-project')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<ElevatedButton>(
                find.byKey(const ValueKey('confirm-image')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<InkWell>(find.byKey(const ValueKey('quick-label-1')))
              .onTap,
          isNull,
        );
        expect(
          tester
              .widget<IconButton>(find.byKey(const ValueKey('zoom-in')))
              .onPressed,
          isNotNull,
        );
        expect(
          find.byKey(const ValueKey('automation-editing-locked-overlay')),
          findsOneWidget,
        );

        completer.complete(
          const DetectionResult(
            detectorName: 'delayed-workbench-detector',
            boxes: [],
          ),
        );
        await tester.pumpAndSettle();
      },
    );

    testWidgets('automation cancel button preserves existing boxes', (
      tester,
    ) async {
      final completer = Completer<DetectionResult>();
      final runtime = FakeAutoBoxRuntime(detectionCompleter: completer);
      final controller = AppController(autoBoxRuntime: runtime)
        ..loadProject(project())
        ..selectBox('box-1');
      addTearDown(controller.dispose);

      await tester.pumpWidget(app(controller));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('auto-boxes-current-image')),
      );
      await tester.tap(find.byKey(const ValueKey('confirm-auto-box-replace')));
      await tester.pump();

      expect(find.byKey(const ValueKey('cancel-auto-boxes')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cancel-auto-boxes')));
      await tester.pumpAndSettle();

      expect(runtime.cancelCount, 1);
      expect(controller.isAutomationRunning, isFalse);
      expect(controller.selectedImage!.visibleBoxes.single.id, 'box-1');
      expect(controller.selectedBoxId, 'box-1');
      expect(controller.lastUserMessage, WorkbenchCopy.autoBoxesCancelled);
    });

    testWidgets('automation toolbar exposes only auto boxes', (tester) async {
      final controller = AppController()..loadProject(project());

      await tester.pumpWidget(app(controller));

      expect(
        find.byKey(const ValueKey('auto-boxes-current-image')),
        findsOneWidget,
      );
      expect(find.textContaining('train'), findsNothing);
    });

    testWidgets('center toolbar delete button removes selected box', (
      tester,
    ) async {
      final controller = AppController()..loadProject(project());
      controller.selectBox('box-1');

      await tester.pumpWidget(app(controller));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('delete-selected-box-toolbar')),
      );

      expect(controller.selectedImage!.visibleBoxes, isEmpty);
    });
  });
}

FilledButton _autoBoxesButton(WidgetTester tester) {
  return tester.widget<FilledButton>(
    find.byKey(const ValueKey('auto-boxes-current-image')),
  );
}
