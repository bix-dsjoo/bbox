import 'package:bbox_labeler/annotation/annotation_rules.dart';
import 'package:bbox_labeler/annotation/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BoundingBox', () {
    test('calculates area and validates positive in-bounds boxes', () {
      final box = BoundingBox(
        id: 'box-1',
        x: 10,
        y: 12,
        width: 30,
        height: 40,
        status: BoxStatus.labeled,
        labelId: 1,
      );

      expect(box.area, 1200);
      expect(
        AnnotationRules.isBoxValid(box, imageWidth: 100, imageHeight: 80),
        isTrue,
      );
    });

    test('rejects zero size and out-of-bounds boxes', () {
      final zeroWidth = BoundingBox(
        id: 'box-1',
        x: 0,
        y: 0,
        width: 0,
        height: 10,
        status: BoxStatus.proposal,
      );
      final outside = BoundingBox(
        id: 'box-2',
        x: 90,
        y: 70,
        width: 20,
        height: 20,
        status: BoxStatus.labeled,
        labelId: 1,
      );

      expect(
        AnnotationRules.isBoxValid(zeroWidth, imageWidth: 100, imageHeight: 80),
        isFalse,
      );
      expect(
        AnnotationRules.isBoxValid(outside, imageWidth: 100, imageHeight: 80),
        isFalse,
      );
    });

    test('clamps boxes to image bounds while preserving minimum size', () {
      final box = BoundingBox(
        id: 'box-1',
        x: -12,
        y: 75,
        width: 150,
        height: 1,
        status: BoxStatus.proposal,
      );

      final clamped = AnnotationRules.clampBox(
        box,
        imageWidth: 100,
        imageHeight: 80,
        minSize: 5,
      );

      expect(clamped.x, 0);
      expect(clamped.y, 75);
      expect(clamped.width, 100);
      expect(clamped.height, 5);
      expect(clamped.y + clamped.height, 80);
    });
  });

  group('labels', () {
    test('creates labels with unique case-insensitive names', () {
      final project = AnnotationProject.empty(name: 'demo');
      final withPerson = AnnotationRules.addLabel(
        project,
        name: 'Person',
        color: 0xffdd3355,
      );

      expect(withPerson.labels.single.name, 'Person');
      expect(
        () => AnnotationRules.addLabel(
          withPerson,
          name: ' person ',
          color: 0xff00aa99,
        ),
        throwsA(isA<DuplicateLabelException>()),
      );
    });

    test('adds labels with normalized shortcuts', () {
      final project = AnnotationProject.empty(name: 'demo');

      final updated = AnnotationRules.addLabel(
        project,
        name: 'Bread',
        color: 0xff123456,
        shortcut: 'Q',
      );

      expect(updated.labels.single.name, 'Bread');
      expect(updated.labels.single.shortcut, 'q');
    });

    test('moving a shortcut clears it from the previous label', () {
      final project = AnnotationProject.empty(name: 'demo').copyWith(
        labels: const [
          LabelClass(id: 1, name: 'Bread', color: 0xff111111, shortcut: '1'),
          LabelClass(id: 2, name: 'Cream', color: 0xff222222),
        ],
      );

      final updated = AnnotationRules.updateLabel(
        project,
        labelId: 2,
        name: 'Cream',
        color: 0xff222222,
        shortcut: '1',
      );

      expect(updated.labels.first.shortcut, isNull);
      expect(updated.labels.last.shortcut, '1');
    });

    test('rejects missing labels without moving shortcuts', () {
      final project = AnnotationProject.empty(name: 'demo').copyWith(
        labels: const [
          LabelClass(id: 1, name: 'Bread', color: 0xff111111, shortcut: '1'),
          LabelClass(id: 2, name: 'Cream', color: 0xff222222),
        ],
      );

      expect(
        () => AnnotationRules.updateLabel(
          project,
          labelId: 99,
          name: 'Missing',
          color: 0xff333333,
          shortcut: '1',
        ),
        throwsA(
          isA<AnnotationValidationException>().having(
            (error) => error.message,
            'message',
            'Label not found: 99',
          ),
        ),
      );
      expect(project.labels.first.shortcut, '1');
      expect(project.labels.last.shortcut, isNull);
    });

    test('rejects shortcuts outside the quick-label set', () {
      final project = AnnotationProject.empty(name: 'demo');

      expect(
        () => AnnotationRules.addLabel(
          project,
          name: 'Bread',
          color: 0xff123456,
          shortcut: 'a',
        ),
        throwsA(isA<AnnotationValidationException>()),
      );
    });

    test('renames labels consistently and blocks duplicate names', () {
      final project = AnnotationProject.empty(name: 'demo')
          .withLabel(LabelClass(id: 1, name: 'Person', color: 0xffdd3355))
          .withLabel(LabelClass(id: 2, name: 'Car', color: 0xff00aa99));

      final renamed = AnnotationRules.renameLabel(
        project,
        labelId: 1,
        name: 'Human',
      );
      expect(renamed.labels.first.name, 'Human');

      expect(
        () => AnnotationRules.renameLabel(project, labelId: 1, name: 'car'),
        throwsA(isA<DuplicateLabelException>()),
      );
    });

    test('prevents deleting labels still used by labeled boxes', () {
      final image = AnnotatedImage(
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
            width: 10,
            height: 10,
            status: BoxStatus.labeled,
            labelId: 1,
          ),
        ],
      );
      final project = AnnotationProject.empty(name: 'demo')
          .withLabel(LabelClass(id: 1, name: 'Person', color: 0xffdd3355))
          .copyWith(images: [image]);

      expect(
        () => AnnotationRules.deleteLabel(project, labelId: 1),
        throwsA(isA<LabelInUseException>()),
      );
    });
  });

  group('image confirmation', () {
    test('proposal boxes block confirmation until they are labeled', () {
      final image = AnnotatedImage(
        id: 1,
        sourcePath: 'a.jpg',
        displayName: 'a.jpg',
        width: 100,
        height: 80,
        status: ImageStatus.needsReview,
        boxes: [
          BoundingBox(
            id: 'proposal-1',
            x: 10,
            y: 10,
            width: 20,
            height: 20,
            status: BoxStatus.proposal,
          ),
        ],
      );

      expect(AnnotationRules.canConfirm(image), isFalse);
    });

    test('labeled valid boxes allow confirmation', () {
      final image = AnnotatedImage(
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
      );

      expect(AnnotationRules.canConfirm(image), isTrue);
      expect(AnnotationRules.confirmImage(image).status, ImageStatus.confirmed);
    });

    test('images with no boxes can be confirmed as object none', () {
      final image = AnnotatedImage(
        id: 1,
        sourcePath: 'empty.jpg',
        displayName: 'empty.jpg',
        width: 100,
        height: 80,
        status: ImageStatus.needsReview,
      );

      expect(AnnotationRules.canConfirm(image), isTrue);
    });

    test('assigning a label changes a proposal into a labeled box', () {
      final image = AnnotatedImage(
        id: 1,
        sourcePath: 'a.jpg',
        displayName: 'a.jpg',
        width: 100,
        height: 80,
        status: ImageStatus.needsReview,
        boxes: [
          BoundingBox(
            id: 'proposal-1',
            x: 10,
            y: 10,
            width: 20,
            height: 20,
            status: BoxStatus.proposal,
          ),
        ],
      );

      final updated = AnnotationRules.assignLabel(
        image,
        boxId: 'proposal-1',
        labelId: 7,
      );

      expect(updated.boxes.single.status, BoxStatus.labeled);
      expect(updated.boxes.single.labelId, 7);
      expect(updated.boxes.single.labelSource, LabelSource.user);
    });

    test('accepting a suggestion creates a user-approved real label', () {
      const image = AnnotatedImage(
        id: 1,
        sourcePath: 'a.jpg',
        displayName: 'a.jpg',
        width: 100,
        height: 80,
        status: ImageStatus.needsReview,
        boxes: [
          BoundingBox(
            id: 'review-1',
            x: 10,
            y: 10,
            width: 20,
            height: 20,
            status: BoxStatus.proposal,
            automation: BoxAutomationMetadata(
              suggestedLabelId: 3,
              candidates: [LabelCandidate(labelId: 3, score: 0.7)],
              reviewReasons: ['classifier_ambiguous'],
              pipelineVersion: 'bread-pipeline-v1',
              policyVersion: 'bread-label-policy-v2',
              detectorSha256: 'detector-hash',
            ),
          ),
        ],
      );

      final updated = AnnotationRules.acceptSuggestedLabel(
        image,
        boxId: 'review-1',
      );
      final box = updated.boxes.single;

      expect(box.status, BoxStatus.labeled);
      expect(box.labelId, 3);
      expect(box.labelSource, LabelSource.user);
      expect(box.requiresLabelReview, isFalse);
      expect(box.automation?.suggestedLabelId, isNull);
      expect(box.automation?.reviewReasons, isEmpty);
    });
  });
}
