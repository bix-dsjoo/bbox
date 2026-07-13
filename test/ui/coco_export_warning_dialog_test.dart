import 'dart:async';

import 'package:bbox_labeler/export/coco_exporter.dart';
import 'package:bbox_labeler/ui/coco_export_warning_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _summary = CocoExportSummary(
  unconfirmedImageCount: 1,
  unlabeledProposalBoxCount: 1,
  errorImageCount: 0,
  blockingErrors: [],
);

Widget _app({
  required Future<String?> Function() pickDestination,
  required Future<void> Function(String path) writeExport,
  ValueChanged<String>? onSuccess,
}) {
  return MaterialApp(
    home: Scaffold(
      body: CocoExportWarningDialog(
        summary: _summary,
        pickDestination: pickDestination,
        writeExport: writeExport,
        onClose: () {},
        onSuccess: onSuccess ?? (_) {},
      ),
    ),
  );
}

void main() {
  testWidgets('cancel restores retry and a second attempt succeeds', (
    tester,
  ) async {
    var picks = 0;
    String? writtenPath;
    String? succeededPath;
    await tester.pumpWidget(
      _app(
        pickDestination: () async => ++picks == 1 ? null : 'coco.json',
        writeExport: (path) async => writtenPath = path,
        onSuccess: (path) => succeededPath = path,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('continue-coco-export')));
    await tester.pump();
    expect(
      tester
          .widget<ElevatedButton>(
            find.byKey(const ValueKey('continue-coco-export')),
          )
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(const ValueKey('continue-coco-export')));
    await tester.pump();
    expect(picks, 2);
    expect(writtenPath, 'coco.json');
    expect(succeededPath, 'coco.json');
  });

  testWidgets('delayed picker is single flight', (tester) async {
    final pending = Completer<String?>();
    var picks = 0;
    await tester.pumpWidget(
      _app(
        pickDestination: () {
          picks += 1;
          return pending.future;
        },
        writeExport: (_) async {},
      ),
    );

    await tester.tap(find.byKey(const ValueKey('continue-coco-export')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('continue-coco-export')),
      warnIfMissed: false,
    );
    await tester.pump();

    expect(picks, 1);
    expect(
      tester
          .widget<ElevatedButton>(
            find.byKey(const ValueKey('continue-coco-export')),
          )
          .onPressed,
      isNull,
    );
    pending.complete(null);
    await tester.pump();
  });

  testWidgets('picker failure shows feedback and restores retry', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        pickDestination: () => Future.error(Exception('picker failed')),
        writeExport: (_) async {},
      ),
    );

    await tester.tap(find.byKey(const ValueKey('continue-coco-export')));
    await tester.pump();

    expect(find.byKey(const ValueKey('export-attempt-error')), findsOneWidget);
    expect(
      tester
          .widget<ElevatedButton>(
            find.byKey(const ValueKey('continue-coco-export')),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('write failure shows feedback and restores retry', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        pickDestination: () async => 'coco.json',
        writeExport: (_) => Future.error(Exception('write failed')),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('continue-coco-export')));
    await tester.pump();

    expect(find.byKey(const ValueKey('export-attempt-error')), findsOneWidget);
    expect(
      tester
          .widget<ElevatedButton>(
            find.byKey(const ValueKey('continue-coco-export')),
          )
          .onPressed,
      isNotNull,
    );
  });
}
