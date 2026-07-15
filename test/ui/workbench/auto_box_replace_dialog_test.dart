import 'package:bbox_labeler/ui/auto_box_replace_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_auto_box_runtime.dart';
import '../workbench/workbench_test_support.dart';

void main() {
  testWidgets('rerun dialog cancel preserves existing boxes', (tester) async {
    final runtime = FakeAutoBoxRuntime(
      detectionResult: const DetectionResult(
        detectorName: 'fake',
        boxes: [
          BoundingBox(
            id: 'replacement',
            x: 1,
            y: 1,
            width: 10,
            height: 10,
            status: BoxStatus.proposal,
          ),
        ],
      ),
    );
    final controller = AppController(autoBoxRuntime: runtime)
      ..loadProject(project());
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => confirmAndRunAutoBoxes(context, controller),
            child: const Text('run'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('auto-box-replace-dialog')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('cancel-auto-box-replace')));
    await tester.pumpAndSettle();

    expect(runtime.detectCount, 0);
    expect(controller.selectedImage!.visibleBoxes.single.id, 'box-1');
  });

  testWidgets('rerun dialog confirmation replaces existing boxes', (
    tester,
  ) async {
    final runtime = FakeAutoBoxRuntime(
      detectionResult: const DetectionResult(
        detectorName: 'fake',
        boxes: [
          BoundingBox(
            id: 'replacement',
            x: 1,
            y: 1,
            width: 10,
            height: 10,
            status: BoxStatus.proposal,
          ),
        ],
      ),
    );
    final controller = AppController(autoBoxRuntime: runtime)
      ..loadProject(project());
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => confirmAndRunAutoBoxes(context, controller),
            child: const Text('run'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-auto-box-replace')));
    await tester.pumpAndSettle();

    expect(runtime.detectCount, 1);
    expect(controller.selectedImage!.visibleBoxes.single.id, 'replacement');
  });
}
