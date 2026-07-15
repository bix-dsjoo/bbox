import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/project/project_library.dart';
import 'package:bbox_labeler/project/project_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/memory_project_library.dart';

void main() {
  group('ProjectLibrary', () {
    late Directory tempDir;
    late DateTime now;
    late ProjectLibrary library;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('bbox_project_library');
      now = DateTime.utc(2026, 7, 7, 5, 30, 12);
      library = ProjectLibrary(
        rootPath: tempDir.path,
        clock: () => now,
        idGenerator: (name, timestamp) => 'fixed-project',
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('creates a project inside the internal projects folder', () async {
      final project = await library.createProject('Demo Project');

      final expectedPath = p.join(
        tempDir.path,
        'projects',
        'fixed-project',
        'project.bbox.json',
      );
      expect(project.name, 'Demo Project');
      expect(project.projectFilePath, expectedPath);
      expect(project.status, ProjectStatus.ready);
      expect(await File(expectedPath).exists(), isTrue);

      final entries = await library.listProjects();
      expect(entries, hasLength(1));
      expect(entries.single.id, 'fixed-project');
      expect(entries.single.name, 'Demo Project');
      expect(entries.single.projectFilePath, expectedPath);
      expect(entries.single.imageCount, 0);
      expect(entries.single.confirmedImageCount, 0);
      expect(entries.single.errorImageCount, 0);
    });

    test(
      'imports a project into a new internal path without changing data',
      () async {
        final source = _externalProject(tempDir.path);

        final imported = await library.importProject(source);

        final expectedPath = p.join(
          tempDir.path,
          'projects',
          'fixed-project',
          'project.bbox.json',
        );
        expect(imported.projectFilePath, expectedPath);
        expect(imported.status, ProjectStatus.ready);
        expect(imported.labels.single.id, 23);
        expect(imported.images.single.id, 41);
        expect(
          imported.images.single.sourcePath,
          p.join(tempDir.path, 'outside', 'bread.jpg'),
        );
        expect(
          imported.images.single.importedFrom,
          p.join(tempDir.path, 'outside'),
        );
        expect(imported.images.single.boxes.single.id, 'annotation-71');
        expect(imported.images.single.boxes.single.labelId, 23);
        expect(
          source.projectFilePath,
          p.join(tempDir.path, 'outside-project.bbox.json'),
        );
        expect((await library.listProjects()).single.id, 'fixed-project');
      },
    );

    test('memory library imports into a unique internal path', () async {
      final memory = MemoryProjectLibrary(
        rootPath: p.join(tempDir.path, 'memory-library'),
        fixedId: 'memory-import',
      );
      final source = _externalProject(tempDir.path);

      final first = await memory.importProject(source);
      final second = await memory.importProject(source);

      expect(
        first.projectFilePath,
        p.join(memory.projectsRootPath, 'memory-import', 'project.bbox.json'),
      );
      expect(
        second.projectFilePath,
        p.join(memory.projectsRootPath, 'memory-import-2', 'project.bbox.json'),
      );
      expect(first.images.single.id, 41);
      expect(first.images.single.boxes.single.id, 'annotation-71');
      expect(await memory.listProjects(), hasLength(2));
    });

    test(
      'memory import does not overwrite a later id after deletion',
      () async {
        final memory = MemoryProjectLibrary(
          rootPath: p.join(tempDir.path, 'memory-library'),
          fixedId: 'memory-import',
        );
        final source = _externalProject(tempDir.path);
        await memory.importProject(source.copyWith(name: 'First'));
        await memory.importProject(source.copyWith(name: 'Second'));
        await memory.importProject(source.copyWith(name: 'Third'));
        await memory.deleteProject('memory-import-2');

        final imported = await memory.importProject(
          source.copyWith(name: 'Replacement'),
        );

        expect(
          p.basename(p.dirname(imported.projectFilePath!)),
          'memory-import-2',
        );
        expect((await memory.openProject('memory-import-3')).name, 'Third');
        expect(await memory.listProjects(), hasLength(3));
      },
    );

    test('lists projects sorted by updatedAt descending', () async {
      final first = ProjectLibrary(
        rootPath: tempDir.path,
        clock: () => DateTime.utc(2026, 7, 7, 5),
        idGenerator: (name, timestamp) => 'first',
      );
      final second = ProjectLibrary(
        rootPath: tempDir.path,
        clock: () => DateTime.utc(2026, 7, 7, 6),
        idGenerator: (name, timestamp) => 'second',
      );

      await first.createProject('First');
      await second.createProject('Second');

      final entries = await library.listProjects();
      expect(entries.map((entry) => entry.id), ['second', 'first']);
    });

    test('opens and renames a project without changing the id', () async {
      await library.createProject('Before');

      final renamed = await library.renameProject('fixed-project', 'After');
      final opened = await library.openProject('fixed-project');
      final entries = await library.listProjects();

      expect(renamed.name, 'After');
      expect(opened.name, 'After');
      expect(entries.single.id, 'fixed-project');
      expect(entries.single.name, 'After');
      expect(p.basename(p.dirname(opened.projectFilePath!)), 'fixed-project');
    });

    test('refreshes index metadata from saved project state', () async {
      final created = await library.createProject('Dataset');
      final updated = created.copyWith(
        images: const [
          AnnotatedImage(
            id: 1,
            sourcePath: 'C:\\images\\a.jpg',
            displayName: 'a.jpg',
            width: 100,
            height: 80,
            status: ImageStatus.confirmed,
          ),
          AnnotatedImage(
            id: 2,
            sourcePath: 'C:\\images\\broken.jpg',
            displayName: 'broken.jpg',
            width: 0,
            height: 0,
            status: ImageStatus.error,
            errorMessage: 'decode failed',
          ),
        ],
      );
      await ProjectStore.save(updated, updated.projectFilePath!);

      await library.refreshEntry(updated);

      final entry = (await library.listProjects()).single;
      expect(entry.imageCount, 2);
      expect(entry.confirmedImageCount, 1);
      expect(entry.errorImageCount, 1);
    });

    test(
      'rebuilds index from project directories when index is corrupted',
      () async {
        await library.createProject('Recoverable');
        final indexFile = File(p.join(tempDir.path, 'projects', 'index.json'));
        await indexFile.writeAsString('{broken', encoding: utf8);

        final entries = await library.listProjects();

        expect(entries, hasLength(1));
        expect(entries.single.name, 'Recoverable');
        final raw =
            jsonDecode(await indexFile.readAsString(encoding: utf8))
                as Map<String, Object?>;
        expect(raw['schemaVersion'], ProjectLibrary.currentIndexSchemaVersion);
      },
    );

    test('deletes only the internal project directory', () async {
      final imageDir = Directory(p.join(tempDir.path, 'external-images'));
      await imageDir.create();
      final imageFile = File(p.join(imageDir.path, 'a.jpg'));
      await imageFile.writeAsString('source image bytes');

      final created = await library.createProject('Delete Me');
      final projectWithImages = created.copyWith(
        images: [
          AnnotatedImage(
            id: 1,
            sourcePath: p.join(imageDir.path, 'a.jpg'),
            displayName: 'a.jpg',
            width: 100,
            height: 80,
            status: ImageStatus.confirmed,
          ),
        ],
      );
      await ProjectStore.save(projectWithImages, created.projectFilePath!);
      await library.refreshEntry(projectWithImages);

      await library.deleteProject('fixed-project');

      expect(await File(created.projectFilePath!).exists(), isFalse);
      expect(await imageFile.exists(), isTrue);
      expect(await library.listProjects(), isEmpty);
    });

    test('resolves AppData root from the provided environment', () {
      final appDataRoot = p.join(tempDir.path, 'Roaming');

      final appDataLibrary = ProjectLibrary.appData(
        environment: {'APPDATA': appDataRoot},
      );

      expect(appDataLibrary.rootPath, p.join(appDataRoot, 'BBoxLabeler'));
      expect(
        appDataLibrary.projectsRootPath,
        p.join(appDataRoot, 'BBoxLabeler', 'projects'),
      );
    });

    test(
      'serializes a barrier-delayed create with a concurrent import',
      () async {
        final createEntered = Completer<void>();
        final releaseCreate = Completer<void>();
        final enteredOperations = <String>[];
        final serialized = ProjectLibrary(
          rootPath: tempDir.path,
          clock: () => now,
          idGenerator: (name, timestamp) => 'fixed-project',
          beforeOperation: (operation) async {
            enteredOperations.add(operation);
            if (operation == ProjectLibraryOperation.create) {
              createEntered.complete();
              await releaseCreate.future;
            }
          },
        );

        final create = serialized.createProject('Created');
        await createEntered.future;
        final import = serialized.importProject(_externalProject(tempDir.path));
        await Future<void>.delayed(Duration.zero);

        expect(enteredOperations, [ProjectLibraryOperation.create]);
        releaseCreate.complete();
        final results = await Future.wait([create, import]);

        expect(
          results.map(
            (project) => p.basename(p.dirname(project.projectFilePath!)),
          ),
          ['fixed-project', 'fixed-project-2'],
        );
        expect(
          (await serialized.listProjects()).map((entry) => entry.id).toSet(),
          {'fixed-project', 'fixed-project-2'},
        );
        expect(await _projectDirectoryNames(serialized), {
          'fixed-project',
          'fixed-project-2',
        });
        expect(await _indexProjectIds(serialized), {
          'fixed-project',
          'fixed-project-2',
        });
      },
    );

    test(
      'serializes import then rename and delete with exact final state',
      () async {
        await library.createProject('Existing');
        final importEntered = Completer<void>();
        final releaseImport = Completer<void>();
        final enteredOperations = <String>[];
        final serialized = ProjectLibrary(
          rootPath: tempDir.path,
          clock: () => now,
          idGenerator: (name, timestamp) => 'fixed-project',
          beforeOperation: (operation) async {
            enteredOperations.add(operation);
            if (operation == ProjectLibraryOperation.importProject) {
              importEntered.complete();
              await releaseImport.future;
            }
          },
        );

        final import = serialized.importProject(_externalProject(tempDir.path));
        await importEntered.future;
        final rename = serialized.renameProject('fixed-project', 'Renamed');
        final delete = serialized.deleteProject('fixed-project');
        await Future<void>.delayed(Duration.zero);

        expect(enteredOperations, [ProjectLibraryOperation.importProject]);
        releaseImport.complete();
        final imported = await import;
        await rename;
        await delete;

        final importedId = p.basename(p.dirname(imported.projectFilePath!));
        expect(importedId, 'fixed-project-2');
        expect((await serialized.listProjects()).map((entry) => entry.id), [
          'fixed-project-2',
        ]);
        expect(await _projectDirectoryNames(serialized), {'fixed-project-2'});
        expect(await _indexProjectIds(serialized), {'fixed-project-2'});
      },
    );

    test('create rolls back its directory when index write fails', () async {
      var failIndexWrite = true;
      final rollbackLibrary = ProjectLibrary(
        rootPath: tempDir.path,
        clock: () => now,
        idGenerator: (name, timestamp) => 'rollback-create',
        beforeIndexWrite: () async {
          if (failIndexWrite) {
            throw FileSystemException('injected index failure');
          }
        },
      );

      await expectLater(
        rollbackLibrary.createProject('Failed Create'),
        throwsA(isA<FileSystemException>()),
      );

      expect(await _projectDirectoryNames(rollbackLibrary), isEmpty);
      expect(await File(rollbackLibrary.indexFilePath).exists(), isFalse);

      failIndexWrite = false;
      final recovered = await rollbackLibrary.createProject('Recovered Create');
      expect(
        p.basename(p.dirname(recovered.projectFilePath!)),
        'rollback-create',
      );
      expect(await _indexProjectIds(rollbackLibrary), {'rollback-create'});
    });

    test('import rolls back its directory when index write fails', () async {
      var failIndexWrite = true;
      final rollbackLibrary = ProjectLibrary(
        rootPath: tempDir.path,
        clock: () => now,
        idGenerator: (name, timestamp) => 'rollback-import',
        beforeIndexWrite: () async {
          if (failIndexWrite) {
            throw FileSystemException('injected index failure');
          }
        },
      );

      await expectLater(
        rollbackLibrary.importProject(_externalProject(tempDir.path)),
        throwsA(isA<FileSystemException>()),
      );

      expect(await _projectDirectoryNames(rollbackLibrary), isEmpty);
      expect(await File(rollbackLibrary.indexFilePath).exists(), isFalse);

      failIndexWrite = false;
      final recovered = await rollbackLibrary.importProject(
        _externalProject(tempDir.path),
      );
      expect(
        p.basename(p.dirname(recovered.projectFilePath!)),
        'rollback-import',
      );
      expect(await _indexProjectIds(rollbackLibrary), {'rollback-import'});
    });

    test(
      'rename restores the original project JSON when index write fails',
      () async {
        final created = await library.createProject('Original Name');
        final projectFile = File(created.projectFilePath!);
        final originalJson = await projectFile.readAsString();
        var failIndexWrite = true;
        final rollbackLibrary = ProjectLibrary(
          rootPath: tempDir.path,
          clock: () => now,
          idGenerator: (name, timestamp) => 'fixed-project',
          beforeIndexWrite: () async {
            if (failIndexWrite) {
              throw FileSystemException('injected index failure');
            }
          },
        );

        await expectLater(
          rollbackLibrary.renameProject('fixed-project', 'Must Roll Back'),
          throwsA(isA<FileSystemException>()),
        );

        expect(await projectFile.readAsString(), originalJson);
        expect(
          (await rollbackLibrary.openProject('fixed-project')).name,
          'Original Name',
        );
        expect(
          (await rollbackLibrary.listProjects()).single.name,
          'Original Name',
        );

        failIndexWrite = false;
        final recovered = await rollbackLibrary.renameProject(
          'fixed-project',
          'Recovered Rename',
        );
        expect(recovered.name, 'Recovered Rename');
      },
    );

    test('delete restores its directory when index write fails', () async {
      final created = await library.createProject('Delete Rollback');
      final projectDirectory = Directory(p.dirname(created.projectFilePath!));
      var failIndexWrite = true;
      final rollbackLibrary = ProjectLibrary(
        rootPath: tempDir.path,
        clock: () => now,
        idGenerator: (name, timestamp) => 'fixed-project',
        beforeIndexWrite: () async {
          if (failIndexWrite) {
            throw FileSystemException('injected index failure');
          }
        },
      );

      await expectLater(
        rollbackLibrary.deleteProject('fixed-project'),
        throwsA(isA<FileSystemException>()),
      );

      expect(await projectDirectory.exists(), isTrue);
      expect(
        (await rollbackLibrary.openProject('fixed-project')).name,
        'Delete Rollback',
      );
      expect(await _tombstoneNames(rollbackLibrary), isEmpty);

      failIndexWrite = false;
      await rollbackLibrary.deleteProject('fixed-project');
      expect(await projectDirectory.exists(), isFalse);
      expect(await rollbackLibrary.listProjects(), isEmpty);
      expect(await _tombstoneNames(rollbackLibrary), isEmpty);
    });

    test(
      'create stays committed when promoted index backup cleanup fails',
      () async {
        await library.createProject('Seed');
        var blockCleanup = true;
        final cleanupLibrary = ProjectLibrary(
          rootPath: tempDir.path,
          clock: () => now,
          idGenerator: (name, timestamp) => 'fixed-project',
          deleteIndexBackup: (backup) async {
            if (blockCleanup) {
              throw FileSystemException('injected backup cleanup failure');
            }
            await backup.delete();
          },
        );

        final created = await cleanupLibrary.createProject('Committed Create');
        expect(
          p.basename(p.dirname(created.projectFilePath!)),
          'fixed-project-2',
        );
        expect(await _indexProjectIds(cleanupLibrary), {
          'fixed-project',
          'fixed-project-2',
        });
        expect(await _indexBackupNames(cleanupLibrary), hasLength(1));

        blockCleanup = false;
        await cleanupLibrary.createProject('Queued Create');
        expect(await _indexProjectIds(cleanupLibrary), {
          'fixed-project',
          'fixed-project-2',
          'fixed-project-3',
        });
        expect(await _indexBackupNames(cleanupLibrary), isEmpty);
      },
    );

    test(
      'import stays committed when promoted index backup cleanup fails',
      () async {
        await library.createProject('Seed');
        var blockCleanup = true;
        final cleanupLibrary = ProjectLibrary(
          rootPath: tempDir.path,
          clock: () => now,
          idGenerator: (name, timestamp) => 'fixed-project',
          deleteIndexBackup: (backup) async {
            if (blockCleanup) {
              throw FileSystemException('injected backup cleanup failure');
            }
            await backup.delete();
          },
        );

        final imported = await cleanupLibrary.importProject(
          _externalProject(tempDir.path),
        );
        expect(
          p.basename(p.dirname(imported.projectFilePath!)),
          'fixed-project-2',
        );
        expect(await _indexProjectIds(cleanupLibrary), {
          'fixed-project',
          'fixed-project-2',
        });
        expect(await _indexBackupNames(cleanupLibrary), hasLength(1));

        blockCleanup = false;
        await cleanupLibrary.renameProject('fixed-project-2', 'Queued Rename');
        expect(
          (await cleanupLibrary.openProject('fixed-project-2')).name,
          'Queued Rename',
        );
        expect(await _indexBackupNames(cleanupLibrary), isEmpty);
      },
    );

    test(
      'rename stays committed when promoted index backup cleanup fails',
      () async {
        await library.createProject('Original');
        var blockCleanup = true;
        final cleanupLibrary = ProjectLibrary(
          rootPath: tempDir.path,
          clock: () => now,
          idGenerator: (name, timestamp) => 'fixed-project',
          deleteIndexBackup: (backup) async {
            if (blockCleanup) {
              throw FileSystemException('injected backup cleanup failure');
            }
            await backup.delete();
          },
        );

        final renamed = await cleanupLibrary.renameProject(
          'fixed-project',
          'Committed Rename',
        );
        expect(renamed.name, 'Committed Rename');
        expect(
          (await cleanupLibrary.listProjects()).single.name,
          'Committed Rename',
        );
        expect(await _indexBackupNames(cleanupLibrary), hasLength(1));

        blockCleanup = false;
        await cleanupLibrary.renameProject('fixed-project', 'Queued Rename');
        expect(
          (await cleanupLibrary.openProject('fixed-project')).name,
          'Queued Rename',
        );
        expect(await _indexBackupNames(cleanupLibrary), isEmpty);
      },
    );

    test(
      'delete stays committed when promoted index backup cleanup fails',
      () async {
        final created = await library.createProject('Delete Me');
        final directory = Directory(p.dirname(created.projectFilePath!));
        var blockCleanup = true;
        final cleanupLibrary = ProjectLibrary(
          rootPath: tempDir.path,
          clock: () => now,
          idGenerator: (name, timestamp) => 'fixed-project',
          deleteIndexBackup: (backup) async {
            if (blockCleanup) {
              throw FileSystemException('injected backup cleanup failure');
            }
            await backup.delete();
          },
        );

        await cleanupLibrary.deleteProject('fixed-project');
        expect(await directory.exists(), isFalse);
        expect(await cleanupLibrary.listProjects(), isEmpty);
        expect(await _indexBackupNames(cleanupLibrary), hasLength(1));

        blockCleanup = false;
        await cleanupLibrary.createProject('Queued Create');
        expect(await _indexProjectIds(cleanupLibrary), {'fixed-project'});
        expect(await _indexBackupNames(cleanupLibrary), isEmpty);
      },
    );

    test(
      'failed tombstone cleanup never resurrects a committed delete',
      () async {
        final created = await library.createProject('Delete Me');
        final directory = Directory(p.dirname(created.projectFilePath!));
        final cleanupLibrary = ProjectLibrary(
          rootPath: tempDir.path,
          clock: () => now,
          idGenerator: (name, timestamp) => 'fixed-project',
          deleteTombstone: (tombstone) async {
            throw FileSystemException('injected tombstone cleanup failure');
          },
        );

        await cleanupLibrary.deleteProject('fixed-project');
        expect(await directory.exists(), isFalse);
        expect(await _tombstoneNames(cleanupLibrary), hasLength(1));
        expect(await cleanupLibrary.rebuildIndex(), isEmpty);
        expect(await cleanupLibrary.listProjects(), isEmpty);

        final queued = await cleanupLibrary.createProject('Queued Create');
        expect(p.basename(p.dirname(queued.projectFilePath!)), 'fixed-project');
        expect(await _indexProjectIds(cleanupLibrary), {'fixed-project'});
      },
    );

    test(
      'rejects cross-id index paths before open rename refresh or delete',
      () async {
        var nextId = 0;
        final ownershipLibrary = ProjectLibrary(
          rootPath: tempDir.path,
          clock: () => now,
          idGenerator: (name, timestamp) => 'project-${++nextId}',
        );
        final projectA = await ownershipLibrary.createProject('Project A');
        final projectB = await ownershipLibrary.createProject('Project B');
        final fileA = File(projectA.projectFilePath!);
        final fileB = File(projectB.projectFilePath!);
        final bytesA = await fileA.readAsBytes();
        final bytesB = await fileB.readAsBytes();
        final indexFile = File(ownershipLibrary.indexFilePath);
        final index =
            jsonDecode(await indexFile.readAsString()) as Map<String, Object?>;
        final projects = index['projects']! as List<Object?>;
        final entryA = projects.cast<Map<String, Object?>>().singleWhere(
          (entry) => entry['id'] == 'project-1',
        );
        entryA['projectFilePath'] = projectB.projectFilePath;
        await indexFile.writeAsString(jsonEncode(index), flush: true);
        final corruptIndexBytes = await indexFile.readAsBytes();

        await expectLater(
          ownershipLibrary.openProject('project-1'),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          ownershipLibrary.renameProject('project-1', 'Do Not Rename'),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          ownershipLibrary.refreshEntry(projectB),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          ownershipLibrary.deleteProject('project-1'),
          throwsA(isA<StateError>()),
        );

        expect(await fileA.readAsBytes(), bytesA);
        expect(await fileB.readAsBytes(), bytesB);
        expect(await indexFile.readAsBytes(), corruptIndexBytes);
        expect(await Directory(p.dirname(fileA.path)).exists(), isTrue);
        expect(await Directory(p.dirname(fileB.path)).exists(), isTrue);
      },
    );
  });
}

Future<Set<String>> _projectDirectoryNames(ProjectLibrary library) async {
  final root = Directory(library.projectsRootPath);
  return {
    await for (final entity in root.list(followLinks: false))
      if (entity is Directory) p.basename(entity.path),
  };
}

Future<Set<String>> _indexProjectIds(ProjectLibrary library) async {
  final raw =
      jsonDecode(await File(library.indexFilePath).readAsString())
          as Map<String, Object?>;
  return {
    for (final entry in raw['projects']! as List<Object?>)
      (entry as Map<String, Object?>)['id']! as String,
  };
}

Future<Set<String>> _tombstoneNames(ProjectLibrary library) async {
  final root = Directory(library.projectsRootPath);
  if (!await root.exists()) return const {};
  return {
    await for (final entity in root.list(followLinks: false))
      if (p.basename(entity.path).contains('.deleting-'))
        p.basename(entity.path),
  };
}

Future<Set<String>> _indexBackupNames(ProjectLibrary library) async {
  final root = Directory(library.projectsRootPath);
  if (!await root.exists()) return const {};
  final prefix = '${p.basename(library.indexFilePath)}.bak-';
  return {
    await for (final entity in root.list(followLinks: false))
      if (p.basename(entity.path).startsWith(prefix)) p.basename(entity.path),
  };
}

AnnotationProject _externalProject(String rootPath) {
  final sourceDirectory = p.join(rootPath, 'outside');
  return AnnotationProject(
    schemaVersion: ProjectStore.currentSchemaVersion,
    name: 'Imported Dataset',
    projectFilePath: p.join(rootPath, 'outside-project.bbox.json'),
    status: ProjectStatus.dirty,
    labels: const [LabelClass(id: 23, name: 'Bread', color: 0xffff9800)],
    images: [
      AnnotatedImage(
        id: 41,
        sourcePath: p.join(sourceDirectory, 'bread.jpg'),
        displayName: 'bread.jpg',
        importedFrom: sourceDirectory,
        width: 100,
        height: 80,
        status: ImageStatus.confirmed,
        boxes: const [
          BoundingBox(
            id: 'annotation-71',
            x: 1,
            y: 2,
            width: 30,
            height: 40,
            status: BoxStatus.labeled,
            labelId: 23,
          ),
        ],
      ),
    ],
  );
}
