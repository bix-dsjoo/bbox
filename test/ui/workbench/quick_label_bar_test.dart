// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_auto_box_runtime.dart';
import 'workbench_test_support.dart';

void main() {
  group('WorkbenchScreen', () {
    testWidgets('selecting a box keeps the global quick-label bar available', (
      tester,
    ) async {
      final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime());
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));
      await tapVisible(tester, find.byKey(const ValueKey('box-row-box-1')));

      expect(
        find.byKey(const ValueKey('global-quick-label-bar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('center-quick-label-bar')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('quick-label-1')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('selected-box-label-selector')),
        findsNothing,
      );
    });

    testWidgets('quick label chip assigns an existing label to selected box', (
      tester,
    ) async {
      final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime());
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));
      await tapVisible(tester, find.byKey(const ValueKey('box-row-box-1')));
      await tapVisible(tester, find.byKey(const ValueKey('quick-label-1')));

      final box = controller.selectedImage!.boxes.single;
      expect(box.labelId, 1);
      expect(box.status, BoxStatus.labeled);
      expect(controller.canConfirmSelectedImage, isTrue);
    });

    testWidgets('selected quick label chip uses orange selected styling', (
      tester,
    ) async {
      final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime());
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));
      await tapVisible(tester, find.byKey(const ValueKey('box-row-box-1')));
      await tapVisible(tester, find.byKey(const ValueKey('quick-label-1')));
      await tester.pump();

      final chipContainers = find.descendant(
        of: find.byKey(const ValueKey('quick-label-1')),
        matching: find.byType(Container),
      );
      final outerContainer = tester.widget<Container>(chipContainers.at(0));
      final decoration = outerContainer.decoration! as BoxDecoration;
      final border = decoration.border! as Border;

      expect(decoration.color, WorkbenchPalette.accentSoft);
      expect(border.top.color, WorkbenchPalette.accentBorder);
      expect(border.top.width, 2);
    });

    testWidgets('label shortcuts assign the first twenty labels', (
      tester,
    ) async {
      final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime());
      controller.loadProject(project().copyWith(labels: createDefaultLabels()));

      await tester.pumpWidget(app(controller));
      await tapVisible(tester, find.byKey(const ValueKey('box-row-box-1')));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.pump();

      final box = controller.selectedImage!.boxes.single;
      expect(box.labelId, 20);
      expect(box.status, BoxStatus.labeled);
    });

    testWidgets('workbench shows a global bottom quick-label bar', (
      tester,
    ) async {
      final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime())
        ..loadProject(projectWithSelectedImage());

      await tester.pumpWidget(
        MaterialApp(home: WorkbenchScreen(controller: controller)),
      );

      expect(
        find.byKey(const ValueKey('global-quick-label-bar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('center-quick-label-bar')),
        findsNothing,
      );
      expect(find.text('Walnut Donut'), findsOneWidget);
      expect(find.text('1'), findsWidgets);
    });

    testWidgets('quick label bar shows twenty shortcut slots', (tester) async {
      final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime());
      controller.loadProject(project().copyWith(labels: createDefaultLabels()));

      await tester.pumpWidget(app(controller));

      expect(
        find.byKey(const ValueKey('global-quick-label-bar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('center-quick-label-bar')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('quick-label-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-label-p')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('open-label-management')),
        findsOneWidget,
      );
      expect(find.text('Walnut Donut'), findsOneWidget);
      expect(find.text('Plain Bread'), findsOneWidget);
    });

    testWidgets('quick label bar centers shortcut content on wide screens', (
      tester,
    ) async {
      final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime());
      controller.loadProject(
        project().copyWith(
          labels: const [
            LabelClass(id: 1, name: 'A', color: 0xffe64a19, shortcut: '1'),
            LabelClass(id: 2, name: 'B', color: 0xff1976d2, shortcut: '2'),
            LabelClass(id: 3, name: 'C', color: 0xff388e3c, shortcut: '3'),
          ],
        ),
      );

      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(controller));

      final barRect = tester.getRect(
        find.byKey(const ValueKey('global-quick-label-bar')),
      );
      final contentRect = tester.getRect(
        find.byKey(const ValueKey('quick-label-content')),
      );

      expect(contentRect.center.dx, closeTo(barRect.center.dx, 16));
      expect(contentRect.left, greaterThan(barRect.left));
      expect(contentRect.right, lessThan(barRect.right));
    });

    testWidgets('quick label chip expands so long label text is not clipped', (
      tester,
    ) async {
      const longLabelName = 'Very Long Donut Package Label';
      final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime())
        ..loadProject(
          project().copyWith(
            labels: const [
              LabelClass(
                id: 1,
                name: longLabelName,
                color: 0xffe64a19,
                shortcut: '1',
              ),
            ],
          ),
        );
      controller.selectBox('box-1');

      await tester.binding.setSurfaceSize(const Size(900, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(controller));

      final labelRect = tester.getRect(find.text(longLabelName));
      final measuredTextWidth = textWidth(
        tester,
        longLabelName,
        Theme.of(
          tester.element(find.byKey(const ValueKey('quick-label-1'))),
        ).textTheme.bodySmall!.copyWith(fontWeight: FontWeight.w600),
      );

      expect(labelRect.width, greaterThanOrEqualTo(measuredTextWidth - 1));
    });

    testWidgets('quick label bar shows an empty state when no labels exist', (
      tester,
    ) async {
      final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime());
      controller.loadProject(project().copyWith(labels: const []));

      await tester.pumpWidget(app(controller));

      expect(
        find.byKey(const ValueKey('global-quick-label-bar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('quick-label-empty-state')),
        findsOneWidget,
      );
      expect(find.text(WorkbenchCopy.addLabelsEmpty), findsOneWidget);
      expect(
        find.byKey(const ValueKey('open-label-management')),
        findsOneWidget,
      );
    });

    testWidgets(
      'label management popover creates a label that can be assigned',
      (tester) async {
        final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime());
        controller.loadProject(project().copyWith(labels: const []));

        await tester.pumpWidget(app(controller));
        await tapVisible(tester, find.byKey(const ValueKey('box-row-box-1')));
        await tapVisible(
          tester,
          find.byKey(const ValueKey('open-label-management')),
        );
        await tester.pump();
        await tester.enterText(
          find.byKey(const ValueKey('label-name-input')),
          'Helmet',
        );
        await tester.enterText(
          find.byKey(const ValueKey('label-shortcut-input')),
          '1',
        );
        await tester.tap(find.byKey(const ValueKey('create-managed-label')));
        await tester.pump();
        final label = controller.project!.labels.single;
        await tapVisible(
          tester,
          find.byKey(ValueKey('quick-label-${label.shortcut}')),
        );

        final box = controller.selectedImage!.boxes.single;
        expect(label.name, 'Helmet');
        expect(box.labelId, label.id);
        expect(box.status, BoxStatus.labeled);
      },
    );

    testWidgets(
      'label management overlay opens from the trigger as a non-modal overlay',
      (tester) async {
        final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime());
        controller.loadProject(project());

        await tester.pumpWidget(app(controller));

        final trigger = find.byKey(const ValueKey('open-label-management'));
        final triggerCenter = tester.getCenter(trigger);
        await tapVisible(tester, trigger);
        await tester.pump();

        expect(
          find.byKey(const ValueKey('label-management-popover')),
          findsOneWidget,
        );
        expect(find.byType(CompositedTransformFollower), findsOneWidget);
        expect(find.byType(Dialog), findsNothing);

        final popoverTopLeft = tester.getTopLeft(
          find.byKey(const ValueKey('label-management-popover')),
        );
        expect((popoverTopLeft.dx - triggerCenter.dx).abs(), lessThan(220));
        expect(popoverTopLeft.dy, lessThan(triggerCenter.dy));

        await tester.tapAt(const Offset(4, 4));
        await tester.pump();

        expect(
          find.byKey(const ValueKey('label-management-popover')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('workbench-shell')), findsOneWidget);
      },
    );

    testWidgets(
      'label management popover stays inside a 1585x943 viewport at the right edge',
      (tester) async {
        final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime())
          ..loadProject(
            project().copyWith(labels: createDefaultLabels().take(10).toList()),
          );

        await tester.binding.setSurfaceSize(const Size(1585, 943));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(app(controller));
        await tapVisible(
          tester,
          find.byKey(const ValueKey('open-label-management')),
        );
        await tester.pump();

        const viewport = Rect.fromLTWH(0, 0, 1585, 943);
        final controls = <String, Finder>{
          'label-management-popover': find.byKey(
            const ValueKey('label-management-popover'),
          ),
          'label-shortcut-input': find.byKey(
            const ValueKey('label-shortcut-input'),
          ),
          'color control': find.byType(PopupMenuButton<int>),
          'create-managed-label': find.byKey(
            const ValueKey('create-managed-label'),
          ),
        };
        for (final MapEntry(key: name, value: finder) in controls.entries) {
          final rect = tester.getRect(finder);
          expect(
            viewport.contains(rect.topLeft),
            isTrue,
            reason: '$name top-left must be inside the viewport',
          );
          expect(
            viewport.contains(rect.bottomRight),
            isTrue,
            reason: '$name bottom-right must be inside the viewport',
          );
        }
      },
    );

    testWidgets('label management popover stays inside a 1280x720 viewport', (
      tester,
    ) async {
      final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime())
        ..loadProject(
          project().copyWith(labels: createDefaultLabels().take(10).toList()),
        );

      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(controller));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('open-label-management')),
      );
      await tester.pump();

      final popover = tester.getRect(
        find.byKey(const ValueKey('label-management-popover')),
      );
      expect(
        const Rect.fromLTWH(0, 0, 1280, 720).contains(popover.topLeft),
        isTrue,
      );
      expect(
        const Rect.fromLTWH(0, 0, 1280, 720).contains(popover.bottomRight),
        isTrue,
      );
      final action = tester.getRect(
        find.byKey(const ValueKey('create-managed-label')),
      );
      expect(popover.contains(action.topLeft), isTrue);
      expect(popover.contains(action.bottomRight), isTrue);
    });

    testWidgets(
      'label management popover stays inside at a left-edge trigger',
      (tester) async {
        final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime())
          ..loadProject(project().copyWith(labels: const []));

        await tester.binding.setSurfaceSize(const Size(800, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(app(controller));
        await tapVisible(
          tester,
          find.byKey(const ValueKey('open-label-management')),
        );
        await tester.pump();

        final trigger = tester.getRect(
          find.byKey(const ValueKey('open-label-management')),
        );
        final popover = tester.getRect(
          find.byKey(const ValueKey('label-management-popover')),
        );
        const viewport = Rect.fromLTWH(0, 0, 800, 720);
        expect(trigger.center.dx, lessThan(viewport.center.dx));
        expect(popover.left, greaterThanOrEqualTo(12));
        expect(viewport.contains(popover.topLeft), isTrue);
        expect(viewport.contains(popover.bottomRight), isTrue);
      },
    );

    testWidgets('drawn unlabeled box stays selected and shows quick labels', (
      tester,
    ) async {
      final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime());
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));
      await tester.tap(find.byKey(const ValueKey('canvas-tool-draw-box')));
      await tester.pump();
      await tester.drag(
        find.byKey(const ValueKey('image-canvas')),
        const Offset(80, 60),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(controller.selectedBoxId, startsWith('manual-'));
      expect(controller.canConfirmSelectedImage, isFalse);
      expect(
        find.byKey(const ValueKey('global-quick-label-bar')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('quick-label-1')), findsOneWidget);
    });

    testWidgets(
      'assigning a label changes proposal to label color and enables confirm',
      (tester) async {
        final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime());
        controller.loadProject(project());

        await tester.pumpWidget(app(controller));
        await tapVisible(tester, find.byKey(const ValueKey('box-row-box-1')));
        await tapVisible(tester, find.byKey(const ValueKey('quick-label-1')));

        expect(
          controller.selectedImage!.boxes.single.status,
          BoxStatus.labeled,
        );
        expect(controller.canConfirmSelectedImage, isTrue);
        expect(find.text('Person'), findsWidgets);
        final confirmButton = tester.widget<ElevatedButton>(
          find.byKey(const ValueKey('confirm-image')),
        );
        expect(confirmButton.onPressed, isNotNull);
      },
    );

    testWidgets('creates labels from the label management popover', (
      tester,
    ) async {
      final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime());
      controller.loadProject(project().copyWith(labels: const []));

      await tester.pumpWidget(app(controller));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('open-label-management')),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('label-name-input')),
        'Vehicle',
      );
      await tester.enterText(
        find.byKey(const ValueKey('label-shortcut-input')),
        '1',
      );
      await tester.tap(find.byKey(const ValueKey('create-managed-label')));
      await tester.pump();

      expect(controller.project!.labels.single.name, 'Vehicle');
      expect(find.text('Vehicle'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('label-management-popover')),
        findsNothing,
      );
    });

    testWidgets(
      'label management popover shows inline errors and keeps editing open',
      (tester) async {
        final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime());
        controller.loadProject(project());

        await tester.pumpWidget(app(controller));
        await tapVisible(
          tester,
          find.byKey(const ValueKey('open-label-management')),
        );
        await tester.pump();
        await tester.enterText(
          find.byKey(const ValueKey('label-name-input')),
          'Helmet',
        );
        await tester.enterText(
          find.byKey(const ValueKey('label-shortcut-input')),
          'z',
        );
        await tester.tap(find.byKey(const ValueKey('create-managed-label')));
        await tester.pump();

        expect(
          find.byKey(const ValueKey('label-management-error')),
          findsOneWidget,
        );
        expect(find.text('지원하지 않는 라벨 단축키입니다.'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('label-management-popover')),
          findsOneWidget,
        );
        expect(controller.project!.labels, hasLength(1));
      },
    );

    testWidgets(
      'label shortcut does not assign while a label text input has focus',
      (tester) async {
        final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime());
        controller.loadProject(overlappingProject());
        controller.selectBox('box-1');

        await tester.pumpWidget(app(controller));
        await tester.pump();
        await tapVisible(
          tester,
          find.byKey(const ValueKey('open-label-management')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('label-name-input')));
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
        await tester.pump();

        final firstBox = controller.selectedImage!.boxes
            .where((box) => box.id == 'box-1')
            .single;
        expect(firstBox.labelId, isNull);
        expect(firstBox.status, BoxStatus.proposal);
        expect(controller.selectedBoxId, 'box-1');
        expect(controller.selectedImageId, 1);
      },
    );
  });
}
