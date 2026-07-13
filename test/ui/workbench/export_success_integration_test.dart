import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_auto_box_runtime.dart';
import 'workbench_test_support.dart';

void main() {
  testWidgets('successful export closes warning and shows saved path', (
    tester,
  ) async {
    const path = r'C:\exports\coco.json';
    String? writtenPath;
    final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime())
      ..loadProject(project());
    addTearDown(controller.dispose);

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
    await tester.pump(const Duration(milliseconds: 300));

    expect(writtenPath, path);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const ValueKey('coco-export-success')), findsOneWidget);
    expect(find.textContaining(path), findsOneWidget);
  });

  testWidgets(
    'in-flight export blocks barrier and Escape until one clean success close',
    (tester) async {
      const path = r'C:\exports\delayed-coco.json';
      final writePending = Completer<void>();
      var writes = 0;
      final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime())
        ..loadProject(project());
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        app(
          controller,
          exportDestinationPicker: FakeCocoExportDestinationPicker(
            onPick: () => SynchronousFuture(path),
          ),
          exportWriter: (_) {
            writes += 1;
            return writePending.future;
          },
        ),
      );
      await tester.tap(find.byKey(const ValueKey('export-coco')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('continue-coco-export')));
      await tester.pump();

      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(writes, 1);

      writePending.complete();
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(const ValueKey('coco-export-success')), findsOneWidget);
      expect(find.textContaining(path), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
