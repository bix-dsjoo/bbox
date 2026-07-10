import 'dart:async';
import 'dart:io';

import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/detector/auto_box_service.dart';
import 'package:bbox_labeler/ui/app_controller.dart';
import 'package:bbox_labeler/ui/app_theme.dart';
import 'package:bbox_labeler/ui/bbox_app.dart';
import 'package:bbox_labeler/ui/label_management_popover.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import 'support/memory_project_library.dart';
import 'support/fake_auto_box_runtime.dart';

void main() {
  testWidgets('first paint does not wait for detector warm up', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync('bbox_warm_up_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final warmUpCompleter = Completer<void>();
    final runtime = FakeAutoBoxRuntime(
      state: AutoBoxState.starting,
      warmUpCompleter: warmUpCompleter,
    );
    final controller = AppController(
      autoBoxRuntime: runtime,
      projectLibrary: MemoryProjectLibrary(
        rootPath: tempDir.path,
        fixedId: 'warm-up-project',
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(BboxApp(controller: controller));
    await tester.pump();

    expect(find.byKey(const ValueKey('project-home')), findsOneWidget);
    expect(runtime.warmUpCount, 1);
  });

  testWidgets('detached lifecycle requests detector shutdown once', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync('bbox_detached_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final runtime = FakeAutoBoxRuntime();
    final controller = AppController(
      autoBoxRuntime: runtime,
      projectLibrary: MemoryProjectLibrary(
        rootPath: tempDir.path,
        fixedId: 'detached-project',
      ),
    );
    addTearDown(controller.dispose);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );

    await tester.pumpWidget(BboxApp(controller: controller));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await tester.pump();

    expect(runtime.shutdownCount, 1);
  });

  testWidgets('detector warm up failure keeps the workbench usable', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'bbox_warm_up_failure_test',
    );
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final warmUpCompleter = Completer<void>();
    final runtime = FakeAutoBoxRuntime(
      state: AutoBoxState.starting,
      warmUpCompleter: warmUpCompleter,
    );
    final controller =
        AppController(
          autoBoxRuntime: runtime,
          projectLibrary: MemoryProjectLibrary(
            rootPath: tempDir.path,
            fixedId: 'warm-up-failure-project',
          ),
        )..loadProject(
          AnnotationProject.empty(name: 'Warm-up failure').copyWith(
            status: ProjectStatus.ready,
            images: const [
              AnnotatedImage(
                id: 1,
                sourcePath: 'missing.jpg',
                displayName: 'missing.jpg',
                width: 100,
                height: 80,
                status: ImageStatus.needsReview,
              ),
            ],
          ),
        );
    addTearDown(controller.dispose);

    await tester.pumpWidget(BboxApp(controller: controller));
    await tester.pump();

    final error = StateError('model unavailable');
    runtime.setState(AutoBoxState.failed, error: error);
    warmUpCompleter.completeError(error);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('workbench-shell')), findsOneWidget);
    expect(find.text('자동 박스 다시 시도'), findsOneWidget);
  });

  testWidgets('app root provides FORUI theme with Pretendard typography', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync('bbox_theme_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final controller = AppController(
      autoBoxRuntime: FakeAutoBoxRuntime(),
      projectLibrary: MemoryProjectLibrary(
        rootPath: tempDir.path,
        fixedId: 'theme-project',
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(BboxApp(controller: controller));
    await tester.pump();

    final context = tester.element(find.byKey(const ValueKey('project-home')));
    final foruiTheme = FTheme.of(context);
    final materialTheme = Theme.of(context);

    expect(foruiTheme.typography.body.fontFamily, 'Pretendard');
    expect(foruiTheme.typography.display.fontFamily, 'Pretendard');
    expect(materialTheme.textTheme.bodyMedium?.fontFamily, 'Pretendard');
  });

  testWidgets('project home creates a new project and opens the workbench', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync('bbox_widget_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final controller = AppController(
      autoBoxRuntime: FakeAutoBoxRuntime(),
      projectLibrary: MemoryProjectLibrary(
        rootPath: tempDir.path,
        fixedId: 'widget-project',
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(BboxApp(controller: controller));
    await tester.pump();
    await _pumpRealAsync(tester);

    expect(find.text('프로젝트 홈'), findsOneWidget);
    expect(find.text('Bounding Box Labeler'), findsNothing);
    expect(find.byKey(const ValueKey('new-project-name')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('new-project-name')),
      'Demo Project',
    );
    await tester.tap(find.byKey(const ValueKey('create-project')));
    await _pumpForuiTap(tester);
    await tester.pump();
    await _pumpRealAsync(tester);

    expect(find.text('Demo Project'), findsOneWidget);
    expect(find.byKey(const ValueKey('choose-image-add')), findsNothing);
    expect(
      find.byKey(const ValueKey('empty-workbench-import-images')),
      findsOneWidget,
    );
  });

  testWidgets('project home uses Pretendard and FORUI primary action', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'bbox_home_visual_test',
    );
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final controller = AppController(
      autoBoxRuntime: FakeAutoBoxRuntime(),
      projectLibrary: MemoryProjectLibrary(
        rootPath: tempDir.path,
        fixedId: 'home-visual-project',
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(BboxApp(controller: controller));
    await tester.pump();
    await _pumpRealAsync(tester);

    expect(find.byKey(const ValueKey('project-home-shell')), findsOneWidget);
    expect(find.byKey(const ValueKey('create-project-forui')), findsOneWidget);

    final title = tester.widget<Text>(find.text('프로젝트 홈'));
    expect(title.style?.fontFamily, 'Pretendard');
  });

  testWidgets('workbench project home action saves and returns home', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'bbox_widget_home_return',
    );
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final controller = AppController(
      autoBoxRuntime: FakeAutoBoxRuntime(),
      projectLibrary: MemoryProjectLibrary(
        rootPath: tempDir.path,
        fixedId: 'home-return-project',
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(BboxApp(controller: controller));
    await tester.pump();
    await _pumpRealAsync(tester);
    await tester.enterText(
      find.byKey(const ValueKey('new-project-name')),
      'Return Demo',
    );
    await tester.tap(find.byKey(const ValueKey('create-project')));
    await _pumpForuiTap(tester);
    await tester.pump();
    await _pumpRealAsync(tester);

    expect(find.byKey(const ValueKey('project-home-action')), findsOneWidget);
    expect(find.byKey(const ValueKey('save-status-saved')), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('project-home-action')));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    expect(find.byKey(const ValueKey('project-home')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('project-entry-home-return-project')),
      findsOneWidget,
    );
    expect(controller.hasProject, isFalse);
  });

  testWidgets('workbench exposes refreshed shell and FORUI toolbar actions', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'bbox_workbench_visual',
    );
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final controller = AppController(
      autoBoxRuntime: FakeAutoBoxRuntime(),
      projectLibrary: MemoryProjectLibrary(
        rootPath: tempDir.path,
        fixedId: 'workbench-visual-project',
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(BboxApp(controller: controller));
    await tester.pump();
    await _pumpRealAsync(tester);
    await tester.enterText(
      find.byKey(const ValueKey('new-project-name')),
      'Workbench Visual',
    );
    await tester.tap(find.byKey(const ValueKey('create-project')));
    await _pumpForuiTap(tester);
    await tester.pump();
    await _pumpRealAsync(tester);

    expect(
      find.byKey(const ValueKey('workbench-forui-toolbar')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('save-status-badge')), findsOneWidget);
    expect(find.byKey(const ValueKey('workbench-shell')), findsOneWidget);
  });

  testWidgets('workbench stays open when project home save fails', (
    tester,
  ) async {
    final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime());
    addTearDown(controller.dispose);
    controller.createProject('Unsaved Direct Project');

    await tester.pumpWidget(BboxApp(controller: controller));
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('project-home-action')));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    expect(find.byKey(const ValueKey('choose-image-add')), findsNothing);
    expect(find.byKey(const ValueKey('project-home')), findsNothing);
    expect(find.textContaining('프로젝트 홈으로 돌아가지 못했습니다'), findsOneWidget);
    expect(find.byKey(const ValueKey('save-status-failed')), findsOneWidget);
  });

  testWidgets('label management popover uses refreshed action button', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: BboxAppTheme.materialTheme,
        builder: (context, child) => FTheme(
          data: BboxAppTheme.foruiTheme,
          child: FToaster(child: FTooltipGroup(child: child!)),
        ),
        home: Scaffold(
          body: Center(
            child: LabelManagementPopover(
              labels: const [],
              onCreateLabel: (_, _, _) {},
              onUpdateLabel: (_, _, _, _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('label-management-popover')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('create-managed-label-forui')),
      findsOneWidget,
    );
  });
}

Future<void> _pumpRealAsync(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  await tester.pump();
}

Future<void> _pumpForuiTap(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 150));
}
