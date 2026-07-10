import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/ui/label_management_popover.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('creates a label with name color and shortcut', (tester) async {
    String? createdName;
    int? createdColor;
    String? createdShortcut;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LabelManagementPopover(
            labels: const [],
            onCreateLabel: (name, color, shortcut) {
              createdName = name;
              createdColor = color;
              createdShortcut = shortcut;
            },
            onUpdateLabel: (_, _, _, _) {},
          ),
        ),
      ),
    );

    expect(find.text('라벨 이름'), findsOneWidget);
    expect(find.text('키'), findsOneWidget);
    expect(find.text('추가'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('label-name-input')),
      'Bread',
    );
    await tester.enterText(
      find.byKey(const ValueKey('label-shortcut-input')),
      '1',
    );
    await tester.tap(find.byKey(const ValueKey('create-managed-label')));
    await tester.pump();

    expect(createdName, 'Bread');
    expect(createdColor, isNotNull);
    expect(createdShortcut, '1');
  });

  testWidgets('shows existing label shortcut color and name', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LabelManagementPopover(
            labels: const [
              LabelClass(
                id: 1,
                name: 'Bread',
                color: 0xff123456,
                shortcut: '1',
              ),
            ],
            onCreateLabel: (_, _, _) {},
            onUpdateLabel: (_, _, _, _) {},
          ),
        ),
      ),
    );

    expect(find.text('1'), findsOneWidget);
    expect(find.text('Bread'), findsOneWidget);
    expect(find.byKey(const ValueKey('managed-label-color-1')), findsOneWidget);
  });

  testWidgets('shows inline error when create callback rejects input', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LabelManagementPopover(
            labels: const [
              LabelClass(
                id: 1,
                name: 'Bread',
                color: 0xff123456,
                shortcut: '1',
              ),
            ],
            onCreateLabel: (_, _, _) {
              throw StateError('Duplicate label name: Bread');
            },
            onUpdateLabel: (_, _, _, _) {},
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('label-name-input')),
      'Bread',
    );
    await tester.tap(find.byKey(const ValueKey('create-managed-label')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('label-management-error')),
      findsOneWidget,
    );
    expect(find.text('Duplicate label name: Bread'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('label-management-popover')),
      findsOneWidget,
    );
  });

  testWidgets('updates an existing label name color and shortcut', (
    tester,
  ) async {
    int? updatedId;
    String? updatedName;
    int? updatedColor;
    String? updatedShortcut;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LabelManagementPopover(
            labels: const [
              LabelClass(
                id: 1,
                name: 'Bread',
                color: 0xff123456,
                shortcut: '1',
              ),
            ],
            onCreateLabel: (_, _, _) {},
            onUpdateLabel: (id, name, color, shortcut) {
              updatedId = id;
              updatedName = name;
              updatedColor = color;
              updatedShortcut = shortcut;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Bread'));
    await tester.pump();
    expect(find.text('수정'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('label-name-input')),
      'Helmet',
    );
    await tester.enterText(
      find.byKey(const ValueKey('label-shortcut-input')),
      '2',
    );
    await tester.tap(find.byTooltip('Color'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuItem<int>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('update-managed-label')));
    await tester.pump();

    expect(updatedId, 1);
    expect(updatedName, 'Helmet');
    expect(updatedColor, isNot(0xff123456));
    expect(updatedShortcut, '2');
  });

  testWidgets('shows inline error when update callback rejects changes', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LabelManagementPopover(
            labels: const [
              LabelClass(
                id: 1,
                name: 'Bread',
                color: 0xff123456,
                shortcut: '1',
              ),
            ],
            onCreateLabel: (_, _, _) {},
            onUpdateLabel: (_, _, _, _) {
              throw Exception('bad update');
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Bread'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('label-name-input')),
      'Helmet',
    );
    await tester.tap(find.byKey(const ValueKey('update-managed-label')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('label-management-error')),
      findsOneWidget,
    );
    expect(find.textContaining('bad update'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('label-management-popover')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('update-managed-label')), findsOneWidget);
  });
}
