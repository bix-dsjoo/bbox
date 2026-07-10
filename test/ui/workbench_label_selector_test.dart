import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/ui/workbench_copy.dart';
import 'package:bbox_labeler/ui/workbench_label_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('filters labels and assigns the selected label', (tester) async {
    int? assignedLabelId;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkbenchLabelSelector(
            labels: const [
              LabelClass(id: 1, name: 'Person', color: 0xffe64a19),
              LabelClass(id: 2, name: 'Vehicle', color: 0xff1976d2),
            ],
            onAssignLabel: (labelId) => assignedLabelId = labelId,
            onCreateLabel: (_) {},
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('label-selector-input')),
      'veh',
    );
    await tester.pump();

    expect(find.text('Vehicle'), findsOneWidget);
    expect(find.text('Person'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('label-option-2')));
    await tester.pump();

    expect(assignedLabelId, 2);
  });

  testWidgets('does not create labels from typed search text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkbenchLabelSelector(
            labels: const [
              LabelClass(id: 1, name: 'Person', color: 0xffe64a19),
            ],
            onAssignLabel: (_) {},
            onCreateLabel: (_) {},
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('label-selector-input')),
      'Helmet',
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('create-label-option')), findsNothing);
    expect(find.text(WorkbenchCopy.noMatchingLabels), findsOneWidget);
  });

  testWidgets('enter does nothing when there is no matching label', (
    tester,
  ) async {
    String? createdLabelName;
    int? assignedLabelId;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkbenchLabelSelector(
            labels: const [
              LabelClass(id: 1, name: 'Person', color: 0xffe64a19),
            ],
            onAssignLabel: (labelId) => assignedLabelId = labelId,
            onCreateLabel: (name) => createdLabelName = name,
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('label-selector-input')),
      'Box',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(createdLabelName, isNull);
    expect(assignedLabelId, isNull);
  });

  testWidgets('shows inline error text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkbenchLabelSelector(
            labels: const [],
            errorText: WorkbenchCopy.duplicateLabel,
            onAssignLabel: (_) {},
            onCreateLabel: (_) {},
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('label-selector-error')), findsOneWidget);
    expect(find.text(WorkbenchCopy.duplicateLabel), findsOneWidget);
  });
}
