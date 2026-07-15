import 'dart:io';

import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/detector/detector.dart';
import 'package:bbox_labeler/export/coco_exporter.dart';
import 'package:bbox_labeler/project/project_store.dart';
import 'package:bbox_labeler/ui/app_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_auto_box_runtime.dart';

void main() {
  test(
    'automatic labels preserve review save undo and export invariants',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'bbox_auto_label_flow',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final projectPath =
          '${tempDir.path}${Platform.pathSeparator}project.bbox.json';
      final runtime = FakeAutoBoxRuntime(
        detectionResult: const DetectionResult(
          detectorName: 'integration-auto-label',
          imageSha256: 'image-hash',
          pipelineVersion: 'pipeline-v1',
          policyVersion: 'policy-v1',
          detectorSha256: 'detector-hash',
          boxes: [
            BoundingBox(
              id: 'accepted-box',
              x: 10,
              y: 10,
              width: 20,
              height: 20,
              status: BoxStatus.labeled,
              labelId: 1,
              labelSource: LabelSource.auto,
              automation: BoxAutomationMetadata(
                candidates: [LabelCandidate(labelId: 1, score: 0.96)],
                pipelineVersion: 'pipeline-v1',
                policyVersion: 'policy-v1',
                detectorSha256: 'detector-hash',
              ),
            ),
            BoundingBox(
              id: 'review-box',
              x: 40,
              y: 10,
              width: 20,
              height: 20,
              status: BoxStatus.proposal,
              automation: BoxAutomationMetadata(
                suggestedLabelId: 1,
                candidates: [LabelCandidate(labelId: 1, score: 0.58)],
                reviewReasons: ['classifier_ambiguous'],
                pipelineVersion: 'pipeline-v1',
                policyVersion: 'policy-v1',
                detectorSha256: 'detector-hash',
              ),
            ),
          ],
        ),
      );
      final controller = AppController(autoBoxRuntime: runtime)
        ..loadProject(_project());
      addTearDown(controller.dispose);

      await controller.detectSelectedImage();

      expect(controller.selectedImage!.visibleBoxes, hasLength(2));
      expect(
        controller.selectedImage!.visibleBoxes.first.isAutoLabeled,
        isTrue,
      );
      expect(
        controller.selectedImage!.visibleBoxes.last.requiresLabelReview,
        isTrue,
      );
      expect(controller.canConfirmSelectedImage, isFalse);

      controller.selectBox('review-box');
      controller.acceptSelectedSuggestedLabel();

      expect(controller.selectedBox!.labelSource, LabelSource.user);
      expect(controller.canConfirmSelectedImage, isTrue);
      controller.confirmSelectedImage();
      expect(controller.selectedImage!.status, ImageStatus.confirmed);

      await controller.saveProject(projectPath);
      final restored = await ProjectStore.load(projectPath);
      expect(restored.images.single.labeledBoxCount, 2);
      final summary = CocoExporter.validate(restored);
      expect(summary.autoLabeledBoxCount, 1);
      expect(summary.userLabeledBoxCount, 1);
      expect(summary.reviewRequiredBoxCount, 0);
      expect(
        (CocoExporter.build(restored)['annotations'] as List<Object?>),
        hasLength(2),
      );

      controller.undo();
      expect(controller.selectedImage!.status, ImageStatus.needsReview);
      expect(controller.selectedImage!.labeledBoxCount, 2);
    },
  );
}

AnnotationProject _project() {
  return AnnotationProject.empty(name: 'auto-label-flow').copyWith(
    labels: const [LabelClass(id: 1, name: 'Bread', color: 0xffe64a19)],
    images: const [
      AnnotatedImage(
        id: 1,
        sourcePath: 'a.jpg',
        displayName: 'a.jpg',
        width: 100,
        height: 80,
        status: ImageStatus.needsReview,
      ),
    ],
  );
}
