import 'dart:async';
import 'dart:io';

import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/project/project_library.dart';
import 'package:bbox_labeler/project/project_snapshot_service.dart';
import 'package:bbox_labeler/project/project_store.dart';
import 'package:bbox_labeler/project/source_relink_service.dart';
import 'package:bbox_labeler/ui/app_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../support/fake_auto_box_runtime.dart';

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
      expect(controller.project!.images.single.status, ImageStatus.needsReview);
      expect(controller.sourceAvailability[1], SourceAvailability.missing);
      expect(controller.missingSourceCount, 1);
    });

    test(
      'saves a transferable snapshot without changing library path',
      () async {
        await controller.createLibraryProject('Transfer');
        final internalPath = controller.project!.projectFilePath!;
        controller.loadProject(
          controller.project!.copyWith(
            images: const [
              AnnotatedImage(
                id: 17,
                sourcePath: r'C:\images\bread.jpg',
                displayName: 'bread.jpg',
                importedFrom: r'C:\images',
                width: 640,
                height: 480,
                status: ImageStatus.confirmed,
              ),
            ],
          ),
        );
        await controller.saveProject();
        final transferPath = p.join(tempDir.path, 'transfer', 'demo.bbox.json');

        await controller.saveProjectSnapshot(transferPath);

        expect(controller.project!.projectFilePath, internalPath);
        expect(await File(transferPath).exists(), isTrue);
        expect(
          (await ProjectSnapshotService().readSnapshot(
            transferPath,
          )).images.single.status,
          ImageStatus.confirmed,
        );
      },
    );

    test('imports a snapshot into a new managed library project', () async {
      await controller.createLibraryProject('Portable');
      controller.loadProject(
        controller.project!.copyWith(
          images: const [
            AnnotatedImage(
              id: 17,
              sourcePath: r'C:\images\bread.jpg',
              displayName: 'bread.jpg',
              importedFrom: r'C:\images',
              width: 640,
              height: 480,
              status: ImageStatus.confirmed,
            ),
          ],
        ),
      );
      await controller.saveProject();
      final transferPath = p.join(tempDir.path, 'portable.bbox.json');
      await controller.saveProjectSnapshot(transferPath);
      final receivingLibrary = ProjectLibrary(
        rootPath: p.join(tempDir.path, 'receiving-library'),
        clock: () => DateTime.utc(2026, 7, 8, 5, 30),
        idGenerator: (name, timestamp) => 'received-project',
      );
      final receivingController = AppController(
        projectLibrary: receivingLibrary,
      );

      await receivingController.importProjectSnapshot(transferPath);

      expect(
        receivingController.project!.projectFilePath,
        startsWith(receivingLibrary.projectsRootPath),
      );
      expect(
        receivingController.project!.images.single.status,
        ImageStatus.confirmed,
      );
      expect(receivingController.project!.images.single.id, 17);
      expect(
        receivingController.projectLibraryEntries.single.id,
        'received-project',
      );
      expect(
        receivingController.sourceAvailability[17],
        SourceAvailability.missing,
      );
    });

    test('relink autosaves the replacement path through the library', () async {
      final source = File(p.join(tempDir.path, 'replacement', 'bread.png'));
      await source.parent.create(recursive: true);
      await source.writeAsBytes(img.encodePng(img.Image(width: 1, height: 1)));
      await controller.createLibraryProject('Relink Autosave');
      controller.loadProject(
        controller.project!.copyWith(
          images: [
            AnnotatedImage(
              id: 1,
              sourcePath: p.join(tempDir.path, 'missing', 'bread.png'),
              displayName: 'bread.png',
              width: 1,
              height: 1,
              status: ImageStatus.confirmed,
            ),
          ],
        ),
      );
      await controller.saveProject();
      await controller.refreshSourceAvailability();

      final result = await controller.relinkSourceFiles([source.path]);
      await controller.saveProjectSnapshot(
        p.join(tempDir.path, 'flush-autosave.bbox.json'),
      );

      expect(result.matchedCount, 1);
      final stored = await ProjectStore.load(
        controller.project!.projectFilePath!,
      );
      expect(stored.images.single.sourcePath, source.absolute.path);
      expect(stored.images.single.importedFrom, source.parent.path);
      expect(controller.projectLibraryEntries.single.confirmedImageCount, 1);
    });

    test('autosaves immutable snapshots before activating an import', () async {
      final saveStarted = [Completer<void>(), Completer<void>()];
      final saveGates = [Completer<void>(), Completer<void>()];
      final savedSnapshots = <AnnotationProject>[];
      var saveIndex = 0;
      final serializedController = AppController(
        projectLibrary: library,
        projectSaver: (project, path) async {
          final index = saveIndex++;
          savedSnapshots.add(project);
          saveStarted[index].complete();
          await saveGates[index].future;
          return ProjectStore.save(project, path);
        },
      );
      await serializedController.createLibraryProject('Old Project');
      final transferPath = p.join(tempDir.path, 'incoming.bbox.json');
      await ProjectSnapshotService().writeSnapshot(
        AnnotationProject.empty(
          name: 'Imported Project',
        ).copyWith(status: ProjectStatus.ready),
        transferPath,
      );

      serializedController.addLabel('First Pending Label', 0xff112233);
      serializedController.addLabel('Second Pending Label', 0xff223344);
      final import = serializedController.importProjectSnapshot(transferPath);

      await saveStarted[0].future;
      expect(
        savedSnapshots[0].labels.any(
          (label) => label.name == 'First Pending Label',
        ),
        isTrue,
      );
      expect(
        savedSnapshots[0].labels.any(
          (label) => label.name == 'Second Pending Label',
        ),
        isFalse,
      );
      expect(serializedController.project!.name, 'Old Project');
      saveGates[0].complete();

      await saveStarted[1].future;
      expect(
        savedSnapshots[1].labels.any(
          (label) => label.name == 'Second Pending Label',
        ),
        isTrue,
      );
      expect(serializedController.project!.name, 'Old Project');
      saveGates[1].complete();
      await import;

      expect(serializedController.project!.name, 'Imported Project');
      expect(
        serializedController.project!.labels.any(
          (label) => label.name == 'First Pending Label',
        ),
        isFalse,
      );
    });

    test(
      'dispose during snapshot save does not notify after disposal',
      () async {
        final snapshotService = _BlockingWriteSnapshotService();
        final disposableController = AppController(
          projectLibrary: library,
          projectSnapshotService: snapshotService,
          autoBoxRuntime: FakeAutoBoxRuntime(),
        )..createProject('Disposable Save');

        final save = disposableController.saveProjectSnapshot(
          p.join(tempDir.path, 'blocked-save.bbox.json'),
        );
        await snapshotService.started.future;
        disposableController.dispose();
        snapshotService.release.complete();

        await expectLater(save, completes);
      },
    );

    test(
      'project switch during snapshot save suppresses stale messages',
      () async {
        final snapshotService = _BlockingWriteSnapshotService();
        final switchingController = AppController(
          projectLibrary: library,
          projectSnapshotService: snapshotService,
        )..createProject('First Project');

        final save = switchingController.saveProjectSnapshot(
          p.join(tempDir.path, 'switch-save.bbox.json'),
        );
        await snapshotService.started.future;
        switchingController.loadProject(
          AnnotationProject.empty(name: 'Second Project'),
        );
        snapshotService.release.complete();
        await save;

        expect(switchingController.project!.name, 'Second Project');
        expect(switchingController.lastUserMessage, isNull);
        expect(switchingController.lastError, isNull);
      },
    );

    test(
      'dispose during snapshot import stops before library mutation',
      () async {
        final snapshotService = _BlockingReadSnapshotService();
        final disposableController = AppController(
          projectLibrary: library,
          projectSnapshotService: snapshotService,
          autoBoxRuntime: FakeAutoBoxRuntime(),
        );

        final import = disposableController.importProjectSnapshot(
          'blocked.json',
        );
        await snapshotService.started.future;
        disposableController.dispose();
        snapshotService.result.complete(
          AnnotationProject.empty(name: 'Must Not Import'),
        );

        await expectLater(import, completes);
        expect(await library.listProjects(), isEmpty);
      },
    );

    test(
      'successful import reports availability refresh failure as warning',
      () async {
        final transferPath = p.join(tempDir.path, 'warning-import.bbox.json');
        await ProjectSnapshotService().writeSnapshot(
          AnnotationProject.empty(name: 'Imported With Warning').copyWith(
            images: const [
              AnnotatedImage(
                id: 1,
                sourcePath: 'missing.png',
                displayName: 'missing.png',
                width: 10,
                height: 10,
                status: ImageStatus.confirmed,
              ),
            ],
          ),
          transferPath,
        );
        final warningController = AppController(
          projectLibrary: library,
          sourceRelinkService: _FailingAvailabilityService(),
        );

        await warningController.importProjectSnapshot(transferPath);

        expect(warningController.project!.name, 'Imported With Warning');
        expect(warningController.projectLibraryEntries, isNotEmpty);
        expect(warningController.lastUserMessage, contains('imported'));
        expect(warningController.lastUserMessage, contains('availability'));
        expect(
          warningController.lastUserMessage,
          isNot(contains('Could not import')),
        );
      },
    );

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

class _BlockingWriteSnapshotService extends ProjectSnapshotService {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> writeSnapshot(
    AnnotationProject project,
    String targetPath,
  ) async {
    started.complete();
    await release.future;
  }
}

class _BlockingReadSnapshotService extends ProjectSnapshotService {
  final started = Completer<void>();
  final result = Completer<AnnotationProject>();

  @override
  Future<AnnotationProject> readSnapshot(String path) {
    started.complete();
    return result.future;
  }
}

class _FailingAvailabilityService extends SourceRelinkService {
  @override
  Future<Map<int, SourceAvailability>> inspectSources(
    Iterable<AnnotatedImage> images,
  ) {
    throw FileSystemException('Injected availability failure');
  }
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
