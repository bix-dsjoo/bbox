import 'dart:io';

import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/detector/detector.dart';
import 'package:bbox_labeler/ui/app_controller.dart';
import 'package:bbox_labeler/ui/workbench_copy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

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
