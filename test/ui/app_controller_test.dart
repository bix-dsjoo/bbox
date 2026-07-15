import 'dart:async';
import 'dart:io';

import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/detector/detector.dart';
import 'package:bbox_labeler/project/source_relink_service.dart';
import 'package:bbox_labeler/ui/app_controller.dart';
import 'package:bbox_labeler/ui/workbench_copy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../support/fake_auto_box_runtime.dart';

void main() {
  group('AppController project labels', () {
    test('new projects start with bakery default labels', () {
      final controller = AppController();

      controller.createProject('demo');

      expect(controller.project!.labels.map((label) => label.name).toList(), [
        'Walnut Donut',
        'Croffle',
        'Waffle',
        'Scon',
        'Half-moon Croissant',
        'Croissant',
        'Flower Bread',
        'Almond Scon',
        'Dinner Roll',
        'Sugar Donut',
        'Bagel',
        'Egg Tart',
        'Muffin',
        'Burger',
        'Sandwich',
        'Grain  Campagne',
        'Almond Campagne',
        'Mini Bread',
        'Pastry Bread',
        'Plain Bread',
      ]);
      expect(controller.project!.labels.map((label) => label.id).toList(), [
        for (var id = 1; id <= 20; id++) id,
      ]);
      expect(
        controller.project!.labels.map((label) => label.shortcut).toList(),
        [
          '1',
          '2',
          '3',
          '4',
          '5',
          '6',
          '7',
          '8',
          '9',
          '0',
          'q',
          'w',
          'e',
          'r',
          't',
          'y',
          'u',
          'i',
          'o',
          'p',
        ],
      );
    });

    test(
      'loadProject migrates missing label shortcuts without changing boxes',
      () {
        final controller = AppController();
        final project = _project().copyWith(
          labels: const [
            LabelClass(id: 10, name: 'Bread', color: 0xff111111),
            LabelClass(id: 20, name: 'Cream', color: 0xff222222),
          ],
          images: [
            _project().images.first.copyWith(
              boxes: const [
                BoundingBox(
                  id: 'box-1',
                  x: 1,
                  y: 2,
                  width: 3,
                  height: 4,
                  status: BoxStatus.labeled,
                  labelId: 20,
                ),
              ],
            ),
          ],
        );

        controller.loadProject(project);

        expect(controller.project!.labels[0].shortcut, '1');
        expect(controller.project!.labels[1].shortcut, '2');
        expect(controller.project!.images.single.boxes.single.labelId, 20);
      },
    );
  });

  group('AppController image import', () {
    test(
      'adds images without running automatic detection during import',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'bbox_controller_import_no_detect',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final imagePath = '${tempDir.path}${Platform.pathSeparator}bread.png';
        final fixture = img.Image(width: 80, height: 60);
        img.fill(fixture, color: img.ColorRgb8(8, 10, 12));
        await File(imagePath).writeAsBytes(img.encodePng(fixture));

        final runtime = FakeAutoBoxRuntime();
        final controller = AppController(autoBoxRuntime: runtime);
        controller.createProject('demo');

        await controller.addImagesFromFolder(tempDir.path);

        expect(runtime.detectCount, 0);
        expect(controller.project!.images.single.visibleBoxes, isEmpty);
        expect(
          controller.project!.images.single.status,
          ImageStatus.needsReview,
        );
      },
    );

    test(
      'adds images from a folder without replacing existing images',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'bbox_controller_append',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final imagePath = '${tempDir.path}${Platform.pathSeparator}b.png';
        final fixture = img.Image(width: 20, height: 10);
        img.fill(fixture, color: img.ColorRgb8(18, 28, 38));
        await File(imagePath).writeAsBytes(img.encodePng(fixture));

        final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime())
          ..loadProject(_project());

        await controller.addImagesFromFolder(
          tempDir.path,
          detector: const DummyDetector(),
        );

        expect(
          controller.project!.images.map((image) => image.displayName).toList(),
          ['a.jpg', 'b.png'],
        );
      },
    );

    test(
      'folder import exposes importing activity before scan completes',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'bbox_import_progress',
        );
        addTearDown(() => tempDir.delete(recursive: true));

        final imagePath = '${tempDir.path}${Platform.pathSeparator}bread.png';
        final fixture = img.Image(width: 20, height: 10);
        img.fill(fixture, color: img.ColorRgb8(18, 28, 38));
        await File(imagePath).writeAsBytes(img.encodePng(fixture));

        final controller = AppController()..createProject('demo');
        final activities = <ProjectActivity>[];
        controller.addListener(
          () => activities.add(controller.projectActivity),
        );

        await controller.addImagesFromFolder(tempDir.path);

        expect(activities, contains(ProjectActivity.importing));
        expect(controller.projectActivity, ProjectActivity.idle);
      },
    );

    test('image import progress counts added skipped and errors', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'bbox_import_counts',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final goodPath = '${tempDir.path}${Platform.pathSeparator}good.png';
      final brokenPath = '${tempDir.path}${Platform.pathSeparator}broken.png';
      final fixture = img.Image(width: 20, height: 10);
      img.fill(fixture, color: img.ColorRgb8(18, 28, 38));
      await File(goodPath).writeAsBytes(img.encodePng(fixture));
      await File(brokenPath).writeAsString('not an image');

      final controller = AppController()..createProject('demo');

      await controller.addImageFiles([goodPath, brokenPath, goodPath]);

      final progress = controller.lastImportProgress!;
      expect(progress.added, 2);
      expect(progress.skipped, 1);
      expect(progress.errors, 1);
      expect(controller.lastUserMessage, WorkbenchCopy.importComplete(2, 1, 1));
    });

    test('new images are immediately marked as available', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'bbox_controller_import_availability',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final imagePath = p.join(tempDir.path, 'bread.png');
      await _writePng(imagePath, width: 20, height: 10);
      final controller = AppController()..createProject('demo');

      await controller.addImageFiles([imagePath]);

      final imageId = controller.project!.images.single.id;
      expect(
        controller.sourceAvailability[imageId],
        SourceAvailability.available,
      );
      controller.removeImageFromProject(imageId);
      expect(controller.sourceAvailability, isEmpty);
    });
  });

  group('AppController source availability and relink', () {
    test(
      'refresh reports missing sources without changing image status',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'bbox_controller_missing_source',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final controller = AppController()
          ..loadProject(
            _portableProject(
              sourcePaths: [p.join(tempDir.path, 'missing', 'bread.png')],
            ),
          );

        expect(
          controller.selectedImageViewState,
          SelectedImageViewState.unknown,
        );

        await controller.refreshSourceAvailability();

        expect(controller.missingSourceCount, 1);
        expect(
          controller.selectedSourceAvailability,
          SourceAvailability.missing,
        );
        expect(
          controller.selectedImageViewState,
          SelectedImageViewState.missing,
        );
        expect(controller.project!.images.single.status, ImageStatus.confirmed);
      },
    );

    test(
      'file relink preserves annotation state and does not add undo',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'bbox_controller_file_relink',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final replacementPath = p.join(
          tempDir.path,
          'replacement',
          'bread.png',
        );
        await _writePng(replacementPath, width: 32, height: 24);
        final project = _portableProject(
          sourcePaths: [p.join(tempDir.path, 'old', 'bread.png')],
        );
        final controller = AppController()..loadProject(project);
        final originalImage = controller.project!.images.single;
        final originalLabels = controller.project!.labels;
        await controller.refreshSourceAvailability();

        final result = await controller.relinkSourceFiles([replacementPath]);

        final relinked = controller.project!.images.single;
        expect(result.matchedCount, 1);
        expect(relinked.sourcePath, File(replacementPath).absolute.path);
        expect(relinked.importedFrom, File(replacementPath).parent.path);
        expect(relinked.id, originalImage.id);
        expect(relinked.status, ImageStatus.confirmed);
        expect(relinked.boxes, same(originalImage.boxes));
        expect(
          relinked.boxes.single.automation,
          same(originalImage.boxes.single.automation),
        );
        expect(controller.project!.labels, same(originalLabels));
        expect(
          controller.selectedSourceAvailability,
          SourceAvailability.available,
        );
        expect(controller.canUndo, isFalse);
      },
    );

    test(
      'folder relink records the replacement root as importedFrom',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'bbox_controller_folder_relink',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final originalRoot = p.join(tempDir.path, 'old-root');
        final replacementRoot = p.join(tempDir.path, 'replacement-root');
        final replacementPath = p.join(replacementRoot, 'batch', 'bread.png');
        await _writePng(replacementPath, width: 32, height: 24);
        final controller = AppController()
          ..loadProject(
            _portableProject(
              sourcePaths: [p.join(originalRoot, 'batch', 'bread.png')],
              importedFrom: originalRoot,
            ),
          );
        await controller.refreshSourceAvailability();

        final result = await controller.relinkSourceFolder(replacementRoot);

        expect(result.matchedCount, 1);
        expect(controller.project!.images.single.sourcePath, replacementPath);
        expect(controller.project!.images.single.importedFrom, replacementRoot);
        expect(controller.project!.images.single.status, ImageStatus.confirmed);
      },
    );

    test(
      'selected-file escape hatch resolves one of two ambiguous images',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'bbox_controller_selected_relink',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final replacementPath = p.join(
          tempDir.path,
          'replacement',
          'bread.png',
        );
        await _writePng(replacementPath, width: 32, height: 24);
        final controller = AppController()
          ..loadProject(
            _portableProject(
              sourcePaths: [
                p.join(tempDir.path, 'old-a', 'bread.png'),
                p.join(tempDir.path, 'old-b', 'bread.png'),
              ],
            ),
          );
        await controller.refreshSourceAvailability();

        final ambiguous = await controller.relinkSourceFiles([replacementPath]);
        expect(ambiguous.matchedCount, 0);
        expect(ambiguous.ambiguousImageIds, {1, 2});

        controller.selectImage(1);
        final selected = await controller.relinkSelectedSourceFile(
          replacementPath,
        );

        expect(selected.matchedCount, 1);
        expect(selected.matchedPaths.keys, {1});
        expect(controller.project!.images[0].sourcePath, replacementPath);
        expect(
          controller.project!.images[1].sourcePath,
          p.join(tempDir.path, 'old-b', 'bread.png'),
        );
        expect(controller.sourceAvailability[1], SourceAvailability.available);
        expect(controller.sourceAvailability[2], SourceAvailability.missing);
      },
    );

    test(
      'selected-file relink is a no-op unless selection is missing',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'bbox_controller_selected_relink_noop',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final existingPath = p.join(tempDir.path, 'bread.png');
        await _writePng(existingPath, width: 32, height: 24);
        final controller = AppController()
          ..loadProject(_portableProject(sourcePaths: [existingPath]));
        await controller.refreshSourceAvailability();

        final result = await controller.relinkSelectedSourceFile(existingPath);

        expect(result.matchedCount, 0);
        expect(result.unresolvedImageIds, isEmpty);
        expect(result.ambiguousImageIds, isEmpty);
        expect(controller.canUndo, isFalse);
      },
    );

    test(
      'undo and redo refresh source availability for restored paths',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'bbox_controller_undo_availability',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final existingPath = p.join(tempDir.path, 'bread.png');
        await _writePng(existingPath, width: 32, height: 24);
        final controller = AppController()
          ..loadProject(_portableProject(sourcePaths: [existingPath]));
        await controller.refreshSourceAvailability();
        controller.selectBox('box-1');
        controller.deleteSelectedBox();
        await File(existingPath).delete();

        controller.undo();
        await _waitForAvailability(controller, 1, SourceAvailability.missing);
        expect(controller.sourceAvailability[1], SourceAvailability.missing);

        await _writePng(existingPath, width: 32, height: 24);
        controller.redo();
        await _waitForAvailability(controller, 1, SourceAvailability.available);
        expect(controller.sourceAvailability[1], SourceAvailability.available);
      },
    );

    test(
      'stale availability refresh cannot overwrite a newly loaded project',
      () async {
        final service = _DelayedInspectSourceRelinkService();
        final controller = AppController(sourceRelinkService: service)
          ..loadProject(_portableProject(sourcePaths: ['old.png']));

        final refresh = controller.refreshSourceAvailability();
        await service.started.future;
        controller.loadProject(
          _portableProject(sourcePaths: ['new.png'], firstImageId: 99),
        );
        service.complete({1: SourceAvailability.missing});
        await refresh;

        expect(controller.sourceAvailability, {99: SourceAvailability.unknown});
        expect(controller.project!.images.single.id, 99);
      },
    );

    test(
      'stale availability refresh cannot reset a newly imported image',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'bbox_controller_import_refresh_race',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final imagePath = p.join(tempDir.path, 'new.png');
        await _writePng(imagePath, width: 32, height: 24);
        final service = _DelayedInspectSourceRelinkService();
        final controller = AppController(sourceRelinkService: service)
          ..loadProject(_portableProject(sourcePaths: ['old.png']));

        final refresh = controller.refreshSourceAvailability();
        await service.started.future;
        await controller.addImageFiles([imagePath]);
        service.complete({1: SourceAvailability.missing});
        await refresh;

        expect(controller.sourceAvailability[2], SourceAvailability.available);
      },
    );

    test('relink rebases source paths in both undo and redo history', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'bbox_controller_relink_history',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final replacementPath = p.join(tempDir.path, 'replacement', 'bread.png');
      await _writePng(replacementPath, width: 32, height: 24);
      final controller = AppController()
        ..loadProject(
          _portableProject(
            sourcePaths: [p.join(tempDir.path, 'old', 'bread.png')],
          ),
        );
      controller.addLabel('Extra One', 0xff112233);
      controller.addLabel('Extra Two', 0xff223344);
      controller.undo();
      await _waitForAvailability(controller, 1, SourceAvailability.missing);
      expect(controller.canUndo, isTrue);
      expect(controller.canRedo, isTrue);

      await controller.relinkSourceFiles([replacementPath]);
      controller.undo();
      await _waitForAvailability(controller, 1, SourceAvailability.available);

      expect(controller.project!.images.single.sourcePath, replacementPath);
      expect(
        controller.project!.images.single.importedFrom,
        p.dirname(replacementPath),
      );
      expect(
        controller.project!.labels.any((label) => label.name == 'Extra One'),
        isFalse,
      );

      controller.redo();
      await _waitForAvailability(controller, 1, SourceAvailability.available);
      expect(controller.project!.images.single.sourcePath, replacementPath);
      expect(
        controller.project!.images.single.importedFrom,
        p.dirname(replacementPath),
      );
      expect(
        controller.project!.labels.any((label) => label.name == 'Extra One'),
        isTrue,
      );
    });

    test(
      'relink rebases only histories with the same image id and source path',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'bbox_controller_relink_reused_id',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final sourceA = p.join(tempDir.path, 'source-a', 'a.png');
        final sourceB = p.join(tempDir.path, 'source-b', 'b.png');
        final replacementB = p.join(tempDir.path, 'replacement-b', 'b.png');
        await _writePng(sourceB, width: 32, height: 24);
        await _writePng(replacementB, width: 32, height: 24);
        final controller = AppController()
          ..loadProject(_portableProject(sourcePaths: [sourceA]));

        controller.addBox(x: 8, y: 8, width: 4, height: 4);
        controller.removeImageFromProject(1);
        await controller.addImageFiles([sourceB]);
        expect(controller.project!.images.single.id, 1);
        controller.addBox(x: 3, y: 3, width: 5, height: 5);
        await File(sourceB).delete();
        await controller.refreshSourceAvailability();
        expect(controller.sourceAvailability[1], SourceAvailability.missing);

        await controller.relinkSourceFiles([replacementB]);

        controller.undo();
        await _waitForAvailability(controller, 1, SourceAvailability.available);
        expect(controller.project!.images.single.sourcePath, replacementB);
        expect(controller.project!.images.single.boxes, isEmpty);

        controller.undo();
        expect(controller.project!.images, isEmpty);

        controller.undo();
        expect(controller.project!.images.single.sourcePath, sourceA);
        expect(controller.project!.images.single.boxes, hasLength(2));

        controller.undo();
        expect(controller.project!.images.single.sourcePath, sourceA);
        expect(controller.project!.images.single.boxes, hasLength(1));

        controller.redo();
        expect(controller.project!.images.single.sourcePath, sourceA);
        expect(controller.project!.images.single.boxes, hasLength(2));

        controller.redo();
        expect(controller.project!.images, isEmpty);

        controller.redo();
        await _waitForAvailability(controller, 1, SourceAvailability.available);
        expect(controller.project!.images.single.sourcePath, replacementB);
        expect(controller.project!.images.single.boxes, isEmpty);

        controller.redo();
        await _waitForAvailability(controller, 1, SourceAvailability.available);
        expect(controller.project!.images.single.sourcePath, replacementB);
        expect(controller.project!.images.single.boxes, hasLength(1));
      },
    );

    test('relink invalidates in-flight detection for the old source', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'bbox_controller_relink_detection',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final replacementPath = p.join(tempDir.path, 'replacement', 'bread.png');
      await _writePng(replacementPath, width: 32, height: 24);
      final detection = Completer<DetectionResult>();
      final controller = AppController()
        ..loadProject(
          _portableProject(
            sourcePaths: [p.join(tempDir.path, 'old', 'bread.png')],
          ),
        );
      await controller.refreshSourceAvailability();

      final pendingDetection = controller.detectSelectedImage(
        replaceExisting: true,
        detector: _RecordingDetector(
          onDetect: (_, {imagePath, options = const DetectionOptions()}) =>
              detection.future,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await controller.relinkSourceFiles([replacementPath]);
      detection.complete(
        const DetectionResult(
          detectorName: 'stale-detector',
          boxes: [
            BoundingBox(
              id: 'stale-box',
              x: 2,
              y: 3,
              width: 4,
              height: 5,
              status: BoxStatus.proposal,
            ),
          ],
        ),
      );
      await pendingDetection;

      expect(controller.project!.images.single.sourcePath, replacementPath);
      expect(controller.project!.images.single.boxes.single.id, 'box-1');
      expect(controller.isAutomationRunning, isFalse);
      expect(controller.lastUserMessage, contains('Reconnected 1'));
    });

    test(
      'relink invalidates in-flight classification for the old source',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'bbox_controller_relink_classification',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final replacementPath = p.join(
          tempDir.path,
          'replacement',
          'bread.png',
        );
        await _writePng(replacementPath, width: 32, height: 24);
        final classification = Completer<DetectionResult>();
        final runtime = FakeAutoBoxRuntime(
          classifyHandler: (_, _) => classification.future,
        );
        final controller = AppController(autoBoxRuntime: runtime)
          ..loadProject(
            _portableProject(
              sourcePaths: [p.join(tempDir.path, 'old', 'bread.png')],
            ),
          )
          ..selectBox('box-1');
        await controller.refreshSourceAvailability();
        controller.moveSelectedBox(1, 0);
        await _waitUntil(() => runtime.classifyCount == 1);

        await controller.relinkSourceFiles([replacementPath]);
        classification.complete(
          const DetectionResult(
            detectorName: 'stale-classifier',
            pipelineVersion: 'pipeline-v1',
            imageSha256: 'new-hash',
            boxes: [
              BoundingBox(
                id: 'box-1',
                x: 2,
                y: 2,
                width: 3,
                height: 4,
                status: BoxStatus.labeled,
                labelId: 7,
                labelSource: LabelSource.auto,
              ),
            ],
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final image = controller.project!.images.single;
        expect(image.sourcePath, replacementPath);
        expect(image.boxes.single.status, BoxStatus.proposal);
        expect(image.boxes.single.labelId, isNull);
        expect(controller.lastUserMessage, contains('Reconnected 1'));
      },
    );

    test(
      'successful relink reports availability refresh failure as warning',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'bbox_controller_relink_refresh_warning',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final replacementPath = p.join(
          tempDir.path,
          'replacement',
          'bread.png',
        );
        await _writePng(replacementPath, width: 32, height: 24);
        final service = _FailOnSecondInspectSourceRelinkService();
        final controller = AppController(sourceRelinkService: service)
          ..loadProject(
            _portableProject(
              sourcePaths: [p.join(tempDir.path, 'old', 'bread.png')],
            ),
          );
        await controller.refreshSourceAvailability();

        final result = await controller.relinkSourceFiles([replacementPath]);

        expect(result.matchedCount, 1);
        expect(controller.project!.images.single.sourcePath, replacementPath);
        expect(controller.lastUserMessage, contains('Reconnected 1'));
        expect(controller.lastUserMessage, contains('availability'));
        expect(controller.lastUserMessage, isNot(contains('try again')));
      },
    );

    test('undo consumes background availability refresh failure', () async {
      final controller = AppController(
        sourceRelinkService: _AlwaysFailingInspectSourceRelinkService(),
      )..loadProject(_portableProject(sourcePaths: ['missing.png']));
      controller.addLabel('Undo Label', 0xff334455);

      controller.undo();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(controller.projectActivity, ProjectActivity.idle);
      expect(controller.lastUserMessage, contains('Could not check source'));
    });
  });

  group('AppController box editing', () {
    test(
      'detectSelectedImage replaces all existing boxes with proposals',
      () async {
        final optionsSeen = <DetectionOptions>[];
        final controller = AppController()..loadProject(_project());
        controller.selectBox('box-1');

        await controller.detectSelectedImage(
          replaceExisting: true,
          detector: _RecordingDetector(
            onDetect:
                (image, {imagePath, options = const DetectionOptions()}) async {
                  optionsSeen.add(options);
                  return DetectionResult(
                    detectorName: 'test-detector',
                    boxes: [
                      BoundingBox(
                        id: 'det-${image.id}-1',
                        x: 3,
                        y: 4,
                        width: 10,
                        height: 12,
                        status: BoxStatus.proposal,
                      ),
                    ],
                  );
                },
          ),
          options: const DetectionOptions(maxProposals: 7),
        );

        expect(optionsSeen.single.maxProposals, 7);
        expect(controller.selectedImage!.visibleBoxes, hasLength(1));
        expect(controller.selectedImage!.visibleBoxes.single.id, 'det-1-1');
        expect(
          controller.selectedImage!.visibleBoxes.single.status,
          BoxStatus.proposal,
        );
        expect(controller.selectedBoxId, 'det-1-1');
        expect(controller.lastUserMessage, WorkbenchCopy.autoBoxesCreated(1));
        expect(controller.canUndo, isTrue);

        controller.undo();
        expect(controller.selectedImage!.visibleBoxes.single.id, 'box-1');
      },
    );

    test(
      'detectSelectedImage undo restores the original confirmed image state',
      () async {
        final controller = AppController()..loadProject(_confirmedProject());
        controller.selectBox('box-1');

        await controller.detectSelectedImage(
          replaceExisting: true,
          detector: _RecordingDetector(
            onDetect:
                (image, {imagePath, options = const DetectionOptions()}) async {
                  return const DetectionResult(
                    detectorName: 'test-detector',
                    boxes: [
                      BoundingBox(
                        id: 'det-1',
                        x: 3,
                        y: 4,
                        width: 10,
                        height: 12,
                        status: BoxStatus.proposal,
                      ),
                    ],
                  );
                },
          ),
        );

        expect(controller.selectedImage!.status, ImageStatus.needsReview);
        expect(controller.selectedImage!.visibleBoxes.single.id, 'det-1');
        expect(controller.canUndo, isTrue);

        controller.undo();

        final restoredImage = controller.selectedImage!;
        final restoredBox = restoredImage.visibleBoxes.single;
        expect(restoredImage.status, ImageStatus.confirmed);
        expect(restoredBox.id, 'box-1');
        expect(restoredBox.status, BoxStatus.labeled);
        expect(restoredBox.labelId, 1);
      },
    );

    test('detectSelectedImage preserves boxes when detector fails', () async {
      final controller = AppController()..loadProject(_project());
      controller.selectBox('box-1');
      final projectBefore = controller.project;
      final selectedBoxIdBefore = controller.selectedBoxId;
      final canUndoBefore = controller.canUndo;

      await controller.detectSelectedImage(
        replaceExisting: true,
        detector: _RecordingDetector(
          onDetect:
              (image, {imagePath, options = const DetectionOptions()}) async {
                return const DetectionResult(
                  detectorName: 'test-detector',
                  boxes: [],
                  errorMessage: 'boom',
                );
              },
        ),
      );

      expect(controller.project, same(projectBefore));
      expect(controller.selectedImage!.visibleBoxes.single.id, 'box-1');
      expect(controller.selectedImage!.errorMessage, isNull);
      expect(controller.selectedBoxId, selectedBoxIdBefore);
      expect(controller.canUndo, canUndoBefore);
      expect(controller.lastError, 'boom');
      expect(controller.lastUserMessage, WorkbenchCopy.autoBoxesFailed);
    });

    test(
      'detectSelectedImage restores state and avoids undo entry when detector throws',
      () async {
        final controller = AppController()..loadProject(_confirmedProject());
        controller.selectBox('box-1');

        await controller.detectSelectedImage(
          replaceExisting: true,
          detector: _RecordingDetector(
            onDetect:
                (image, {imagePath, options = const DetectionOptions()}) async {
                  throw StateError('detector exploded');
                },
          ),
        );

        final restoredImage = controller.selectedImage!;
        final restoredBox = restoredImage.visibleBoxes.single;
        expect(restoredImage.status, ImageStatus.confirmed);
        expect(restoredBox.id, 'box-1');
        expect(restoredBox.status, BoxStatus.labeled);
        expect(restoredBox.labelId, 1);
        expect(controller.canUndo, isFalse);
        expect(
          restoredImage.errorMessage ?? controller.lastError?.toString(),
          contains('detector exploded'),
        );
        expect(controller.lastUserMessage, WorkbenchCopy.autoBoxesWorkerFailed);
      },
    );

    test('detectSelectedImage reports when no proposals are found', () async {
      final controller = AppController()..loadProject(_project());

      await controller.detectSelectedImage(
        replaceExisting: true,
        detector: _RecordingDetector(
          onDetect:
              (image, {imagePath, options = const DetectionOptions()}) async {
                return const DetectionResult(
                  detectorName: 'test-detector',
                  boxes: [],
                );
              },
        ),
      );

      expect(controller.selectedImage!.visibleBoxes, isEmpty);
      expect(controller.lastUserMessage, WorkbenchCopy.autoBoxesEmpty);
    });

    test(
      'detectSelectedImage uses detector defaults without proposal count UI',
      () async {
        final optionsSeen = <DetectionOptions>[];
        final controller = AppController()..loadProject(_project());

        await controller.detectSelectedImage(
          replaceExisting: true,
          detector: _RecordingDetector(
            onDetect:
                (image, {imagePath, options = const DetectionOptions()}) async {
                  optionsSeen.add(options);
                  return const DetectionResult(
                    detectorName: 'test-detector',
                    boxes: [],
                  );
                },
          ),
        );

        expect(optionsSeen.single.maxProposals, isNull);
      },
    );

    test('clearSelectedImageBoxes removes boxes and supports undo', () {
      final controller = AppController()..loadProject(_project());
      controller.selectBox('box-1');

      controller.clearSelectedImageBoxes();

      expect(controller.selectedImage!.visibleBoxes, isEmpty);
      expect(controller.selectedBoxId, isNull);
      expect(controller.canConfirmSelectedImage, isTrue);

      controller.undo();
      expect(controller.selectedImage!.visibleBoxes.single.id, 'box-1');
    });

    test('moves and resizes selected boxes in original image pixels', () {
      final controller = AppController()..loadProject(_project());
      controller.selectBox('box-1');

      controller.moveSelectedBox(80, 70);
      controller.resizeSelectedBox(500, 500);

      final box = controller.selectedImage!.visibleBoxes.single;
      expect(box.x, 80);
      expect(box.y, 60);
      expect(box.width, 20);
      expect(box.height, 20);
      expect(box.x + box.width, 100);
      expect(box.y + box.height, 80);
    });

    test('setSelectedBoxGeometry updates all selected box coordinates', () {
      final controller = AppController()..loadProject(_project());
      controller.selectBox('box-1');

      controller.setSelectedBoxGeometry(x: 10, y: 12, width: 30, height: 28);

      final box = controller.selectedImage!.visibleBoxes.single;
      expect(box.x, 10);
      expect(box.y, 12);
      expect(box.width, 30);
      expect(box.height, 28);
    });

    test('deletes boxes with undo and redo support', () {
      final controller = AppController()..loadProject(_project());
      controller.selectBox('box-1');

      controller.deleteSelectedBox();
      expect(controller.selectedImage!.visibleBoxes, isEmpty);
      expect(controller.canUndo, isTrue);

      controller.undo();
      expect(controller.selectedImage!.visibleBoxes.single.id, 'box-1');
      expect(controller.canRedo, isTrue);

      controller.redo();
      expect(controller.selectedImage!.visibleBoxes, isEmpty);
    });

    test('adds manual proposal boxes and selects them', () {
      final controller = AppController()..loadProject(_project());

      controller.addBox(x: 5, y: 6, width: 30, height: 40);

      final box = controller.selectedBox!;
      expect(box.status, BoxStatus.proposal);
      expect(box.x, 5);
      expect(box.y, 6);
      expect(box.width, 30);
      expect(box.height, 40);
    });

    test(
      'completeSelectedImageAndSelectNext advances to next review image',
      () {
        final controller = AppController()
          ..loadProject(
            AnnotationProject.empty(name: 'demo').copyWith(
              status: ProjectStatus.ready,
              labels: const [
                LabelClass(id: 1, name: 'Person', color: 0xffe64a19),
              ],
              images: const [
                AnnotatedImage(
                  id: 1,
                  sourcePath: 'a.jpg',
                  displayName: 'a.jpg',
                  width: 100,
                  height: 80,
                  status: ImageStatus.needsReview,
                  boxes: [
                    BoundingBox(
                      id: 'box-1',
                      x: 10,
                      y: 10,
                      width: 20,
                      height: 20,
                      status: BoxStatus.labeled,
                      labelId: 1,
                    ),
                  ],
                ),
                AnnotatedImage(
                  id: 2,
                  sourcePath: 'b.jpg',
                  displayName: 'b.jpg',
                  width: 100,
                  height: 80,
                  status: ImageStatus.needsReview,
                ),
              ],
            ),
          );

        controller.completeSelectedImageAndSelectNext();

        expect(controller.project!.images.first.status, ImageStatus.confirmed);
        expect(controller.selectedImageId, 2);
      },
    );

    test(
      'completeSelectedImageAndSelectNext keeps selection when no work image remains',
      () {
        final controller = AppController()
          ..loadProject(
            AnnotationProject.empty(name: 'demo').copyWith(
              status: ProjectStatus.ready,
              labels: const [
                LabelClass(id: 1, name: 'Person', color: 0xffe64a19),
              ],
              images: const [
                AnnotatedImage(
                  id: 1,
                  sourcePath: 'a.jpg',
                  displayName: 'a.jpg',
                  width: 100,
                  height: 80,
                  status: ImageStatus.needsReview,
                  boxes: [
                    BoundingBox(
                      id: 'box-1',
                      x: 10,
                      y: 10,
                      width: 20,
                      height: 20,
                      status: BoxStatus.labeled,
                      labelId: 1,
                    ),
                  ],
                ),
              ],
            ),
          );

        controller.completeSelectedImageAndSelectNext();

        expect(controller.project!.images.single.status, ImageStatus.confirmed);
        expect(controller.selectedImageId, 1);
        expect(controller.selectedBoxId, isNull);
        expect(
          controller.lastUserMessage,
          WorkbenchCopy.allWorkImagesCompleted,
        );
      },
    );

    test('completeSelectedImageAndSelectNext skips error images and wraps', () {
      final controller = AppController()
        ..loadProject(
          AnnotationProject.empty(name: 'demo').copyWith(
            status: ProjectStatus.ready,
            labels: const [
              LabelClass(id: 1, name: 'Person', color: 0xffe64a19),
            ],
            images: const [
              AnnotatedImage(
                id: 1,
                sourcePath: 'a.jpg',
                displayName: 'a.jpg',
                width: 100,
                height: 80,
                status: ImageStatus.needsReview,
              ),
              AnnotatedImage(
                id: 2,
                sourcePath: 'broken.jpg',
                displayName: 'broken.jpg',
                width: 0,
                height: 0,
                status: ImageStatus.error,
              ),
              AnnotatedImage(
                id: 3,
                sourcePath: 'c.jpg',
                displayName: 'c.jpg',
                width: 100,
                height: 80,
                status: ImageStatus.needsReview,
                boxes: [
                  BoundingBox(
                    id: 'box-3',
                    x: 10,
                    y: 10,
                    width: 20,
                    height: 20,
                    status: BoxStatus.labeled,
                    labelId: 1,
                  ),
                ],
              ),
            ],
          ),
        );

      controller.selectImage(3);
      controller.completeSelectedImageAndSelectNext();

      expect(controller.project!.images.last.status, ImageStatus.confirmed);
      expect(controller.selectedImageId, 1);
    });

    test('assignSelectedBoxLabel follows display numbers from #1 to #2', () {
      final controller = AppController()
        ..loadProject(
          AnnotationProject.empty(name: 'demo').copyWith(
            status: ProjectStatus.ready,
            labels: const [
              LabelClass(id: 1, name: 'Person', color: 0xffe64a19),
            ],
            images: const [
              AnnotatedImage(
                id: 1,
                sourcePath: 'a.jpg',
                displayName: 'a.jpg',
                width: 100,
                height: 80,
                status: ImageStatus.needsReview,
                boxes: [
                  BoundingBox(
                    id: 'box-3',
                    x: 10,
                    y: 50,
                    width: 20,
                    height: 20,
                    status: BoxStatus.proposal,
                  ),
                  BoundingBox(
                    id: 'box-1',
                    x: 10,
                    y: 10,
                    width: 20,
                    height: 20,
                    status: BoxStatus.proposal,
                  ),
                  BoundingBox(
                    id: 'box-2',
                    x: 40,
                    y: 10,
                    width: 20,
                    height: 20,
                    status: BoxStatus.proposal,
                  ),
                ],
              ),
            ],
          ),
        );

      controller.selectBox('box-1');
      controller.assignSelectedBoxLabel(1);

      expect(
        controller.selectedImage!.boxes
            .singleWhere((box) => box.id == 'box-1')
            .status,
        BoxStatus.labeled,
      );
      expect(controller.selectedBoxId, 'box-2');
    });

    test(
      'assignSelectedBoxLabel ignores source order when selecting visual #2',
      () {
        final controller = AppController()
          ..loadProject(
            AnnotationProject.empty(name: 'demo').copyWith(
              status: ProjectStatus.ready,
              labels: const [
                LabelClass(id: 1, name: 'Person', color: 0xffe64a19),
              ],
              images: const [
                AnnotatedImage(
                  id: 1,
                  sourcePath: 'a.jpg',
                  displayName: 'a.jpg',
                  width: 100,
                  height: 80,
                  status: ImageStatus.needsReview,
                  boxes: [
                    BoundingBox(
                      id: 'box-3',
                      x: 10,
                      y: 50,
                      width: 20,
                      height: 20,
                      status: BoxStatus.proposal,
                    ),
                    BoundingBox(
                      id: 'box-2',
                      x: 40,
                      y: 10,
                      width: 20,
                      height: 20,
                      status: BoxStatus.proposal,
                    ),
                    BoundingBox(
                      id: 'box-1',
                      x: 10,
                      y: 10,
                      width: 20,
                      height: 20,
                      status: BoxStatus.proposal,
                    ),
                  ],
                ),
              ],
            ),
          );

        controller.selectBox('box-1');
        controller.assignSelectedBoxLabel(1);

        expect(controller.selectedBoxId, 'box-2');
      },
    );

    test(
      'assignSelectedBoxLabel keeps selection when all boxes are labeled',
      () {
        final controller = AppController()
          ..loadProject(
            AnnotationProject.empty(name: 'demo').copyWith(
              status: ProjectStatus.ready,
              labels: const [
                LabelClass(id: 1, name: 'Person', color: 0xffe64a19),
              ],
              images: const [
                AnnotatedImage(
                  id: 1,
                  sourcePath: 'a.jpg',
                  displayName: 'a.jpg',
                  width: 100,
                  height: 80,
                  status: ImageStatus.needsReview,
                  boxes: [
                    BoundingBox(
                      id: 'box-1',
                      x: 10,
                      y: 10,
                      width: 20,
                      height: 20,
                      status: BoxStatus.proposal,
                    ),
                  ],
                ),
              ],
            ),
          );

        controller.selectBox('box-1');
        controller.assignSelectedBoxLabel(1);

        expect(controller.selectedBoxId, 'box-1');
        expect(controller.canConfirmSelectedImage, isTrue);
      },
    );

    test('selectedImageCompletionBlockerReason reports unlabeled boxes', () {
      final controller = AppController()..loadProject(_project());

      expect(
        controller.selectedImageCompletionBlockerReason,
        WorkbenchCopy.unlabeledBoxCount(1),
      );
    });

    test('selectedImageCompletionBlockerReason reports error images', () {
      final controller = AppController()..loadProject(_projectWithError());
      controller.selectImage(3);

      expect(
        controller.selectedImageCompletionBlockerReason,
        WorkbenchCopy.completionBlockedInvalidImage,
      );
    });

    test('selectedImageCompletionBlockerReason reports invalid boxes', () {
      final controller = AppController()..loadProject(_projectWithInvalidBox());

      expect(
        controller.selectedImageCompletionBlockerReason,
        WorkbenchCopy.invalidBoxCount(1),
      );
    });
  });
}

AnnotationProject _project() {
  return AnnotationProject.empty(name: 'demo').copyWith(
    images: const [
      AnnotatedImage(
        id: 1,
        sourcePath: 'a.jpg',
        displayName: 'a.jpg',
        width: 100,
        height: 80,
        status: ImageStatus.needsReview,
        boxes: [
          BoundingBox(
            id: 'box-1',
            x: 0,
            y: 0,
            width: 20,
            height: 20,
            status: BoxStatus.proposal,
          ),
        ],
      ),
    ],
  );
}

AnnotationProject _confirmedProject() {
  return AnnotationProject.empty(name: 'demo').copyWith(
    labels: const [LabelClass(id: 1, name: 'Bread', color: 0xFFAA5500)],
    images: const [
      AnnotatedImage(
        id: 1,
        sourcePath: 'a.jpg',
        displayName: 'a.jpg',
        width: 100,
        height: 80,
        status: ImageStatus.confirmed,
        boxes: [
          BoundingBox(
            id: 'box-1',
            x: 5,
            y: 6,
            width: 20,
            height: 22,
            status: BoxStatus.labeled,
            labelId: 1,
          ),
        ],
      ),
    ],
  );
}

AnnotationProject _projectWithError() {
  return _project().copyWith(
    images: [
      ..._project().images,
      const AnnotatedImage(
        id: 3,
        sourcePath: 'broken.jpg',
        displayName: 'broken.jpg',
        width: 0,
        height: 0,
        status: ImageStatus.error,
        errorMessage: 'decode failed',
      ),
    ],
  );
}

AnnotationProject _projectWithInvalidBox() {
  return AnnotationProject.empty(name: 'demo').copyWith(
    images: const [
      AnnotatedImage(
        id: 1,
        sourcePath: 'a.jpg',
        displayName: 'a.jpg',
        width: 100,
        height: 80,
        status: ImageStatus.needsReview,
        boxes: [
          BoundingBox(
            id: 'box-1',
            x: 90,
            y: 70,
            width: 20,
            height: 20,
            status: BoxStatus.labeled,
            labelId: 1,
          ),
        ],
      ),
    ],
  );
}

class _RecordingDetector implements Detector {
  const _RecordingDetector({required this.onDetect});

  final Future<DetectionResult> Function(
    AnnotatedImage image, {
    String? imagePath,
    DetectionOptions options,
  })
  onDetect;

  @override
  String get name => 'recording-detector';

  @override
  Future<DetectionResult> detect(
    AnnotatedImage image, {
    String? imagePath,
    DetectionOptions options = const DetectionOptions(),
  }) {
    return onDetect(image, imagePath: imagePath, options: options);
  }
}

AnnotationProject _portableProject({
  required List<String> sourcePaths,
  String? importedFrom,
  int firstImageId = 1,
}) {
  const automation = BoxAutomationMetadata(
    suggestedLabelId: 7,
    candidates: [LabelCandidate(labelId: 7, score: 0.98)],
    pipelineVersion: 'pipeline-v1',
    policyVersion: 'policy-v1',
    detectorSha256: 'detector-sha',
  );
  return AnnotationProject.empty(name: 'portable').copyWith(
    labels: const [LabelClass(id: 7, name: 'Bread', color: 0xffff9800)],
    images: [
      for (var index = 0; index < sourcePaths.length; index++)
        AnnotatedImage(
          id: firstImageId + index,
          sourcePath: sourcePaths[index],
          displayName: 'bread.png',
          importedFrom: importedFrom,
          width: 32,
          height: 24,
          status: ImageStatus.confirmed,
          boxes: const [
            BoundingBox(
              id: 'box-1',
              x: 1,
              y: 2,
              width: 3,
              height: 4,
              status: BoxStatus.labeled,
              labelId: 7,
              labelSource: LabelSource.auto,
              automation: automation,
            ),
          ],
        ),
    ],
  );
}

Future<void> _writePng(
  String path, {
  required int width,
  required int height,
}) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(18, 28, 38));
  await file.writeAsBytes(img.encodePng(image), flush: true);
}

Future<void> _waitForAvailability(
  AppController controller,
  int imageId,
  SourceAvailability expected,
) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (controller.sourceAvailability[imageId] == expected) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for $expected availability for image $imageId.');
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for condition.');
}

class _DelayedInspectSourceRelinkService extends SourceRelinkService {
  _DelayedInspectSourceRelinkService();

  final started = Completer<void>();
  final _completion = Completer<Map<int, SourceAvailability>>();

  @override
  Future<Map<int, SourceAvailability>> inspectSources(
    Iterable<AnnotatedImage> images,
  ) {
    if (!started.isCompleted) started.complete();
    return _completion.future;
  }

  void complete(Map<int, SourceAvailability> availability) {
    _completion.complete(availability);
  }
}

class _FailOnSecondInspectSourceRelinkService extends SourceRelinkService {
  int _inspectCount = 0;

  @override
  Future<Map<int, SourceAvailability>> inspectSources(
    Iterable<AnnotatedImage> images,
  ) {
    _inspectCount++;
    if (_inspectCount == 2) {
      throw FileSystemException('Injected availability failure');
    }
    return super.inspectSources(images);
  }
}

class _AlwaysFailingInspectSourceRelinkService extends SourceRelinkService {
  @override
  Future<Map<int, SourceAvailability>> inspectSources(
    Iterable<AnnotatedImage> images,
  ) {
    throw FileSystemException('Injected availability failure');
  }
}
