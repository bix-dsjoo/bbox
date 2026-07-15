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
            name: 'normalized duplicate label names',
            message: 'duplicate normalized label name "bread"',
            mutate: (project) => project.copyWith(
              labels: [
                project.labels.single,
                project.labels.single.copyWith(id: 2, name: '  BREAD  '),
              ],
            ),
          ),
          (
            name: 'duplicate non-null shortcuts',
            message: 'duplicate label shortcut "1"',
            mutate: (project) => project.copyWith(
              labels: [
                project.labels.single,
                project.labels.single.copyWith(
                  id: 2,
                  name: 'Pastry',
                  shortcut: ' 1 ',
                ),
              ],
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
            name: 'non-positive image width',
            message: 'image 17 width must be positive',
            mutate: (project) => project.copyWith(
              images: [project.images.single.copyWith(width: 0)],
            ),
          ),
          (
            name: 'non-positive image height',
            message: 'image 17 height must be positive',
            mutate: (project) => project.copyWith(
              images: [project.images.single.copyWith(height: -1)],
            ),
          ),
          (
            name: 'box with negative origin',
            message: 'box box-42 in image 17 must stay within image bounds',
            mutate: (project) => _withBox(
              project,
              project.images.single.boxes.single.copyWith(x: -1),
            ),
          ),
          (
            name: 'box with non-positive width',
            message: 'box box-42 in image 17 must have positive dimensions',
            mutate: (project) => _withBox(
              project,
              project.images.single.boxes.single.copyWith(width: 0),
            ),
          ),
          (
            name: 'box outside image bounds',
            message: 'box box-42 in image 17 must stay within image bounds',
            mutate: (project) => _withBox(
              project,
              project.images.single.boxes.single.copyWith(width: 1000),
            ),
          ),
          (
            name: 'proposal with assigned label',
            message:
                'proposal box box-42 must not have a label or label source',
            mutate: (project) => _withBox(
              project,
              project.images.single.boxes.single.copyWith(
                status: BoxStatus.proposal,
              ),
            ),
          ),
          (
            name: 'labeled box without label source',
            message: 'labeled box box-42 requires a label and label source',
            mutate: (project) => _withBox(
              project,
              project.images.single.boxes.single.copyWith(labelSource: null),
            ),
          ),
          (
            name: 'deleted box with inconsistent label source',
            message:
                'deleted box box-42 must keep label and label source together',
            mutate: (project) => _withBox(
              project,
              project.images.single.boxes.single.copyWith(
                status: BoxStatus.deleted,
                labelId: null,
              ),
            ),
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
          (
            name: 'duplicate candidate label ids',
            message: 'duplicate candidate label 1 for box box-42',
            mutate: (project) {
              final box = project.images.single.boxes.single;
              return _withBox(
                project,
                box.copyWith(
                  automation: box.automation!.copyWith(
                    candidates: const [
                      LabelCandidate(labelId: 1, score: 0.8),
                      LabelCandidate(labelId: 1, score: 0.7),
                    ],
                  ),
                ),
              );
            },
          ),
          (
            name: 'candidate score outside range',
            message:
                'candidate score for label 1 in box box-42 must be finite and between 0 and 1',
            mutate: (project) {
              final box = project.images.single.boxes.single;
              return _withBox(
                project,
                box.copyWith(
                  automation: box.automation!.copyWith(
                    candidates: const [LabelCandidate(labelId: 1, score: 1.01)],
                  ),
                ),
              );
            },
          ),
          (
            name: 'confidence outside range',
            message:
                'confidence for box box-42 must be finite and between 0 and 1',
            mutate: (project) => _withBox(
              project,
              project.images.single.boxes.single.copyWith(confidence: -0.1),
            ),
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
          () async {
            final decoded = await service.readSnapshot(transferPath);
            await library.importProject(decoded);
          }(),
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

    final malformedRawSnapshots =
        <({String name, void Function(Map<String, Object?>) mutate})>[
          (
            name: 'unknown project status',
            mutate: (raw) => raw['status'] = 'teleporting',
          ),
          (
            name: 'unknown image status',
            mutate: (raw) => _rawImage(raw)['status'] = 'archived',
          ),
          (
            name: 'unknown box status',
            mutate: (raw) => _rawBox(raw)['status'] = 'accepted',
          ),
          (
            name: 'unknown label source',
            mutate: (raw) => _rawBox(raw)['labelSource'] = 'robot',
          ),
          (
            name: 'malformed required project name',
            mutate: (raw) => raw['name'] = 42,
          ),
          (
            name: 'malformed required label id',
            mutate: (raw) => _rawLabel(raw)['id'] = '1',
          ),
          (
            name: 'malformed required image width',
            mutate: (raw) => _rawImage(raw)['width'] = '640',
          ),
          (
            name: 'malformed required box coordinate',
            mutate: (raw) => _rawBox(raw)['x'] = '10',
          ),
          (
            name: 'malformed required automation flag',
            mutate: (raw) => _rawAutomation(raw)['embeddingUsed'] = 'yes',
          ),
          (
            name: 'malformed required candidate score',
            mutate: (raw) => _rawCandidate(raw)['score'] = '0.9',
          ),
        ];

    for (final malformed in malformedRawSnapshots) {
      test('normalizes ${malformed.name} as an invalid snapshot', () async {
        final transferPath = p.join(
          tempDir.path,
          '${malformed.name}.bbox.json',
        );
        final raw = _project(projectFilePath: null).toJson();
        malformed.mutate(raw);
        await File(transferPath).writeAsString(jsonEncode(raw));
        final library = ProjectLibrary(
          rootPath: p.join(tempDir.path, 'raw-library'),
        );

        await expectLater(
          () async {
            final decoded = await service.readSnapshot(transferPath);
            await library.importProject(decoded);
          }(),
          throwsA(
            isA<InvalidProjectSnapshotException>().having(
              (error) => error.message,
              'message',
              isNot(isEmpty),
            ),
          ),
        );
        expect(await Directory(library.projectsRootPath).exists(), isFalse);
        expect(await File(library.indexFilePath).exists(), isFalse);
      });
    }

    test('normalizes unsupported project schema versions', () async {
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
        throwsA(isA<InvalidProjectSnapshotException>()),
      );
    });

    test('rejects non-finite JSON numeric values', () async {
      final transferPath = p.join(tempDir.path, 'infinite.bbox.json');
      final raw = jsonEncode(
        _project(projectFilePath: null).toJson(),
      ).replaceFirst('"x":10.0', '"x":1e999');
      await File(transferPath).writeAsString(raw);

      await expectLater(
        service.readSnapshot(transferPath),
        throwsA(isA<InvalidProjectSnapshotException>()),
      );
    });
  });
}

Map<String, Object?> _rawLabel(Map<String, Object?> raw) =>
    (raw['labels'] as List<Object?>).single as Map<String, Object?>;

Map<String, Object?> _rawImage(Map<String, Object?> raw) =>
    (raw['images'] as List<Object?>).single as Map<String, Object?>;

Map<String, Object?> _rawBox(Map<String, Object?> raw) =>
    (_rawImage(raw)['boxes'] as List<Object?>).single as Map<String, Object?>;

Map<String, Object?> _rawAutomation(Map<String, Object?> raw) =>
    _rawBox(raw)['automation'] as Map<String, Object?>;

Map<String, Object?> _rawCandidate(Map<String, Object?> raw) =>
    (_rawAutomation(raw)['candidates'] as List<Object?>).single
        as Map<String, Object?>;

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
