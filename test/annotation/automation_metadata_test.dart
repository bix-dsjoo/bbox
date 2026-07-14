import 'package:bbox_labeler/annotation/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('red suggestion is not a real label', () {
    const box = BoundingBox(
      id: 'b1',
      x: 10,
      y: 12,
      width: 80,
      height: 60,
      status: BoxStatus.proposal,
      automation: BoxAutomationMetadata(
        suggestedLabelId: 3,
        candidates: [
          LabelCandidate(labelId: 3, score: 0.72),
          LabelCandidate(labelId: 5, score: 0.24),
        ],
        reviewReasons: ['classifier_ambiguous'],
        pipelineVersion: 'bread-pipeline-v1',
        policyVersion: 'bread-label-policy-v2',
        detectorSha256: 'detector-hash',
        classifierSha256: 'classifier-hash',
      ),
    );

    expect(box.labelId, isNull);
    expect(box.displayLabelId, 3);
    expect(box.requiresLabelReview, isTrue);
    expect(box.isAutoLabeled, isFalse);
  });

  test('automation metadata and image checksum round trip through JSON', () {
    const original = AnnotatedImage(
      id: 1,
      sourcePath: 'bread.jpg',
      displayName: 'bread.jpg',
      width: 100,
      height: 80,
      status: ImageStatus.needsReview,
      contentSha256: 'image-hash',
      boxes: [
        BoundingBox(
          id: 'b1',
          x: 10,
          y: 12,
          width: 30,
          height: 40,
          status: BoxStatus.labeled,
          labelId: 3,
          labelSource: LabelSource.auto,
          automation: BoxAutomationMetadata(
            candidates: [LabelCandidate(labelId: 3, score: 0.98)],
            pipelineVersion: 'bread-pipeline-v1',
            policyVersion: 'bread-label-policy-v2',
            detectorSha256: 'detector-hash',
            classifierSha256: 'classifier-hash',
            embeddingUsed: true,
          ),
        ),
      ],
    );

    final restored = AnnotatedImage.fromJson(original.toJson());
    final box = restored.boxes.single;

    expect(restored.contentSha256, 'image-hash');
    expect(box.labelSource, LabelSource.auto);
    expect(box.isAutoLabeled, isTrue);
    expect(box.automation?.pipelineVersion, 'bread-pipeline-v1');
    expect(box.automation?.policyVersion, 'bread-label-policy-v2');
    expect(box.automation?.embeddingUsed, isTrue);
    expect(box.automation?.candidates.single.labelId, 3);
    expect(box.automation?.candidates.single.score, 0.98);
  });
}
