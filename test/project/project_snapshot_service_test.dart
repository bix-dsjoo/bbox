import 'dart:convert';
import 'dart:io';

import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/project/project_library.dart';
import 'package:bbox_labeler/project/project_snapshot_service.dart';
import 'package:bbox_labeler/project/project_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('ProjectSnapshotService', () {
    late Directory tempDir;
    late ProjectSnapshotService service;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('bbox_snapshot_test');
      service = ProjectSnapshotService(
        clock: () => DateTime.utc(2026, 7, 15, 9, 30),
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'writes a transferable snapshot without mutating the source',
      () async {
        final internalPath = p.join(
          tempDir.path,
          'internal',
          'project.bbox.json',
        );
        final transferPath = p.join(tempDir.path, 'transfer', 'demo.bbox.json');
        final original = _project(projectFilePath: internalPath);

        await service.writeSnapshot(original, transferPath);

        final raw =
            jsonDecode(await File(transferPath).readAsString())
                as Map<String, Object?>;
        expect(raw['projectFilePath'], isNull);
        expect(original.projectFilePath, internalPath);

        final restored = await service.readSnapshot(transferPath);
        expect(restored.projectFilePath, isNull);
        expect(restored.status, ProjectStatus.ready);
        expect(restored.images.single.status, ImageStatus.confirmed);
        expect(restored.images.single.sourcePath, r'C:\images\bread.jpg');
        expect(restored.images.single.importedFrom, r'C:\images');
        expect(restored.images.single.boxes.single.labelId, 1);
        expect(
          restored.images.single.boxes.single.automation?.pipelineVersion,
          'pipeline-v1',
        );
      },
    );

    test(
      'atomically replaces an existing snapshot and removes artifacts',
      () async {
        final transferPath = p.join(tempDir.path, 'transfer.bbox.json');
        await File(transferPath).writeAsString('previous contents');

        await service.writeSnapshot(
          _project(projectFilePath: p.join(tempDir.path, 'internal.json')),
          transferPath,
        );

        expect(
          (await service.readSnapshot(transferPath)).name,
          'Transfer Demo',
        );
        expect(
          await _snapshotArtifacts(tempDir, 'transfer.bbox.json'),
          isEmpty,
        );
      },
    );

    test(
      'restores the prior target when replacement fails after backup',
      () async {
        final transferPath = p.join(tempDir.path, 'rollback.bbox.json');
        await File(transferPath).writeAsString('previous contents');
        var oldTargetMoved = false;
        var replacementFailureInjected = false;
        final failingService = ProjectSnapshotService.withFileRenamerForTesting(
          clock: () => DateTime.utc(2026, 7, 15, 9, 30),
          renameFile: (source, newPath) async {
            if (source.path == transferPath) {
              final renamed = await source.rename(newPath);
              oldTargetMoved = true;
              return renamed;
            }
            if (source.path.startsWith('$transferPath.tmp-') &&
                newPath == transferPath) {
              replacementFailureInjected = true;
              throw FileSystemException(
                'Injected replacement failure',
                source.path,
              );
            }
            return source.rename(newPath);
          },
        );

        await expectLater(
          failingService.writeSnapshot(
            _project(projectFilePath: p.join(tempDir.path, 'internal.json')),
            transferPath,
          ),
          throwsA(isA<FileSystemException>()),
        );

        expect(oldTargetMoved, isTrue);
        expect(replacementFailureInjected, isTrue);
        expect(await File(transferPath).readAsString(), 'previous contents');
        expect(
          await _snapshotArtifacts(tempDir, 'rollback.bbox.json'),
          isEmpty,
        );
      },
    );

    final invalidSnapshots =
        <
          ({
            String name,
            String message,
            AnnotationProject Function(AnnotationProject) mutate,
          })
        >[
          (
            name: 'duplicate label ids',
            message: 'duplicate label id',
            mutate: (project) => project.copyWith(
              labels: [project.labels.single, project.labels.single],
            ),
          ),
          (
            name: 'duplicate image ids',
            message: 'duplicate image id',
            mutate: (project) => project.copyWith(
              images: [project.images.single, project.images.single],
            ),
          ),
          (
            name: 'duplicate box ids in one image',
            message: 'duplicate box id in image 17',
            mutate: (project) => _withBoxes(project, [
              project.images.single.boxes.single,
              project.images.single.boxes.single,
            ]),
          ),
          (
            name: 'missing direct label reference',
            message: 'missing label 999 for box box-42',
            mutate: (project) => _withBox(
              project,
              project.images.single.boxes.single.copyWith(labelId: 999),
            ),
          ),
          (
            name: 'missing suggested label reference',
            message: 'missing suggested label for box box-42',
            mutate: (project) {
              final box = project.images.single.boxes.single;
              return _withBox(
                project,
                box.copyWith(
                  automation: box.automation!.copyWith(suggestedLabelId: 999),
                ),
              );
            },
          ),
          (
            name: 'missing candidate label reference',
            message: 'missing candidate label for box box-42',
            mutate: (project) {
              final box = project.images.single.boxes.single;
              return _withBox(
                project,
                box.copyWith(
                  automation: box.automation!.copyWith(
                    candidates: const [
                      LabelCandidate(labelId: 999, score: 0.5),
                    ],
                  ),
                ),
              );
            },
          ),
        ];

    for (final invalidSnapshot in invalidSnapshots) {
      test('rejects ${invalidSnapshot.name} before import', () async {
        final transferPath = p.join(
          tempDir.path,
          '${invalidSnapshot.name}.bbox.json',
        );
        final invalid = invalidSnapshot.mutate(_project(projectFilePath: null));
        await service.writeSnapshot(invalid, transferPath);
        final library = ProjectLibrary(
          rootPath: p.join(tempDir.path, 'library'),
          idGenerator: (name, timestamp) => 'imported-project',
        );

        await expectLater(
          service.readSnapshot(transferPath),
          throwsA(
            isA<InvalidProjectSnapshotException>().having(
              (error) => error.message,
              'message',
              invalidSnapshot.message,
            ),
          ),
        );

        expect(await Directory(library.projectsRootPath).exists(), isFalse);
        expect(await File(library.indexFilePath).exists(), isFalse);
      });
    }

    test('propagates unsupported project schema versions', () async {
      final transferPath = p.join(tempDir.path, 'future.bbox.json');
      await File(transferPath).writeAsString(
        jsonEncode({
          'schemaVersion': ProjectStore.currentSchemaVersion + 1,
          'name': 'Future project',
          'labels': <Object?>[],
          'images': <Object?>[],
        }),
      );

      await expectLater(
        service.readSnapshot(transferPath),
        throwsA(isA<UnsupportedProjectVersionException>()),
      );
    });
  });
}

Future<List<String>> _snapshotArtifacts(
  Directory directory,
  String targetName,
) async {
  return directory
      .list()
      .map((entity) => p.basename(entity.path))
      .where(
        (name) =>
            name.startsWith('$targetName.tmp-') ||
            name.startsWith('$targetName.bak-'),
      )
      .toList();
}

AnnotationProject _withBox(AnnotationProject project, BoundingBox box) {
  return _withBoxes(project, [box]);
}

AnnotationProject _withBoxes(
  AnnotationProject project,
  List<BoundingBox> boxes,
) {
  return project.copyWith(
    images: [project.images.single.copyWith(boxes: boxes)],
  );
}

AnnotationProject _project({required String? projectFilePath}) {
  return AnnotationProject(
    schemaVersion: ProjectStore.currentSchemaVersion,
    name: 'Transfer Demo',
    projectFilePath: projectFilePath,
    status: ProjectStatus.dirty,
    labels: const [
      LabelClass(id: 1, name: 'Bread', color: 0xffff9800, shortcut: '1'),
    ],
    images: const [
      AnnotatedImage(
        id: 17,
        sourcePath: r'C:\images\bread.jpg',
        displayName: 'bread.jpg',
        importedFrom: r'C:\images',
        width: 640,
        height: 480,
        status: ImageStatus.confirmed,
        boxes: [
          BoundingBox(
            id: 'box-42',
            x: 10,
            y: 20,
            width: 30,
            height: 40,
            status: BoxStatus.labeled,
            labelId: 1,
            labelSource: LabelSource.auto,
            automation: BoxAutomationMetadata(
              suggestedLabelId: 1,
              candidates: [LabelCandidate(labelId: 1, score: 0.97)],
              pipelineVersion: 'pipeline-v1',
              policyVersion: 'policy-v1',
              detectorSha256: 'detector-sha',
            ),
          ),
        ],
      ),
    ],
  );
}
