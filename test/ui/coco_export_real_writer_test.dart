import 'dart:convert';
import 'dart:io';

import 'package:bbox_labeler/ui/app_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_auto_box_runtime.dart';
import 'workbench/workbench_test_support.dart' show project;

void main() {
  test(
    'AppController writes parseable COCO JSON with expected content',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'bbox-coco-review-',
      );
      final output = File('${tempDir.path}${Platform.pathSeparator}coco.json');
      final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime())
        ..loadProject(project());

      try {
        await controller.exportCocoFile(output.path);

        expect(output.existsSync(), isTrue);
        final coco =
            jsonDecode(output.readAsStringSync()) as Map<String, dynamic>;
        expect(
          coco.keys,
          containsAll(<String>['images', 'annotations', 'categories']),
        );
        final images = coco['images'] as List<dynamic>;
        final annotations = coco['annotations'] as List<dynamic>;
        final categories = coco['categories'] as List<dynamic>;
        expect(images, hasLength(2));
        expect(images.first, containsPair('file_name', 'a.jpg'));
        expect(annotations, isEmpty);
        expect(categories, hasLength(1));
        expect(categories.first, containsPair('id', 1));
        expect(categories.first, containsPair('name', 'Person'));
      } finally {
        controller.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );
}
