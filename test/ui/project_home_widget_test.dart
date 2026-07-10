import 'dart:io';

import 'package:bbox_labeler/ui/app_controller.dart';
import 'package:bbox_labeler/ui/bbox_app.dart';
import 'package:bbox_labeler/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_auto_box_runtime.dart';
import '../support/memory_project_library.dart';

void main() {
  group('Project home', () {
    late MemoryProjectLibrary library;
    late AppController controller;

    setUp(() {
      library = MemoryProjectLibrary(
        rootPath: p.join(Directory.systemTemp.path, 'bbox_project_home'),
        fixedId: 'home-project',
      );
      controller = AppController(
        projectLibrary: library,
        autoBoxRuntime: FakeAutoBoxRuntime(),
      );
      addTearDown(controller.dispose);
    });

    testWidgets('first launch shows a Korean project home', (tester) async {
      await tester.pumpWidget(BboxApp(controller: controller));
      await tester.pump();
      await _pumpRealAsync(tester);

      expect(find.byKey(const ValueKey('project-home')), findsOneWidget);
      expect(find.text('프로젝트 홈'), findsOneWidget);
      expect(find.text('라벨링 프로젝트를 만들거나 이어서 작업하세요.'), findsOneWidget);
      expect(find.byKey(const ValueKey('new-project-name')), findsOneWidget);
      expect(find.text('프로젝트 이름'), findsOneWidget);
      expect(find.byKey(const ValueKey('create-project')), findsOneWidget);
      expect(find.text('만들기'), findsOneWidget);
      expect(find.text('프로젝트가 없습니다'), findsOneWidget);
      expect(find.text('새 프로젝트를 만들어 이미지 라벨링을 시작하세요.'), findsOneWidget);
      expect(find.text('No projects yet'), findsNothing);
      expect(find.text('Project name'), findsNothing);
      expect(find.text('New project'), findsNothing);
    });

    testWidgets('creating a project opens the workbench', (tester) async {
      await tester.pumpWidget(BboxApp(controller: controller));
      await tester.pump();
      await _pumpRealAsync(tester);

      await tester.enterText(
        find.byKey(const ValueKey('new-project-name')),
        'Demo Project',
      );
      await tester.tap(find.byKey(const ValueKey('create-project')));
      await tester.pump();
      await _pumpRealAsync(tester);

      expect(controller.hasProject, isTrue);
      expect(controller.project!.projectFilePath, isNotNull);
      expect(find.text('Demo Project'), findsOneWidget);
      expect(find.byKey(const ValueKey('choose-image-add')), findsNothing);
      expect(
        find.byKey(const ValueKey('empty-workbench-import-images')),
        findsOneWidget,
      );
    });

    testWidgets('returning launch lists and opens saved projects', (
      tester,
    ) async {
      await library.createProject('Saved Project');

      await tester.pumpWidget(BboxApp(controller: controller));
      await tester.pump();
      await _pumpRealAsync(tester);

      expect(
        find.byKey(const ValueKey('project-entry-home-project')),
        findsOneWidget,
      );
      expect(find.text('Saved Project'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('project-entry-home-project')),
      );
      await tester.pump();
      await _pumpRealAsync(tester);

      expect(controller.hasProject, isTrue);
      expect(controller.project!.name, 'Saved Project');
      expect(find.byKey(const ValueKey('choose-image-add')), findsNothing);
      expect(
        find.byKey(const ValueKey('empty-workbench-import-images')),
        findsOneWidget,
      );
    });

    testWidgets('project rows use Korean metadata and action labels', (
      tester,
    ) async {
      await library.createProject('저장된 프로젝트');

      await tester.pumpWidget(BboxApp(controller: controller));
      await tester.pump();
      await _pumpRealAsync(tester);

      expect(find.text('저장된 프로젝트'), findsOneWidget);
      expect(find.textContaining('이미지 0장'), findsOneWidget);
      expect(find.textContaining('완료 0장'), findsOneWidget);
      expect(find.textContaining('문제 0장'), findsOneWidget);

      final menu = find.byKey(const ValueKey('project-menu-home-project'));
      expect(tester.widget<PopupMenuButton<String>>(menu).tooltip, '프로젝트 작업');

      await tester.tap(menu);
      await tester.pumpAndSettle();

      expect(find.text('이름 변경'), findsOneWidget);
      expect(find.text('삭제'), findsOneWidget);
      expect(find.text('Rename'), findsNothing);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('renames a saved project from the project home', (
      tester,
    ) async {
      await library.createProject('Before');

      await tester.pumpWidget(BboxApp(controller: controller));
      await tester.pump();
      await _pumpRealAsync(tester);

      await tester.tap(find.byKey(const ValueKey('project-menu-home-project')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('rename-project-home-project')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('rename-project-name')),
        'After',
      );
      await tester.tap(find.byKey(const ValueKey('confirm-rename-project')));
      await tester.pumpAndSettle();

      expect(find.text('After'), findsOneWidget);
      expect(controller.projectLibraryEntries.single.name, 'After');
    });

    testWidgets(
      'deletes a saved project from the project home only after confirmation',
      (tester) async {
        await library.createProject('Delete Me');

        await tester.pumpWidget(BboxApp(controller: controller));
        await tester.pump();
        await _pumpRealAsync(tester);

        await tester.tap(
          find.byKey(const ValueKey('project-menu-home-project')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('delete-project-home-project')),
        );
        await tester.pumpAndSettle();

        expect(find.text('프로젝트 삭제'), findsOneWidget);
        expect(
          find.text('내부 프로젝트 데이터만 삭제됩니다. 원본 이미지는 삭제되지 않습니다.'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Source images will not be deleted'),
          findsNothing,
        );

        final confirmButton = tester.widget<FilledButton>(
          find.byKey(const ValueKey('confirm-delete-project')),
        );
        expect(
          confirmButton.style?.backgroundColor?.resolve(<WidgetState>{}),
          WorkbenchPalette.danger,
        );

        await tester.tap(find.byKey(const ValueKey('confirm-delete-project')));
        await tester.pump();
        await _pumpRealAsync(tester);

        expect(
          find.byKey(const ValueKey('project-entry-home-project')),
          findsNothing,
        );
        expect(controller.projectLibraryEntries, isEmpty);
      },
    );
  });
}

Future<void> _pumpRealAsync(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  await tester.pump();
}
