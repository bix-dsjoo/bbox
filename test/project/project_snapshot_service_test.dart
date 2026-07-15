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
        final artifactNames = await Directory(tempDir.path)
            .list()
            .map((entity) => p.basename(entity.path))
            .where(
              (name) =>
                  name.startsWith('transfer.bbox.json.tmp-') ||
                  name.startsWith('transfer.bbox.json.bak-'),
            )
            .toList();
        expect(artifactNames, isEmpty);
      },
    );

    test(
      'rejects a labeled box whose label is missing before import',
      () async {
        final transferPath = p.join(tempDir.path, 'invalid.bbox.json');
        final invalid = _project(projectFilePath: null).copyWith(
          images: [
            _project(projectFilePath: null).images.single.copyWith(
              boxes: [
                _project(
                  projectFilePath: null,
                ).images.single.boxes.single.copyWith(labelId: 999),
              ],
            ),
          ],
        );
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
              contains('missing label 999'),
            ),
          ),
        );

        expect(await Directory(library.projectsRootPath).exists(), isFalse);
        expect(await File(library.indexFilePath).exists(), isFalse);
      },
    );

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
