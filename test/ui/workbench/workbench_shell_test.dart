// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image/image.dart' as img;

import 'workbench_test_support.dart';

void main() {
  group('WorkbenchScreen', () {
    testWidgets('empty project shows image folder as the primary next action', (
      tester,
    ) async {
      final tempDir = Directory.systemTemp.createTempSync(
        'bbox_emptyproject_import',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final controller = AppController();
      controller.createProject('demo');

      var folderPickerCalled = false;
      await tester.pumpWidget(
        app(
          controller,
          imageImportPicker: FakeImageImportPicker(
            folderPath: tempDir.path,
            onPickFolder: () => folderPickerCalled = true,
          ),
        ),
      );

      expect(find.text(WorkbenchCopy.chooseFolderToStart), findsWidgets);
      expect(
        find.byKey(const ValueKey('empty-workbench-import-images')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('choose-image-add')), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('empty-workbench-import-images')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(WorkbenchCopy.addImageFolder).last);
      await tester.pump(const Duration(milliseconds: 500));

      expect(folderPickerCalled, isTrue);
      expect(controller.project!.images, isEmpty);
    });

    testWidgets('top bar presents project context and global actions', (
      tester,
    ) async {
      final controller = AppController();
      controller.createProject('Very Long Project Name For Layout Testing');

      await tester.pumpWidget(app(controller));

      expect(find.byKey(const ValueKey('workbench-shell')), findsOneWidget);
      expect(find.byKey(const ValueKey('workbench-top-bar')), findsOneWidget);
      expect(find.text(WorkbenchCopy.projectHome), findsOneWidget);
      expect(find.byKey(const ValueKey('choose-image-add')), findsNothing);
      expect(find.text(WorkbenchCopy.cocoExport), findsOneWidget);
      expect(find.byKey(const ValueKey('save-status-saved')), findsOneWidget);
    });

    testWidgets(
      'saves a project copy without replacing the internal project path',
      (tester) async {
        final tempDir = Directory.systemTemp.createTempSync(
          'bbox_workbench_snapshot',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final internalPath =
            '${tempDir.path}${Platform.pathSeparator}library'
            '${Platform.pathSeparator}project.bbox.json';
        final snapshotPath =
            '${tempDir.path}${Platform.pathSeparator}portable.bbox.json';
        final controller = AppController()
          ..createProject('demo', projectFilePath: internalPath);
        addTearDown(controller.dispose);
        var pickerCalls = 0;

        await tester.pumpWidget(
          app(
            controller,
            projectTransferPicker: FakeProjectTransferPicker(
              snapshotPath: snapshotPath,
              onPickSnapshot: () => pickerCalls += 1,
            ),
          ),
        );

        expect(find.byKey(const ValueKey('save-project-copy')), findsOneWidget);
        expect(find.byTooltip(WorkbenchCopy.saveProjectFile), findsOneWidget);

        await tester.runAsync(
          () => tester.tap(find.byKey(const ValueKey('save-project-copy'))),
        );
        await tester.pump();
        await tester.runAsync(() async {
          for (var attempt = 0; attempt < 100; attempt += 1) {
            if (await File(snapshotPath).exists()) return;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pump();

        expect(pickerCalls, 1);
        expect(File(snapshotPath).existsSync(), isTrue);
        expect(controller.project!.projectFilePath, internalPath);
        expect(
          find.text(WorkbenchCopy.projectFileSaved(snapshotPath)),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('save-project')), findsOneWidget);
      },
    );

    testWidgets('cancelling project copy save shows no feedback', (
      tester,
    ) async {
      final controller = AppController()
        ..createProject('demo', projectFilePath: 'internal.bbox.json');

      await tester.pumpWidget(app(controller));
      await tester.tap(find.byKey(const ValueKey('save-project-copy')));
      await tester.pump();

      expect(find.byType(SnackBar), findsNothing);
      expect(controller.project!.projectFilePath, 'internal.bbox.json');
    });

    testWidgets('top bar groups context status document and edit actions', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));

      expect(find.byKey(const ValueKey('top-context-group')), findsOneWidget);
      expect(find.byKey(const ValueKey('top-status-group')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('top-document-actions')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('top-edit-actions')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('top-toolbar-separator-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('top-toolbar-separator-2')),
        findsOneWidget,
      );
    });

    testWidgets('top bar action rail is visually subtle and aligned', (
      tester,
    ) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));

      final rail = find.byKey(const ValueKey('top-action-rail'));
      expect(rail, findsOneWidget);

      final statusRect = tester.getRect(
        find.byKey(const ValueKey('top-status-group')),
      );
      final documentRect = tester.getRect(
        find.byKey(const ValueKey('top-document-actions')),
      );
      final editRect = tester.getRect(
        find.byKey(const ValueKey('top-edit-actions')),
      );
      final separator = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byKey(const ValueKey('top-toolbar-separator-1')),
          matching: find.byType(DecoratedBox),
        ),
      );
      final decoration = separator.decoration as BoxDecoration;

      expect(statusRect.height, closeTo(documentRect.height, 0.1));
      expect(documentRect.height, closeTo(editRect.height, 0.1));
      expect(decoration.color, WorkbenchPalette.border);
      expect(decoration.color, isNot(Colors.black));
    });

    testWidgets('workbench palette uses orange accent colors', (tester) async {
      expect(WorkbenchPalette.accent, const Color(0xffd97706));
      expect(WorkbenchPalette.accentSoft, const Color(0xfffff3e0));
      expect(WorkbenchPalette.accentStrong, const Color(0xffb45309));
      expect(WorkbenchPalette.accentBorder, const Color(0xfff59e0b));
    });

    testWidgets('top bar uses Korean undo redo tooltips', (tester) async {
      final controller = AppController();
      controller.createProject('demo');

      await tester.pumpWidget(app(controller));

      final undoButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.undo),
      );
      final redoButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.redo),
      );

      expect(undoButton.tooltip, WorkbenchCopy.undo);
      expect(redoButton.tooltip, WorkbenchCopy.redo);
    });

    testWidgets('top bar image add appears after images exist', (tester) async {
      final controller = AppController();
      controller.loadProject(project());

      await tester.pumpWidget(app(controller));

      expect(find.byKey(const ValueKey('choose-image-add')), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, WorkbenchCopy.imageAdd),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('empty import menu can add an image folder', (tester) async {
      final tempDir = Directory.systemTemp.createTempSync(
        'bbox_empty_import_menu',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final imagePath = '${tempDir.path}${Platform.pathSeparator}bread.png';
      final fixture = img.Image(width: 32, height: 24);
      img.fill(fixture, color: img.ColorRgb8(8, 10, 12));
      File(imagePath).writeAsBytesSync(img.encodePng(fixture));

      final controller = AppController()..createProject('demo');
      var folderPickerCalled = false;

      await tester.pumpWidget(
        app(
          controller,
          imageImportPicker: FakeImageImportPicker(
            folderPath: tempDir.path,
            onPickFolder: () => folderPickerCalled = true,
          ),
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('empty-workbench-import-images')),
      );
      await tester.pumpAndSettle();
      expect(find.text(WorkbenchCopy.addImageFolder), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text(WorkbenchCopy.addImageFolder).last);
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();

      expect(folderPickerCalled, isTrue);
    });

    testWidgets('workbench shows importing progress', (tester) async {
      final controller = AppController()..createProject('demo');
      controller.debugSetImportProgressForTest(
        const ImageImportProgress(
          total: 10,
          processed: 3,
          added: 2,
          skipped: 1,
        ),
      );

      await tester.pumpWidget(app(controller));

      expect(
        find.byKey(const ValueKey('workbench-activity-bar')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('image-import-progress')), findsNothing);
      expect(find.byKey(const ValueKey('auto-boxes-feedback')), findsNothing);
      expect(find.textContaining('3 / 10'), findsOneWidget);
      expect(controller.imageImportProgress?.added, 2);
    });

    testWidgets('workbench shows scanning state before import total is known', (
      tester,
    ) async {
      final controller = AppController()..createProject('demo');
      controller.debugSetImportProgressForTest(null);
      controller.debugSetProjectActivityForTest(ProjectActivity.importing);

      await tester.pumpWidget(app(controller));

      expect(
        find.byKey(const ValueKey('workbench-activity-bar')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('image-import-progress')), findsNothing);
      expect(find.text(WorkbenchCopy.importScanning), findsOneWidget);
    });

    testWidgets('activity bar keeps one stable slot across idle and progress', (
      tester,
    ) async {
      final controller = AppController()..loadProject(project());

      await tester.pumpWidget(app(controller));

      final idleRect = tester.getRect(
        find.byKey(const ValueKey('workbench-activity-bar')),
      );
      expect(find.text(WorkbenchCopy.activityReady), findsOneWidget);

      controller.lastUserMessage = WorkbenchCopy.autoBoxesCreated(1);
      controller.notifyListeners();
      await tester.pump();

      final messageRect = tester.getRect(
        find.byKey(const ValueKey('workbench-activity-bar')),
      );
      expect(messageRect.height, idleRect.height);
      expect(find.text(WorkbenchCopy.autoBoxesCreated(1)), findsOneWidget);

      controller.debugSetImportProgressForTest(
        const ImageImportProgress(
          total: 10,
          processed: 3,
          added: 2,
          skipped: 1,
        ),
      );
      await tester.pump();

      final importRect = tester.getRect(
        find.byKey(const ValueKey('workbench-activity-bar')),
      );
      expect(importRect.height, idleRect.height);
      expect(find.textContaining('3 / 10'), findsOneWidget);
      expect(find.byKey(const ValueKey('image-import-progress')), findsNothing);
      expect(find.byKey(const ValueKey('auto-boxes-feedback')), findsNothing);
    });

    testWidgets(
      'missing source banner reconnects only the selected image from one file',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final tempDir = Directory.systemTemp.createTempSync(
          'bbox_relink_selected_file',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final replacementPath = '${tempDir.path}${Platform.pathSeparator}a.jpg';
        File(
          replacementPath,
        ).writeAsBytesSync(img.encodeJpg(fixtureImage(100, 80)));
        final missingPath =
            '${tempDir.path}${Platform.pathSeparator}missing'
            '${Platform.pathSeparator}a.jpg';
        final otherMissingPath =
            '${tempDir.path}${Platform.pathSeparator}other'
            '${Platform.pathSeparator}a.jpg';
        final missingProject = project().copyWith(
          images: [
            project().images.first.copyWith(
              sourcePath: missingPath,
              displayName: 'a.jpg',
              status: ImageStatus.confirmed,
            ),
            project().images.last.copyWith(
              sourcePath: otherMissingPath,
              displayName: 'a.jpg',
            ),
          ],
        );
        final controller = AppController()..loadProject(missingProject);
        addTearDown(controller.dispose);
        await tester.runAsync(controller.refreshSourceAvailability);
        var filePickerCalls = 0;

        await tester.pumpWidget(
          app(
            controller,
            imageImportPicker: FakeImageImportPicker(
              filePaths: [replacementPath],
              onPickFiles: () => filePickerCalls += 1,
            ),
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const ValueKey('missing-source-banner')),
          findsOneWidget,
        );
        expect(find.text('원본 이미지 2개를 찾을 수 없습니다'), findsOneWidget);
        expect(find.text('라벨링 데이터는 보존되어 있습니다.'), findsWidgets);
        expect(
          find.byKey(const ValueKey('relink-source-files')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('relink-source-folder')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('missing-selected-source')),
          findsOneWidget,
        );
        expect(controller.project!.images.first.status, ImageStatus.confirmed);
        expect(tester.takeException(), isNull);

        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('relink-source-files')));
          for (var attempt = 0; attempt < 100; attempt += 1) {
            if (controller.project!.images.first.sourcePath ==
                    replacementPath &&
                controller.projectActivity == ProjectActivity.idle) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
              return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pumpAndSettle();

        expect(filePickerCalls, 1);
        expect(controller.project!.images.first.sourcePath, replacementPath);
        expect(controller.project!.images.last.sourcePath, otherMissingPath);
        expect(controller.project!.images.first.status, ImageStatus.confirmed);
        expect(find.text('1개 연결 · 0개 미해결 · 0개 중복 후보'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('missing-selected-source')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('missing source banner reconnects images from a folder', (
      tester,
    ) async {
      final tempDir = Directory.systemTemp.createTempSync('bbox_relink_folder');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final replacementPath =
          '${tempDir.path}${Platform.pathSeparator}empty.jpg';
      File(
        replacementPath,
      ).writeAsBytesSync(img.encodeJpg(fixtureImage(100, 80)));
      final missingPath =
          '${tempDir.path}${Platform.pathSeparator}missing'
          '${Platform.pathSeparator}empty.jpg';
      final missingProject = project().copyWith(
        images: [
          project().images.last.copyWith(
            sourcePath: missingPath,
            status: ImageStatus.confirmed,
          ),
        ],
      );
      final controller = AppController()..loadProject(missingProject);
      addTearDown(controller.dispose);
      await tester.runAsync(controller.refreshSourceAvailability);
      var folderPickerCalls = 0;

      await tester.pumpWidget(
        app(
          controller,
          imageImportPicker: FakeImageImportPicker(
            folderPath: tempDir.path,
            onPickFolder: () => folderPickerCalls += 1,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('원본 이미지 1개를 찾을 수 없습니다'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('relink-source-folder')));
        for (var attempt = 0; attempt < 100; attempt += 1) {
          if (controller.project!.images.single.sourcePath == replacementPath &&
              controller.projectActivity == ProjectActivity.idle) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();

      expect(folderPickerCalls, 1);
      expect(controller.project!.images.single.sourcePath, replacementPath);
      expect(controller.project!.images.single.status, ImageStatus.confirmed);
      expect(find.text('1개 연결 · 0개 미해결 · 0개 중복 후보'), findsOneWidget);
      expect(find.byKey(const ValueKey('missing-source-banner')), findsNothing);
      expect(
        find.byKey(const ValueKey('missing-selected-source')),
        findsNothing,
      );
    });

    testWidgets(
      'reconnect cancellation changes nothing and only validation disables actions',
      (tester) async {
        final tempDir = Directory.systemTemp.createTempSync(
          'bbox_relink_cancel',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final missingPath =
            '${tempDir.path}${Platform.pathSeparator}missing.jpg';
        final controller = AppController()
          ..loadProject(
            project().copyWith(
              images: [
                project().images.first.copyWith(sourcePath: missingPath),
              ],
            ),
          );
        addTearDown(controller.dispose);
        await tester.runAsync(controller.refreshSourceAvailability);
        var filePickerCalls = 0;
        var folderPickerCalls = 0;

        await tester.pumpWidget(
          app(
            controller,
            imageImportPicker: FakeImageImportPicker(
              onPickFiles: () => filePickerCalls += 1,
              onPickFolder: () => folderPickerCalls += 1,
            ),
          ),
        );

        controller.debugSetProjectActivityForTest(ProjectActivity.validating);
        await tester.pump();
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('relink-source-files')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('relink-source-folder')),
              )
              .onPressed,
          isNull,
        );

        controller.debugSetProjectActivityForTest(ProjectActivity.importing);
        await tester.pump();
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('relink-source-files')),
              )
              .onPressed,
          isNotNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('relink-source-folder')),
              )
              .onPressed,
          isNotNull,
        );

        await tester.tap(find.byKey(const ValueKey('relink-source-files')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('relink-source-folder')));
        await tester.pump();

        expect(filePickerCalls, 1);
        expect(folderPickerCalls, 1);
        expect(controller.project!.images.single.sourcePath, missingPath);
        expect(find.byType(SnackBar), findsNothing);
      },
    );

    testWidgets(
      'reconnect banner allows only one action while the picker is pending',
      (tester) async {
        const replacementPath = 'replacement/bread.jpg';
        const missingPath = 'missing/bread.jpg';
        final relinkService = ImmediateRelinkSourceService(
          replacementPath: replacementPath,
        );
        final controller = AppController(sourceRelinkService: relinkService)
          ..loadProject(
            project().copyWith(
              images: [
                project().images.first.copyWith(
                  sourcePath: missingPath,
                  displayName: 'bread.jpg',
                  status: ImageStatus.confirmed,
                ),
              ],
            ),
          );
        addTearDown(controller.dispose);
        await controller.refreshSourceAvailability();
        final picker = DelayedImageImportPicker();

        await tester.pumpWidget(app(controller, imageImportPicker: picker));

        await tester.tap(find.byKey(const ValueKey('relink-source-files')));
        await tester.pump();

        expect(picker.fileCalls, 1);
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('relink-source-files')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('relink-source-folder')),
              )
              .onPressed,
          isNull,
        );

        await tester.tap(find.byKey(const ValueKey('relink-source-files')));
        await tester.tap(find.byKey(const ValueKey('relink-source-folder')));
        await tester.pump();

        expect(picker.fileCalls, 1);
        expect(picker.folderCalls, 0);

        picker.fileResult.complete([replacementPath]);
        await tester.pump();
        await tester.pump();

        expect(picker.fileCalls, 1);
        expect(picker.folderCalls, 0);
        expect(relinkService.fileRelinkCalls, 1);
        expect(relinkService.folderRelinkCalls, 0);
        expect(controller.project!.images.single.status, ImageStatus.confirmed);
        expect(find.text('1개 연결 · 0개 미해결 · 0개 중복 후보'), findsOneWidget);
      },
    );
  });
}
