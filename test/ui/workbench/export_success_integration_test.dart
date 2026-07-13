import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workbench_test_support.dart';

void main() {
  testWidgets('successful export closes warning and shows saved path', (
    tester,
  ) async {
    const path = r'C:\exports\coco.json';
    String? writtenPath;
    final controller = AppController()..loadProject(project());

    await tester.pumpWidget(
      app(
        controller,
        exportDestinationPicker: FakeCocoExportDestinationPicker(
          onPick: () => SynchronousFuture(path),
        ),
        exportWriter: (path) {
          writtenPath = path;
          return SynchronousFuture<void>(null);
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('export-coco')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('continue-coco-export')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(writtenPath, path);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const ValueKey('coco-export-success')), findsOneWidget);
    expect(find.textContaining(path), findsOneWidget);
  });
}
