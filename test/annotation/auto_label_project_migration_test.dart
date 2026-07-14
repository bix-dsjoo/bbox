import 'dart:convert';
import 'dart:io';

import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/project/project_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('schema 2 project loads without losing labels and saves as 3', () async {
    final directory = await Directory.systemTemp.createTemp(
      'bbox_auto_label_migration',
    );
    addTearDown(() => directory.delete(recursive: true));
    final inputPath = '${directory.path}${Platform.pathSeparator}v2.bbox.json';
    final outputPath = '${directory.path}${Platform.pathSeparator}v3.bbox.json';
    await File(inputPath).writeAsString(
      jsonEncode({
        'schemaVersion': 2,
        'name': 'Legacy labels',
        'status': 'ready',
        'labels': [
          {
            'id': 3,
            'name': 'Waffle',
            'color': 0xff123456,
            'shortcut': '3',
            'supercategory': 'object',
          },
        ],
        'images': [
          {
            'id': 1,
            'sourcePath': r'C:\images\bread.jpg',
            'displayName': 'bread.jpg',
            'width': 100,
            'height': 80,
            'status': 'needsReview',
            'boxes': [
              {
                'id': 'labeled',
                'x': 1,
                'y': 2,
                'width': 30,
                'height': 40,
                'status': 'labeled',
                'labelId': 3,
              },
              {
                'id': 'proposal',
                'x': 40,
                'y': 10,
                'width': 20,
                'height': 20,
                'status': 'proposal',
                'labelId': null,
              },
            ],
          },
        ],
        'detectorName': 'legacy',
      }),
      encoding: utf8,
    );

    final loaded = await ProjectStore.load(inputPath);
    final labeled = loaded.images.single.boxes.first;
    final proposal = loaded.images.single.boxes.last;

    expect(loaded.schemaVersion, 3);
    expect(loaded.images.single.contentSha256, isNull);
    expect(labeled.labelId, 3);
    expect(labeled.labelSource, LabelSource.user);
    expect(labeled.automation, isNull);
    expect(proposal.labelSource, isNull);
    expect(proposal.automation, isNull);

    await ProjectStore.save(loaded, outputPath);
    final saved = jsonDecode(await File(outputPath).readAsString()) as Map;
    expect(saved['schemaVersion'], 3);
  });

  test('unknown future schema still fails closed', () async {
    final directory = await Directory.systemTemp.createTemp(
      'bbox_future_schema',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}future.bbox.json';
    await File(path).writeAsString(
      jsonEncode({
        'schemaVersion': 4,
        'name': 'Future',
        'labels': <Object?>[],
        'images': <Object?>[],
      }),
    );

    await expectLater(
      ProjectStore.load(path),
      throwsA(isA<UnsupportedProjectVersionException>()),
    );
  });
}
