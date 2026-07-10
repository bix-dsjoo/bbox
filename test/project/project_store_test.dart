import 'dart:convert';
import 'dart:io';

import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/project/project_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProjectStore', () {
    test('saves and loads schema 2 project state with source paths', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'bbox_project_store_test',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final projectPath =
          '${tempDir.path}${Platform.pathSeparator}project.bbox.json';
      final project = AnnotationProject.empty(name: 'Demo Project').copyWith(
        status: ProjectStatus.ready,
        labels: const [
          LabelClass(id: 1, name: 'Bread', color: 0xff123456, shortcut: '1'),
          LabelClass(id: 2, name: 'Car', color: 0xff1976d2),
        ],
        images: const [
          AnnotatedImage(
            id: 1,
            sourcePath: r'C:\images\folder\sample.jpg',
            displayName: 'sample.jpg',
            importedFrom: r'C:\images\folder',
            width: 640,
            height: 480,
            status: ImageStatus.confirmed,
            boxes: [
              BoundingBox(
                id: 'box-1',
                x: 10,
                y: 20,
                width: 30,
                height: 40,
                status: BoxStatus.labeled,
                labelId: 1,
                confidence: 0.8,
              ),
            ],
          ),
        ],
      );

      final saved = await ProjectStore.save(project, projectPath);
      final raw = await File(projectPath).readAsString(encoding: utf8);
      final json = jsonDecode(raw) as Map<String, Object?>;
      final loaded = await ProjectStore.load(projectPath);

      expect(saved.projectFilePath, projectPath);
      expect(json['schemaVersion'], ProjectStore.currentSchemaVersion);
      expect(json.containsKey('imageFolderPath'), isFalse);
      expect(loaded.name, 'Demo Project');
      expect(loaded.projectFilePath, projectPath);
      expect(loaded.labels.first.shortcut, '1');
      expect(loaded.images.single.sourcePath, r'C:\images\folder\sample.jpg');
      expect(loaded.images.single.displayName, 'sample.jpg');
      expect(loaded.images.single.importedFrom, r'C:\images\folder');
      expect(loaded.images.single.status, ImageStatus.confirmed);
      expect(loaded.images.single.boxes.single.labelId, 1);
      expect(loaded.images.single.boxes.single.confidence, 0.8);
    });

    test('rejects unsupported project schema versions', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'bbox_project_store_bad_schema',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final projectPath =
          '${tempDir.path}${Platform.pathSeparator}bad.bbox.json';
      await File(projectPath).writeAsString(
        jsonEncode({
          'schemaVersion': ProjectStore.currentSchemaVersion + 1,
          'name': 'future project',
          'labels': <Object?>[],
          'images': <Object?>[],
        }),
        encoding: utf8,
      );

      expect(
        () => ProjectStore.load(projectPath),
        throwsA(isA<UnsupportedProjectVersionException>()),
      );
    });
  });
}
