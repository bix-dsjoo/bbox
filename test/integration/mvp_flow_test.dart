import 'dart:io';

import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/detector/detector.dart';
import 'package:bbox_labeler/project/project_library.dart';
import 'package:bbox_labeler/ui/app_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../support/fake_auto_box_runtime.dart';

void main() {
  test('project import label confirm export save and reload flow', () async {
    final tempDir = await Directory.systemTemp.createTemp('bbox_mvp_flow');
    addTearDown(() => tempDir.delete(recursive: true));
    final imageDir = Directory('${tempDir.path}${Platform.pathSeparator}이미지');
    await imageDir.create();
    await File(
      '${imageDir.path}${Platform.pathSeparator}a.jpg',
    ).writeAsBytes(img.encodeJpg(_fixtureImage(width: 100, height: 80)));
    await File(
      '${imageDir.path}${Platform.pathSeparator}한글.png',
    ).writeAsBytes(img.encodePng(_fixtureImage(width: 120, height: 90)));
    final projectPath =
        '${tempDir.path}${Platform.pathSeparator}project.bbox.json';

    final controller = AppController(
      autoBoxRuntime: FakeAutoBoxRuntime(
        detectionResult: const DetectionResult(
          detectorName: 'integration-auto-boxes',
          boxes: [
            BoundingBox(
              id: 'det-1-1',
              x: 25,
              y: 20,
              width: 33,
              height: 26,
              status: BoxStatus.proposal,
            ),
          ],
        ),
      ),
    );
    addTearDown(controller.dispose);
    controller.createProject('demo');
    await controller.addImagesFromFolder(
      imageDir.path,
      detector: const DummyDetector(),
    );

    expect(controller.project!.images, hasLength(2));
    expect(controller.project!.images.map((image) => image.status).toSet(), {
      ImageStatus.needsReview,
    });
    expect(controller.selectedImage!.visibleBoxes, isEmpty);

    await controller.detectSelectedImage();
    expect(
      controller.selectedImage!.visibleBoxes.single.status,
      BoxStatus.proposal,
    );

    controller.selectBox(controller.selectedImage!.visibleBoxes.single.id);
    final label = controller.addLabel('Person', 0xffe64a19);
    controller.assignSelectedBoxLabel(label.id);
    controller.confirmSelectedImage();
    await controller.saveProject(projectPath);

    final summary = controller.exportSummary();
    expect(summary.unconfirmedImageCount, 1);
    expect(summary.unlabeledProposalBoxCount, 0);
    expect(summary.hasBlockingErrors, isFalse);

    final coco = controller.buildCoco();
    expect(coco['images'], hasLength(2));
    expect(coco['annotations'], hasLength(1));
    expect(
      (coco['annotations'] as List<Object?>).single,
      containsPair('category_id', label.id),
    );

    final reloaded = AppController();
    addTearDown(reloaded.dispose);
    await reloaded.openProject(projectPath);

    expect(reloaded.project!.name, 'demo');
    expect(
      reloaded.project!.images.every(
        (image) => p.dirname(image.sourcePath) == imageDir.path,
      ),
      isTrue,
    );
    expect(
      reloaded.project!.images.any(
        (image) => image.status == ImageStatus.confirmed,
      ),
      isTrue,
    );
    expect(
      reloaded.project!.labels.any((label) => label.name == 'Person'),
      isTrue,
    );
  });

  test('internal project library create save list and reopen flow', () async {
    final tempDir = await Directory.systemTemp.createTemp('bbox_library_flow');
    addTearDown(() => tempDir.delete(recursive: true));

    final imageDir = Directory(
      '${tempDir.path}${Platform.pathSeparator}images',
    );
    await imageDir.create();
    await File(
      '${imageDir.path}${Platform.pathSeparator}a.jpg',
    ).writeAsBytes(img.encodeJpg(_fixtureImage(width: 100, height: 80)));

    final library = ProjectLibrary(
      rootPath: '${tempDir.path}${Platform.pathSeparator}appdata',
      clock: () => DateTime.utc(2026, 7, 7, 5, 30),
      idGenerator: (name, timestamp) => 'flow-project',
    );
    final controller = AppController(
      projectLibrary: library,
      autoBoxRuntime: FakeAutoBoxRuntime(),
    );
    addTearDown(controller.dispose);

    await controller.createLibraryProject('Library Demo');
    await controller.addImagesFromFolder(
      imageDir.path,
      detector: const DummyDetector(),
    );

    await controller.detectSelectedImage();
    await controller.saveProject();

    final freshController = AppController(projectLibrary: library);
    addTearDown(freshController.dispose);
    await freshController.loadProjectLibrary();

    expect(freshController.projectLibraryEntries.single.id, 'flow-project');
    expect(freshController.projectLibraryEntries.single.imageCount, 1);

    await freshController.openLibraryProject('flow-project');

    expect(freshController.project!.name, 'Library Demo');
    expect(
      p.basename(freshController.project!.images.single.sourcePath),
      'a.jpg',
    );
    expect(freshController.project!.images.single.importedFrom, imageDir.path);
    expect(
      freshController.project!.images.single.status,
      ImageStatus.needsReview,
    );
    expect(
      freshController.project!.images.single.sourcePath.isNotEmpty,
      isTrue,
    );
  });
}

img.Image _fixtureImage({required int width, required int height}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(8, 10, 12));
  for (var y = height ~/ 4; y < height ~/ 4 + height ~/ 3; y++) {
    for (var x = width ~/ 4; x < width ~/ 4 + width ~/ 3; x++) {
      image.setPixel(x, y, img.ColorRgb8(230, 170, 70));
    }
  }
  return image;
}
