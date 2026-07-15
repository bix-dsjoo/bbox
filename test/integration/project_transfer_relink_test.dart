import 'dart:io';

import 'package:bbox_labeler/annotation/box_display_order.dart';
import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/project/project_library.dart';
import 'package:bbox_labeler/project/project_store.dart';
import 'package:bbox_labeler/project/source_relink_service.dart';
import 'package:bbox_labeler/ui/app_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  test(
    'project handoff relinks sources and preserves export identities',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'bbox-project-transfer-',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final sourceDirectory = await Directory(
        p.join(tempDir.path, 'sender fixtures', 'images'),
      ).create(recursive: true);
      final confirmedSource = await _writePng(
        p.join(sourceDirectory.path, 'confirmed bread.png'),
        width: 64,
        height: 48,
        color: img.ColorRgb8(224, 148, 54),
      );
      final reviewSource = await _writePng(
        p.join(sourceDirectory.path, 'manual review.png'),
        width: 80,
        height: 60,
        color: img.ColorRgb8(102, 71, 43),
      );

      final senderLibrary = ProjectLibrary(
        rootPath: p.join(tempDir.path, 'sender library'),
        clock: () => DateTime.utc(2026, 7, 15, 1),
        idGenerator: (name, timestamp) => 'sender-project',
      );
      final sender = AppController(projectLibrary: senderLibrary);
      addTearDown(sender.dispose);
      await sender.createLibraryProject('Portable handoff');
      sender.loadProject(
        _senderProject(
          projectFilePath: sender.project!.projectFilePath!,
          confirmedSource: confirmedSource,
          reviewSource: reviewSource,
        ),
      );
      await sender.saveProject();

      final senderProject = sender.project!;
      final senderCoco = sender.buildCoco();
      final manualImage = senderProject.images.singleWhere(
        (image) => image.id == 207,
      );
      expect(manualImage.boxes.map((box) => box.id), [
        'manual-visual-2',
        'manual-visual-1',
      ]);
      expect(BoxDisplayOrder.sorted(manualImage).map((box) => box.id), [
        'manual-visual-1',
        'manual-visual-2',
      ]);

      final transferDirectory = Directory(p.join(tempDir.path, 'transfer'));
      final snapshotPath = p.join(
        transferDirectory.path,
        'portable-project.bbox.json',
      );
      await sender.saveProjectSnapshot(snapshotPath);

      final transferEntries = await transferDirectory
          .list(followLinks: false)
          .toList();
      expect(transferEntries.map((entry) => p.normalize(entry.path)), [
        p.normalize(snapshotPath),
      ]);
      expect(
        transferEntries.whereType<File>().map((file) => p.extension(file.path)),
        everyElement('.json'),
      );

      final receiverLibrary = ProjectLibrary(
        rootPath: p.join(tempDir.path, 'receiver library'),
        clock: () => DateTime.utc(2026, 7, 15, 2),
        idGenerator: (name, timestamp) => 'receiver-project',
      );
      final receiver = AppController(projectLibrary: receiverLibrary);
      addTearDown(receiver.dispose);
      await receiver.importProjectSnapshot(snapshotPath);

      expect(receiver.missingSourceCount, 0);
      expect(
        receiver.sourceAvailability.values,
        everyElement(SourceAvailability.available),
      );
      _expectTransferredAnnotations(receiver.project!, senderProject);

      final statusesBeforeMove = {
        for (final image in receiver.project!.images) image.id: image.status,
      };
      final relocatedParent = await Directory(
        p.join(tempDir.path, 'relocated fixtures'),
      ).create();
      final relocatedDirectory = await sourceDirectory.rename(
        p.join(relocatedParent.path, 'images'),
      );
      final relocatedConfirmed = p.join(
        relocatedDirectory.path,
        p.basename(confirmedSource.path),
      );
      final relocatedReview = p.join(
        relocatedDirectory.path,
        p.basename(reviewSource.path),
      );

      await receiver.refreshSourceAvailability();

      expect(receiver.missingSourceCount, 2);
      expect(
        receiver.sourceAvailability.values,
        everyElement(SourceAvailability.missing),
      );
      expect({
        for (final image in receiver.project!.images) image.id: image.status,
      }, statusesBeforeMove);

      final fileRelink = await receiver.relinkSourceFiles([relocatedConfirmed]);

      expect(fileRelink.matchedPaths.keys, {101});
      expect(fileRelink.unresolvedImageIds, {207});
      expect(fileRelink.ambiguousImageIds, isEmpty);
      expect(receiver.missingSourceCount, 1);
      expect({
        for (final image in receiver.project!.images) image.id: image.status,
      }, statusesBeforeMove);

      final folderRelink = await receiver.relinkSourceFolder(
        relocatedDirectory.path,
      );

      expect(folderRelink.matchedPaths.keys, {207});
      expect(folderRelink.unresolvedImageIds, isEmpty);
      expect(folderRelink.ambiguousImageIds, isEmpty);
      expect(receiver.missingSourceCount, 0);
      expect({
        for (final image in receiver.project!.images) image.id: image.status,
      }, statusesBeforeMove);
      expect(
        receiver.project!.images
            .singleWhere((image) => image.id == 101)
            .sourcePath,
        p.normalize(relocatedConfirmed),
      );
      expect(
        receiver.project!.images
            .singleWhere((image) => image.id == 207)
            .sourcePath,
        p.normalize(relocatedReview),
      );

      await receiver.saveProject();

      final reopened = AppController(projectLibrary: receiverLibrary);
      addTearDown(reopened.dispose);
      await reopened.openLibraryProject('receiver-project');

      expect(reopened.missingSourceCount, 0);
      expect({
        for (final image in reopened.project!.images) image.id: image.status,
      }, statusesBeforeMove);
      for (final expectedImage in senderProject.images) {
        final actualImage = reopened.project!.images.singleWhere(
          (image) => image.id == expectedImage.id,
        );
        expect(
          actualImage.boxes.map((box) => box.toJson()).toList(),
          expectedImage.boxes.map((box) => box.toJson()).toList(),
        );
      }
      final receiverCoco = reopened.buildCoco();
      expect(_cocoImageIds(receiverCoco), _cocoImageIds(senderCoco));
      expect(_cocoCategoryIds(receiverCoco), _cocoCategoryIds(senderCoco));
      expect(_cocoBboxes(receiverCoco), _cocoBboxes(senderCoco));

      reopened.selectImage(207);
      final visualOrder = BoxDisplayOrder.sorted(reopened.selectedImage!);
      expect(visualOrder.map((box) => box.id), [
        'manual-visual-1',
        'manual-visual-2',
      ]);
      reopened.selectBox(visualOrder.first.id);
      reopened.assignSelectedBoxLabel(11);

      expect(reopened.selectedBoxId, 'manual-visual-2');
      expect(
        reopened.selectedImage!.boxes
            .singleWhere((box) => box.id == 'manual-visual-1')
            .labelId,
        11,
      );
      await reopened.saveProject();
    },
  );
}

AnnotationProject _senderProject({
  required String projectFilePath,
  required File confirmedSource,
  required File reviewSource,
}) {
  return AnnotationProject(
    schemaVersion: ProjectStore.currentSchemaVersion,
    name: 'Portable handoff',
    projectFilePath: projectFilePath,
    status: ProjectStatus.dirty,
    detectorName: 'integration-fixture',
    labels: const [
      LabelClass(
        id: 5,
        name: 'Pastry',
        color: 0xff7e57c2,
        shortcut: '1',
        supercategory: 'baked-good',
      ),
      LabelClass(
        id: 11,
        name: 'Bread',
        color: 0xffff9800,
        shortcut: '2',
        supercategory: 'baked-good',
      ),
    ],
    images: [
      AnnotatedImage(
        id: 101,
        sourcePath: confirmedSource.absolute.path,
        displayName: p.basename(confirmedSource.path),
        importedFrom: confirmedSource.parent.absolute.path,
        width: 64,
        height: 48,
        status: ImageStatus.confirmed,
        contentSha256: sha256
            .convert(confirmedSource.readAsBytesSync())
            .toString(),
        boxes: const [
          BoundingBox(
            id: 'confirmed-auto-box',
            x: 4,
            y: 5,
            width: 20,
            height: 18,
            status: BoxStatus.labeled,
            labelId: 11,
            labelSource: LabelSource.auto,
            confidence: 0.97,
            automation: BoxAutomationMetadata(
              suggestedLabelId: 11,
              candidates: [
                LabelCandidate(labelId: 11, score: 0.97),
                LabelCandidate(labelId: 5, score: 0.03),
              ],
              pipelineVersion: 'portable-pipeline-v3',
              policyVersion: 'portable-policy-v2',
              detectorSha256: 'detector-sha-256',
              classifierSha256: 'classifier-sha-256',
              verifierSha256: 'verifier-sha-256',
              embeddingUsed: true,
            ),
          ),
        ],
      ),
      AnnotatedImage(
        id: 207,
        sourcePath: reviewSource.absolute.path,
        displayName: p.basename(reviewSource.path),
        importedFrom: reviewSource.parent.absolute.path,
        width: 80,
        height: 60,
        status: ImageStatus.needsReview,
        contentSha256: sha256
            .convert(reviewSource.readAsBytesSync())
            .toString(),
        boxes: const [
          BoundingBox(
            id: 'manual-visual-2',
            x: 48,
            y: 34,
            width: 20,
            height: 15,
            status: BoxStatus.proposal,
          ),
          BoundingBox(
            id: 'manual-visual-1',
            x: 6,
            y: 8,
            width: 18,
            height: 14,
            status: BoxStatus.proposal,
          ),
        ],
      ),
    ],
  );
}

void _expectTransferredAnnotations(
  AnnotationProject actual,
  AnnotationProject expected,
) {
  expect(
    actual.labels.map((label) => label.toJson()).toList(),
    expected.labels.map((label) => label.toJson()).toList(),
  );
  expect(
    actual.images.map((image) => image.toJson()).toList(),
    expected.images.map((image) => image.toJson()).toList(),
  );
}

List<int> _cocoImageIds(Map<String, Object?> coco) {
  return (coco['images']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .map((image) => image['id']! as int)
      .toList();
}

List<int> _cocoCategoryIds(Map<String, Object?> coco) {
  return (coco['categories']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .map((category) => category['id']! as int)
      .toList();
}

List<Object?> _cocoBboxes(Map<String, Object?> coco) {
  return (coco['annotations']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .map((annotation) => annotation['bbox'])
      .toList();
}

Future<File> _writePng(
  String path, {
  required int width,
  required int height,
  required img.Color color,
}) async {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: color);
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(img.encodePng(image), flush: true);
  return file;
}
