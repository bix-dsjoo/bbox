// ignore_for_file: deprecated_member_use
export 'dart:async';
export 'dart:io';
export 'dart:ui' show Tristate;
export 'package:bbox_labeler/annotation/default_labels.dart';
export 'package:bbox_labeler/annotation/models.dart';
export 'package:bbox_labeler/detector/detector.dart';
export 'package:bbox_labeler/project/source_relink_service.dart';
export 'package:bbox_labeler/ui/app_controller.dart';
export 'package:bbox_labeler/ui/app_theme.dart';
export 'package:bbox_labeler/ui/coco_export_destination_picker.dart';
export 'package:bbox_labeler/ui/image_import_picker.dart';
export 'package:bbox_labeler/ui/project_transfer_picker.dart';
export 'package:bbox_labeler/ui/workbench_copy.dart';
export 'package:bbox_labeler/ui/workbench_screen.dart';
export 'package:flutter/foundation.dart';
export 'package:flutter/gestures.dart';
export 'package:flutter/semantics.dart';
export 'package:flutter/services.dart';
import 'dart:async';
import 'dart:io';
import 'package:bbox_labeler/annotation/default_labels.dart';
import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/project/source_relink_service.dart';
import 'package:bbox_labeler/ui/app_controller.dart';
import 'package:bbox_labeler/ui/coco_export_destination_picker.dart';
import 'package:bbox_labeler/ui/image_import_picker.dart';
import 'package:bbox_labeler/ui/project_transfer_picker.dart';
import 'package:bbox_labeler/ui/workbench_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

img.Image fixtureImage(int width, int height) {
  final fixture = img.Image(width: width, height: height);
  img.fill(fixture, color: img.ColorRgb8(18, 28, 38));
  return fixture;
}

Widget app(
  AppController controller, {
  ImageImportPicker imageImportPicker = const FakeImageImportPicker(),
  CocoExportDestinationPicker exportDestinationPicker =
      const FakeCocoExportDestinationPicker(),
  ProjectTransferPicker projectTransferPicker =
      const FakeProjectTransferPicker(),
  Future<void> Function(String path)? exportWriter,
}) {
  return MaterialApp(
    home: WorkbenchScreen(
      controller: controller,
      imageImportPicker: imageImportPicker,
      exportDestinationPicker: exportDestinationPicker,
      projectTransferPicker: projectTransferPicker,
      exportWriter: exportWriter,
    ),
  );
}

class FakeProjectTransferPicker extends ProjectTransferPicker {
  const FakeProjectTransferPicker({
    this.importPath,
    this.snapshotPath,
    this.onPickImport,
    this.onPickSnapshot,
  });

  final String? importPath;
  final String? snapshotPath;
  final VoidCallback? onPickImport;
  final VoidCallback? onPickSnapshot;

  @override
  Future<String?> pickImportFile() {
    onPickImport?.call();
    return SynchronousFuture(importPath);
  }

  @override
  Future<String?> pickSnapshotDestination() {
    onPickSnapshot?.call();
    return SynchronousFuture(snapshotPath);
  }
}

class FakeCocoExportDestinationPicker extends CocoExportDestinationPicker {
  const FakeCocoExportDestinationPicker({this.onPick});

  final Future<String?> Function()? onPick;

  @override
  Future<String?> pickDestination() =>
      onPick?.call() ?? SynchronousFuture<String?>(null);
}

class FakeImageImportPicker extends ImageImportPicker {
  const FakeImageImportPicker({
    this.folderPath,
    this.filePaths = const [],
    this.onPickFolder,
    this.onPickFiles,
  });
  final String? folderPath;
  final List<String> filePaths;
  final VoidCallback? onPickFolder;
  final VoidCallback? onPickFiles;
  @override
  Future<String?> pickImageFolder() {
    onPickFolder?.call();
    return SynchronousFuture(folderPath);
  }

  @override
  Future<List<String>> pickImageFiles() {
    onPickFiles?.call();
    return SynchronousFuture(filePaths);
  }
}

class DelayedImageImportPicker extends ImageImportPicker {
  final fileResult = Completer<List<String>>();
  final folderResult = Completer<String?>();
  int fileCalls = 0;
  int folderCalls = 0;

  @override
  Future<String?> pickImageFolder() {
    folderCalls += 1;
    return folderResult.future;
  }

  @override
  Future<List<String>> pickImageFiles() {
    fileCalls += 1;
    return fileResult.future;
  }
}

class ImmediateRelinkSourceService extends SourceRelinkService {
  ImmediateRelinkSourceService({required this.replacementPath});

  final String replacementPath;
  int fileRelinkCalls = 0;
  int folderRelinkCalls = 0;

  @override
  Future<Map<int, SourceAvailability>> inspectSources(
    Iterable<AnnotatedImage> images,
  ) => SynchronousFuture({
    for (final image in images)
      image.id: image.sourcePath == replacementPath
          ? SourceAvailability.available
          : SourceAvailability.missing,
  });

  @override
  Future<SourceRelinkResult> relinkFiles({
    required List<AnnotatedImage> missingImages,
    required List<String> candidatePaths,
  }) {
    fileRelinkCalls += 1;
    final image = missingImages.single;
    return SynchronousFuture(
      SourceRelinkResult(
        matchedPaths: {image.id: replacementPath},
        matchedImportedFrom: {image.id: File(replacementPath).parent.path},
        unresolvedImageIds: const {},
        ambiguousImageIds: const {},
      ),
    );
  }

  @override
  Future<SourceRelinkResult> relinkFolder({
    required List<AnnotatedImage> missingImages,
    required String folderPath,
  }) {
    folderRelinkCalls += 1;
    return SynchronousFuture(
      const SourceRelinkResult(
        matchedPaths: {},
        matchedImportedFrom: {},
        unresolvedImageIds: {},
        ambiguousImageIds: {},
      ),
    );
  }
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

AnnotationProject projectWithRenderedImage(Directory tempDir) {
  final imageFile = File('${tempDir.path}${Platform.pathSeparator}a.png');
  imageFile.writeAsBytesSync(img.encodePng(fixtureImage(100, 80)));
  return project().copyWith(
    images: [
      project().images.first.copyWith(sourcePath: imageFile.path),
      project().images.last,
    ],
  );
}

double? smallestDownscalePaintTransform(
  WidgetTester tester,
  Finder descendant,
) {
  final transforms = find.ancestor(
    of: descendant,
    matching: find.byType(Transform),
  );
  double? smallest;
  for (final element in transforms.evaluate()) {
    final transform = element.widget as Transform;
    final storage = transform.transform.storage;
    final scale = storage[0] < storage[5] ? storage[0] : storage[5];
    if (scale < 0.99 && (smallest == null || scale < smallest)) {
      smallest = scale;
    }
  }
  return smallest;
}

double badgeTextWidth(String label) {
  const style = TextStyle(fontSize: 11, fontWeight: FontWeight.w700, height: 1);
  final painter = TextPainter(
    text: const TextSpan(style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..text = TextSpan(style: style, text: label);
  painter.layout();
  return painter.width + 8;
}

double textWidth(WidgetTester tester, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(style: style, text: text),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  return painter.width;
}

AnnotationProject project() {
  return AnnotationProject.empty(name: 'demo').copyWith(
    status: ProjectStatus.ready,
    labels: const [
      LabelClass(id: 1, name: 'Person', color: 0xffe64a19, shortcut: '1'),
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
      AnnotatedImage(
        id: 2,
        sourcePath: 'empty.jpg',
        displayName: 'empty.jpg',
        width: 100,
        height: 80,
        status: ImageStatus.needsReview,
      ),
    ],
  );
}

AnnotationProject narrowLabelProject() {
  return project().copyWith(
    images: [
      project().images.first.copyWith(
        width: 400,
        height: 80,
        boxes: const [
          BoundingBox(
            id: 'box-1',
            x: 8,
            y: 10,
            width: 18,
            height: 20,
            status: BoxStatus.labeled,
            labelId: 1,
          ),
          BoundingBox(
            id: 'box-2',
            x: 8,
            y: 10,
            width: 390,
            height: 20,
            status: BoxStatus.labeled,
            labelId: 1,
          ),
        ],
      ),
      project().images.last,
    ],
  );
}

AnnotationProject manyLabeledBoxesProject() {
  final boxes = List<BoundingBox>.generate(
    32,
    (index) => BoundingBox(
      id: 'box-$index',
      x: 4 + (index % 5) * 12,
      y: 4 + (index ~/ 5) * 8,
      width: 10,
      height: 10,
      status: BoxStatus.labeled,
      labelId: 1,
    ),
  );
  return project().copyWith(
    images: [
      project().images.first.copyWith(boxes: boxes),
      project().images.last,
    ],
  );
}

AnnotationProject mixedBoxProject() {
  return project().copyWith(
    images: [
      project().images.first.copyWith(
        boxes: const [
          BoundingBox(
            id: 'box-labeled',
            x: 40,
            y: 10,
            width: 20,
            height: 20,
            status: BoxStatus.labeled,
            labelId: 1,
          ),
          BoundingBox(
            id: 'box-unlabeled',
            x: 10,
            y: 10,
            width: 20,
            height: 20,
            status: BoxStatus.proposal,
          ),
        ],
      ),
      project().images.last,
    ],
  );
}

AnnotationProject overlappingProject() {
  return project().copyWith(
    images: [
      project().images.first.copyWith(
        boxes: const [
          BoundingBox(
            id: 'box-1',
            x: 10,
            y: 10,
            width: 30,
            height: 30,
            status: BoxStatus.proposal,
          ),
          BoundingBox(
            id: 'box-2',
            x: 12,
            y: 12,
            width: 30,
            height: 30,
            status: BoxStatus.proposal,
          ),
        ],
      ),
      project().images.last,
    ],
  );
}

AnnotationProject projectWithError() {
  return project().copyWith(
    images: [
      ...project().images,
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

AnnotationProject projectWithSelectedImage() {
  return project().copyWith(
    labels: createDefaultLabels(),
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
      AnnotatedImage(
        id: 2,
        sourcePath: 'empty.jpg',
        displayName: 'empty.jpg',
        width: 100,
        height: 80,
        status: ImageStatus.needsReview,
      ),
    ],
  );
}
