// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workbench_test_support.dart';

void main() {
  group('WorkbenchScreen', () {
    testWidgets('inspector and canvas use polished empty states', (
      tester,
    ) async {
      final controller = AppController();
      controller.createProject('demo');

      await tester.pumpWidget(app(controller));

      expect(
        find.byKey(const ValueKey('annotation-canvas-panel')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('inspector-panel')), findsOneWidget);
      expect(find.text(WorkbenchCopy.selectImageShort), findsOneWidget);
      expect(find.text(WorkbenchCopy.noImageSelected), findsNothing);
      expect(find.text(WorkbenchCopy.selectImageForInspector), findsNothing);
    });

    testWidgets('right sidebar shows file name and compact work summary', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));

      final inspector = find.byKey(const ValueKey('inspector-panel'));
      expect(
        find.descendant(
          of: inspector,
          matching: find.text(WorkbenchCopy.selectedImage),
        ),
        findsNothing,
      );
      expect(
        find.descendant(of: inspector, matching: find.text('a.jpg')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inspector, matching: find.text('박스 1개 · 라벨 필요 1개')),
        findsOneWidget,
      );
    });

    testWidgets('right sidebar uses no-box summary and direct remove action', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());
      controller.selectImage(2);

      await tester.pumpWidget(app(controller));

      final inspector = find.byKey(const ValueKey('inspector-panel'));
      expect(
        find.descendant(
          of: inspector,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Text &&
                widget.data == WorkbenchCopy.boxesNone &&
                widget.style != null,
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: inspector,
          matching: find.byKey(const ValueKey('remove-image-from-project')),
        ),
        findsOneWidget,
      );
      expect(find.text(WorkbenchCopy.removeImageFromProject), findsOneWidget);
    });

    testWidgets('right sidebar defaults to work tab and can show table tab', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(mixedBoxProject());

      await tester.pumpWidget(app(controller));

      final inspector = find.byKey(const ValueKey('inspector-panel'));
      expect(
        find.descendant(of: inspector, matching: find.text('작업')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inspector, matching: find.text('표 보기')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: inspector,
          matching: find.byKey(const ValueKey('sidebar-box-scroll')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: inspector,
          matching: find.byKey(const ValueKey('box-table-view')),
        ),
        findsNothing,
      );

      await tapVisible(
        tester,
        find.descendant(of: inspector, matching: find.text('표 보기')),
      );
      await tester.pump();

      expect(
        find.descendant(
          of: inspector,
          matching: find.byKey(const ValueKey('box-table-view')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: inspector,
          matching: find.byKey(const ValueKey('sidebar-box-scroll')),
        ),
        findsNothing,
      );
    });

    testWidgets('box table shows labels, unlabeled cells, and rounded coords', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(mixedBoxProject());

      await tester.pumpWidget(app(controller));
      await tapVisible(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('inspector-panel')),
          matching: find.text('표 보기'),
        ),
      );
      await tester.pump();

      final tableView = find.byKey(const ValueKey('box-table-view'));
      final table = tester.widget<DataTable>(
        find.descendant(of: tableView, matching: find.byType(DataTable)),
      );

      expect(
        table.rows,
        hasLength(2),
        reason: 'the mixed box project should expose two data rows',
      );
      expect(
        table.rows.map((row) => row.key),
        contains(const ValueKey('box-table-row-box-labeled')),
      );
      expect(
        table.rows.map((row) => row.key),
        contains(const ValueKey('box-table-row-box-unlabeled')),
      );
      expect(
        find.descendant(of: tableView, matching: find.text('Person')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tableView, matching: find.text('미라벨')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('box-table-view')),
          matching: find.text('40'),
        ),
        findsWidgets,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('box-table-view')),
          matching: find.text('10'),
        ),
        findsWidgets,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('box-table-view')),
          matching: find.text('20'),
        ),
        findsWidgets,
      );
      expect(find.text('No'), findsOneWidget);
      expect(find.text('Class'), findsOneWidget);
      expect(find.text('X'), findsOneWidget);
      expect(find.text('Y'), findsOneWidget);
      expect(find.text('W'), findsOneWidget);
      expect(find.text('H'), findsOneWidget);
    });

    testWidgets(
      'box table fits all coordinate columns without horizontal scroll',
      (tester) async {
        final controller = AppController();
        controller.loadProject(mixedBoxProject());

        await tester.pumpWidget(app(controller));
        await tapVisible(
          tester,
          find.descendant(
            of: find.byKey(const ValueKey('inspector-panel')),
            matching: find.text(WorkbenchCopy.inspectorTableTab),
          ),
        );
        await tester.pump();

        final tableView = find.byKey(const ValueKey('box-table-view'));
        final table = tester.widget<DataTable>(
          find.descendant(of: tableView, matching: find.byType(DataTable)),
        );

        expect(tester.widget(tableView), isNot(isA<SingleChildScrollView>()));
        expect(
          find.descendant(
            of: tableView,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is SingleChildScrollView &&
                  widget.scrollDirection == Axis.horizontal,
            ),
          ),
          findsNothing,
        );
        expect(table.columnSpacing, lessThanOrEqualTo(8));
        expect(table.horizontalMargin, lessThanOrEqualTo(6));
        expect(table.headingTextStyle?.fontSize, 12);
        expect(table.dataTextStyle?.fontSize, 12);
        final classHeaderWidths = tester
            .widgetList<SizedBox>(
              find.ancestor(
                of: find.descendant(
                  of: tableView,
                  matching: find.text('Class'),
                ),
                matching: find.byType(SizedBox),
              ),
            )
            .map((widget) => widget.width)
            .whereType<double>();
        final narrowestClassHeaderWidth = classHeaderWidths.reduce(
          (a, b) => a < b ? a : b,
        );
        expect(narrowestClassHeaderWidth, greaterThan(64));
        expect(
          find.descendant(of: tableView, matching: find.text('W')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: tableView, matching: find.text('H')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: tableView, matching: find.text('Width')),
          findsNothing,
        );
        expect(
          find.descendant(of: tableView, matching: find.text('Height')),
          findsNothing,
        );
      },
    );

    testWidgets('box table shows an empty state for images with no boxes', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());
      controller.selectImage(2);

      await tester.pumpWidget(app(controller));
      await tapVisible(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('inspector-panel')),
          matching: find.text('표 보기'),
        ),
      );
      await tester.pump();

      final tableView = find.byKey(const ValueKey('box-table-view'));
      expect(tableView, findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              widget.data == WorkbenchCopy.boxesNone &&
              widget.style == null,
        ),
        findsOneWidget,
      );
    });

    testWidgets('box table excludes deleted boxes', (tester) async {
      final controller = AppController();
      controller.loadProject(
        project().copyWith(
          images: [
            project().images.first.copyWith(
              boxes: const [
                BoundingBox(
                  id: 'box-visible',
                  x: 11,
                  y: 12,
                  width: 13,
                  height: 14,
                  status: BoxStatus.labeled,
                  labelId: 1,
                ),
                BoundingBox(
                  id: 'box-deleted',
                  x: 21,
                  y: 22,
                  width: 23,
                  height: 24,
                  status: BoxStatus.deleted,
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
        find.descendant(
          of: find.byKey(const ValueKey('inspector-panel')),
          matching: find.text('표 보기'),
        ),
      );
      await tester.pump();

      final tableView = find.byKey(const ValueKey('box-table-view'));
      final table = tester.widget<DataTable>(
        find.descendant(of: tableView, matching: find.byType(DataTable)),
      );

      expect(table.rows, hasLength(1));
      expect(
        table.rows.map((row) => row.key),
        contains(const ValueKey('box-table-row-box-visible')),
      );
      expect(
        table.rows.map((row) => row.key),
        isNot(contains(const ValueKey('box-table-row-box-deleted'))),
      );
    });

    testWidgets('box table marks invalid boxes with a warning icon', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(
        project().copyWith(
          images: [
            project().images.first.copyWith(
              boxes: const [
                BoundingBox(
                  id: 'box-invalid',
                  x: 90,
                  y: 70,
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
        find.descendant(
          of: find.byKey(const ValueKey('inspector-panel')),
          matching: find.text('표 보기'),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets('box table rows follow fixed-anchor display order', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(
        project().copyWith(
          images: [
            project().images.first.copyWith(
              boxes: const [
                BoundingBox(
                  id: 'box-a',
                  x: 60,
                  y: 0,
                  width: 20,
                  height: 20,
                  status: BoxStatus.proposal,
                ),
                BoundingBox(
                  id: 'box-b',
                  x: 40,
                  y: 9,
                  width: 20,
                  height: 20,
                  status: BoxStatus.proposal,
                ),
                BoundingBox(
                  id: 'box-c',
                  x: 20,
                  y: 18,
                  width: 20,
                  height: 20,
                  status: BoxStatus.proposal,
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
        find.descendant(
          of: find.byKey(const ValueKey('inspector-panel')),
          matching: find.text(WorkbenchCopy.inspectorTableTab),
        ),
      );
      await tester.pump();

      final tableView = find.byKey(const ValueKey('box-table-view'));
      final table = tester.widget<DataTable>(
        find.descendant(of: tableView, matching: find.byType(DataTable)),
      );

      expect(table.rows.map((row) => row.key), [
        const ValueKey('box-table-row-box-b'),
        const ValueKey('box-table-row-box-a'),
        const ValueKey('box-table-row-box-c'),
      ]);
    });

    testWidgets('clicking a box table row selects the canvas box', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(mixedBoxProject());

      await tester.pumpWidget(app(controller));
      await tapVisible(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('inspector-panel')),
          matching: find.text('표 보기'),
        ),
      );
      await tester.pump();

      await tapVisible(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('box-table-view')),
          matching: find.text('미라벨'),
        ),
      );

      expect(controller.selectedBoxId, 'box-unlabeled');
      expect(
        find.byKey(const ValueKey('selected-box-box-unlabeled')),
        findsOneWidget,
      );
    });

    testWidgets('box table highlights the selected box row', (tester) async {
      final controller = AppController();
      controller.loadProject(mixedBoxProject());

      await tester.pumpWidget(app(controller));
      await tapVisible(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('inspector-panel')),
          matching: find.text('표 보기'),
        ),
      );
      await tester.pump();
      await tapVisible(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('box-table-view')),
          matching: find.text('미라벨'),
        ),
      );

      final tableView = find.byKey(const ValueKey('box-table-view'));
      final table = tester.widget<DataTable>(
        find.descendant(of: tableView, matching: find.byType(DataTable)),
      );

      final labeledRow = table.rows.singleWhere(
        (row) => row.key == const ValueKey('box-table-row-box-labeled'),
      );
      final unlabeledRow = table.rows.singleWhere(
        (row) => row.key == const ValueKey('box-table-row-box-unlabeled'),
      );

      expect(unlabeledRow.selected, isTrue);
      expect(labeledRow.selected, isFalse);
    });

    testWidgets('box list selection updates overlay selection state', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));
      await tapVisible(tester, find.byKey(const ValueKey('box-row-box-1')));

      expect(controller.selectedBoxId, 'box-1');
      expect(find.byKey(const ValueKey('selected-box-box-1')), findsOneWidget);
    });

    testWidgets('right sidebar hides automatic box origin in box rows', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));

      final inspector = find.byKey(const ValueKey('inspector-panel'));
      expect(
        find.descendant(
          of: inspector,
          matching: find.text(WorkbenchCopy.proposalBox),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('box-row-box-1')),
          matching: find.textContaining(WorkbenchCopy.unlabeledBox),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'right sidebar groups label-needed boxes before completed boxes',
      (tester) async {
        final controller = AppController();
        controller.loadProject(mixedBoxProject());

        await tester.pumpWidget(app(controller));

        final widgets = tester.allWidgets.toList();
        final needHeadingIndex = widgets.indexWhere(
          (widget) => widget.key == const ValueKey('box-group-unlabeled'),
        );
        final doneHeadingIndex = widgets.indexWhere(
          (widget) => widget.key == const ValueKey('box-group-labeled'),
        );
        final unlabeledRowIndex = widgets.indexWhere(
          (widget) => widget.key == const ValueKey('box-row-box-unlabeled'),
        );
        final labeledRowIndex = widgets.indexWhere(
          (widget) => widget.key == const ValueKey('box-row-box-labeled'),
        );

        expect(needHeadingIndex, isNonNegative);
        expect(doneHeadingIndex, isNonNegative);
        expect(unlabeledRowIndex, isNonNegative);
        expect(labeledRowIndex, isNonNegative);
        expect(needHeadingIndex, lessThan(doneHeadingIndex));
        expect(unlabeledRowIndex, lessThan(labeledRowIndex));
      },
    );

    testWidgets('right sidebar box rows number boxes from top left', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(mixedBoxProject());

      await tester.pumpWidget(app(controller));

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('box-row-box-labeled')),
          matching: find.textContaining('#2'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('box-row-box-unlabeled')),
          matching: find.textContaining('#1'),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'right sidebar box rows number top to bottom then left to right',
      (tester) async {
        final controller = AppController();
        controller.loadProject(
          project().copyWith(
            images: [
              project().images.first.copyWith(
                boxes: const [
                  BoundingBox(
                    id: 'box-top-right',
                    x: 80,
                    y: 10,
                    width: 10,
                    height: 10,
                    status: BoxStatus.proposal,
                  ),
                  BoundingBox(
                    id: 'box-bottom-left',
                    x: 10,
                    y: 60,
                    width: 10,
                    height: 10,
                    status: BoxStatus.proposal,
                  ),
                ],
              ),
              project().images.last,
            ],
          ),
        );

        await tester.pumpWidget(app(controller));

        expect(
          find.descendant(
            of: find.byKey(const ValueKey('box-row-box-bottom-left')),
            matching: find.textContaining('#2'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('box-row-box-top-right')),
            matching: find.textContaining('#1'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('right sidebar box rows omit coordinates by default', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));

      final row = find.byKey(const ValueKey('box-row-box-1'));
      expect(
        find.descendant(of: row, matching: find.textContaining('x ')),
        findsNothing,
      );
      expect(
        find.descendant(of: row, matching: find.textContaining('area')),
        findsNothing,
      );
    });

    testWidgets('selected box details identify the selected display number', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(mixedBoxProject());
      controller.selectBox('box-unlabeled');

      await tester.pumpWidget(app(controller));

      final details = find.byKey(const ValueKey('selected-box-details'));
      expect(
        find.descendant(of: details, matching: find.textContaining('#2')),
        findsNothing,
      );
      expect(
        find.descendant(of: details, matching: find.textContaining('#1')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: details,
          matching: find.textContaining(WorkbenchCopy.unlabeledBox),
        ),
        findsOneWidget,
      );
    });

    testWidgets('selected box details show selected box coordinates', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));
      await tapVisible(tester, find.byKey(const ValueKey('box-row-box-1')));

      expect(
        find.byKey(const ValueKey('selected-box-details')),
        findsOneWidget,
      );
      expect(find.text(WorkbenchCopy.details), findsOneWidget);
      expect(find.textContaining('w 20'), findsWidgets);
      expect(find.textContaining('h 20'), findsWidgets);
    });

    testWidgets('review details show suggestion candidates and reason', (
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
        )
        ..selectBox('box-1');

      await tester.pumpWidget(app(controller));

      final details = find.byKey(const ValueKey('selected-box-details'));
      expect(
        find.descendant(
          of: details,
          matching: find.text(WorkbenchCopy.reviewRequired),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: details,
          matching: find.text(WorkbenchCopy.reviewReasonClassifierAmbiguous),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: details, matching: find.text('Person')),
        findsWidgets,
      );
      expect(
        find.descendant(of: details, matching: find.text('58%')),
        findsOneWidget,
      );
    });

    testWidgets(
      'selected box details stay inside work tab while table row selection persists',
      (tester) async {
        final controller = AppController();
        controller.loadProject(mixedBoxProject());
        controller.selectBox('box-unlabeled');

        await tester.pumpWidget(app(controller));

        final inspector = find.byKey(const ValueKey('inspector-panel'));
        expect(
          find.descendant(
            of: inspector,
            matching: find.byKey(const ValueKey('selected-box-details')),
          ),
          findsOneWidget,
        );

        await tapVisible(
          tester,
          find.descendant(of: inspector, matching: find.text('표 보기')),
        );
        await tester.pump();

        expect(
          find.descendant(
            of: inspector,
            matching: find.byKey(const ValueKey('selected-box-details')),
          ),
          findsNothing,
        );

        final tableView = find.byKey(const ValueKey('box-table-view'));
        final table = tester.widget<DataTable>(
          find.descendant(of: tableView, matching: find.byType(DataTable)),
        );
        final unlabeledRow = table.rows.singleWhere(
          (row) => row.key == const ValueKey('box-table-row-box-unlabeled'),
        );

        expect(unlabeledRow.selected, isTrue);
        expect(
          find.descendant(of: tableView, matching: find.text('미라벨')),
          findsOneWidget,
        );
      },
    );

    testWidgets('selected box details stay above the scrollable box list', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(manyLabeledBoxesProject());
      controller.selectBox('box-12');

      await tester.pumpWidget(app(controller));

      final details = find.byKey(const ValueKey('selected-box-details'));
      final scroll = find.byKey(const ValueKey('sidebar-box-scroll'));

      expect(details, findsOneWidget);
      expect(find.descendant(of: scroll, matching: details), findsNothing);
      expect(
        tester.getTopLeft(details).dy,
        lessThan(tester.getTopLeft(scroll).dy),
      );
    });

    testWidgets('right sidebar pins completion action below box scrolling', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(manyLabeledBoxesProject());

      await tester.pumpWidget(app(controller));

      final scroll = find.byKey(const ValueKey('sidebar-box-scroll'));
      final confirm = find.byKey(const ValueKey('confirm-image'));
      final initialRect = tester.getRect(confirm);

      expect(confirm, findsOneWidget);
      expect(find.descendant(of: scroll, matching: confirm), findsNothing);

      await tester.drag(scroll, const Offset(0, -320));
      await tester.pump();

      final afterScrollRect = tester.getRect(confirm);
      expect(afterScrollRect.top, closeTo(initialRect.top, 0.1));
      expect(afterScrollRect.bottom, closeTo(initialRect.bottom, 0.1));
    });

    testWidgets('selected box delete is not duplicated in the inspector', (
      tester,
    ) async {
      final controller = AppController()..loadProject(project());
      controller.selectBox('box-1');

      await tester.pumpWidget(app(controller));

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('inspector-panel')),
          matching: find.byKey(const ValueKey('delete-selected-box')),
        ),
        findsNothing,
      );
    });

    testWidgets('removes selected image from project after confirmation', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));
      await tester.tap(find.byKey(const ValueKey('remove-image-from-project')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('confirm-remove-image-from-project')),
      );
      await tester.pumpAndSettle();

      expect(controller.project!.images, hasLength(1));
      expect(controller.project!.images.single.id, 2);
    });

    testWidgets('inspector no longer duplicates labels or auto controls', (
      tester,
    ) async {
      final controller = AppController()..loadProject(project());

      await tester.pumpWidget(app(controller));

      final inspector = find.byKey(const ValueKey('inspector-panel'));
      expect(
        find.descendant(
          of: inspector,
          matching: find.byKey(const ValueKey('auto-boxes-current-image')),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: inspector,
          matching: find.byKey(const ValueKey('clear-current-image-boxes')),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: inspector,
          matching: find.text(WorkbenchCopy.labels),
        ),
        findsNothing,
      );
    });
  });
}
