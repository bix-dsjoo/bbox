import 'dart:io';

import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/project/project_library.dart';
import 'package:bbox_labeler/ui/app_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('AppController project library', () {
    late Directory tempDir;
    late ProjectLibrary library;
    late AppController controller;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'bbox_controller_library',
      );
      library = ProjectLibrary(
        rootPath: tempDir.path,
        clock: () => DateTime.utc(2026, 7, 7, 5, 30),
        idGenerator: (name, timestamp) => 'controller-project',
      );
      controller = AppController(projectLibrary: library);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await _deleteTempDir(tempDir);
      }
    });

    test('loads library entries and creates a saved library project', () async {
      await controller.loadProjectLibrary();
      expect(controller.projectLibraryEntries, isEmpty);

      await controller.createLibraryProject('Demo');

      expect(controller.hasProject, isTrue);
      expect(controller.project!.name, 'Demo');
      expect(controller.project!.projectFilePath, isNotNull);
      expect(await File(controller.project!.projectFilePath!).exists(), isTrue);
      expect(controller.projectLibraryEntries.single.id, 'controller-project');
      expect(controller.projectLibraryEntries.single.name, 'Demo');
    });

    test('opens a project by library id and selects the first image', () async {
      final project = await library.createProject('Open Me');
      final saved = project.copyWith(
        images: const [
          AnnotatedImage(
            id: 7,
            sourcePath: 'C:\\images\\a.jpg',
            displayName: 'a.jpg',
            width: 100,
            height: 80,
            status: ImageStatus.needsReview,
          ),
        ],
      );
      controller.loadProject(saved);
      await controller.saveProject(saved.projectFilePath);

      final reloaded = AppController(projectLibrary: library);
      await reloaded.loadProjectLibrary();
      await reloaded.openLibraryProject('controller-project');

      expect(reloaded.project!.name, 'Open Me');
      expect(reloaded.selectedImageId, 7);
    });

    test(
      'refreshes library index after autosaved annotation changes',
      () async {
        await controller.createLibraryProject('Autosave');
        final imageDir = Directory(p.join(tempDir.path, 'images'));
        await imageDir.create();

        await controller.addImagesFromFolder(imageDir.path);
        await controller.saveProject();
        await controller.loadProjectLibrary();

        expect(controller.projectLibraryEntries.single.imageCount, 0);
      },
    );

    test('renames and deletes projects through the library', () async {
      await controller.createLibraryProject('Before');
      final projectPath = controller.project!.projectFilePath!;

      await controller.renameLibraryProject('controller-project', 'After');
      expect(controller.project!.name, 'After');
      expect(controller.projectLibraryEntries.single.name, 'After');

      await controller.deleteLibraryProject('controller-project');
      expect(await File(projectPath).exists(), isFalse);
      expect(controller.projectLibraryEntries, isEmpty);
      expect(controller.hasProject, isFalse);
    });

    test('validates missing image source files before continuing', () async {
      await controller.createLibraryProject('Validate Sources');
      controller.loadProject(
        controller.project!.copyWith(
          images: const [
            AnnotatedImage(
              id: 1,
              sourcePath: 'C:\\does-not-exist\\a.jpg',
              displayName: 'a.jpg',
              width: 100,
              height: 80,
              status: ImageStatus.needsReview,
            ),
          ],
        ),
      );
      await controller.saveProject();

      final missing = await controller.validateSourceFiles();

      expect(missing, ['C:\\does-not-exist\\a.jpg']);
      expect(controller.project!.images.single.status, ImageStatus.error);
    });

    test('returns to project home after saving the current project', () async {
      await controller.createLibraryProject('Home Demo');
      controller.loadProject(
        controller.project!.copyWith(
          images: const [
            AnnotatedImage(
              id: 1,
              sourcePath: 'done.jpg',
              displayName: 'done.jpg',
              width: 100,
              height: 80,
              status: ImageStatus.confirmed,
            ),
          ],
        ),
      );

      await controller.returnToProjectHome();

      expect(controller.hasProject, isFalse);
      expect(controller.selectedImageId, isNull);
      expect(controller.selectedBoxId, isNull);
      expect(controller.saveStatus, SaveStatus.saved);
      expect(controller.lastSaveError, isNull);
      expect(controller.projectLibraryEntries.single.name, 'Home Demo');
      expect(controller.projectLibraryEntries.single.imageCount, 1);
      expect(controller.projectLibraryEntries.single.confirmedImageCount, 1);
    });

    test('keeps the project open when returning home cannot save', () async {
      controller.createProject('Unsaved Direct Project');

      await expectLater(
        controller.returnToProjectHome(),
        throwsA(isA<StateError>()),
      );

      expect(controller.hasProject, isTrue);
      expect(controller.project!.name, 'Unsaved Direct Project');
      expect(controller.saveStatus, SaveStatus.failed);
      expect(controller.lastSaveError, isA<StateError>());
    });
  });
}

Future<void> _deleteTempDir(Directory directory) async {
  for (var attempt = 0; attempt < 5; attempt += 1) {
    try {
      await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 4) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
