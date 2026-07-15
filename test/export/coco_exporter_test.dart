import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/export/coco_exporter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CocoExporter', () {
    test(
      'builds COCO JSON with stable category ids and labeled boxes only',
      () {
        final project = _project();

        final coco = CocoExporter.build(project);

        expect(
          coco.keys,
          containsAll([
            'info',
            'licenses',
            'images',
            'annotations',
            'categories',
          ]),
        );
        expect(coco['categories'], [
          {'id': 1, 'name': 'Person', 'supercategory': 'object'},
          {'id': 7, 'name': 'Car', 'supercategory': 'vehicle'},
        ]);
        expect(coco['images'], [
          {'id': 1, 'file_name': 'a.jpg', 'width': 100, 'height': 80},
          {'id': 2, 'file_name': 'b.jpg', 'width': 200, 'height': 120},
        ]);
        expect(coco['annotations'], [
          {
            'id': 1,
            'image_id': 1,
            'category_id': 1,
            'bbox': [10.0, 12.0, 30.0, 40.0],
            'area': 1200.0,
            'iscrowd': 0,
          },
          {
            'id': 2,
            'image_id': 2,
            'category_id': 7,
            'bbox': [5.0, 8.0, 20.0, 10.0],
            'area': 200.0,
            'iscrowd': 0,
          },
        ]);
      },
    );

    test(
      'reports warnings for unconfirmed images, proposals, and error images',
      () {
        final summary = CocoExporter.validate(_project());

        expect(summary.unconfirmedImageCount, 1);
        expect(summary.unlabeledProposalBoxCount, 1);
        expect(summary.errorImageCount, 1);
        expect(summary.hasBlockingErrors, isFalse);
        expect(summary.hasWarnings, isTrue);
      },
    );

    test('can export confirmed images only', () {
      final coco = CocoExporter.build(
        _project(),
        options: const CocoExportOptions(scope: CocoExportScope.confirmedOnly),
      );

      expect(coco['images'], [
        {'id': 1, 'file_name': 'a.jpg', 'width': 100, 'height': 80},
      ]);
      expect((coco['annotations'] as List<Object?>), hasLength(1));
    });

    test('counts white red and gray states and exports white labels only', () {
      final project = _automationStateProject();

      final summary = CocoExporter.validate(project);
      final coco = CocoExporter.build(project);

      expect(summary.autoLabeledBoxCount, 1);
      expect(summary.userLabeledBoxCount, 1);
      expect(summary.reviewRequiredBoxCount, 1);
      expect(summary.unlabeledProposalBoxCount, 1);
      expect((coco['annotations'] as List<Object?>), hasLength(2));
      expect(
        (coco['annotations'] as List<Object?>).cast<Map<String, Object?>>().map(
          (annotation) => annotation['category_id'],
        ),
        [1, 7],
      );
      expect(coco.toString(), isNot(contains('automation')));
      expect(coco.toString(), isNot(contains('reviewReasons')));
    });

    test('invalid labeled boxes create blocking export errors', () {
      final project = _project().copyWith(
        images: [
          AnnotatedImage(
            id: 1,
            sourcePath: 'bad.jpg',
            displayName: 'bad.jpg',
            width: 100,
            height: 80,
            status: ImageStatus.confirmed,
            boxes: const [
              BoundingBox(
                id: 'bad-box',
                x: 95,
                y: 10,
                width: 20,
                height: 20,
                status: BoxStatus.labeled,
                labelId: 1,
              ),
            ],
          ),
        ],
      );

      final summary = CocoExporter.validate(project);

      expect(summary.hasBlockingErrors, isTrue);
      expect(summary.blockingErrors.single, contains('bad-box'));
      expect(
        () => CocoExporter.build(project),
        throwsA(isA<CocoExportException>()),
      );
    });
  });
}

AnnotationProject _automationStateProject() {
  return AnnotationProject.empty(name: 'automation-states').copyWith(
    labels: const [
      LabelClass(id: 1, name: 'Person', color: 0xffe64a19),
      LabelClass(id: 7, name: 'Car', color: 0xff1976d2),
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
            id: 'auto',
            x: 1,
            y: 1,
            width: 10,
            height: 10,
            status: BoxStatus.labeled,
            labelId: 1,
            labelSource: LabelSource.auto,
          ),
          BoundingBox(
            id: 'user',
            x: 20,
            y: 1,
            width: 10,
            height: 10,
            status: BoxStatus.labeled,
            labelId: 7,
            labelSource: LabelSource.user,
          ),
          BoundingBox(
            id: 'review',
            x: 40,
            y: 1,
            width: 10,
            height: 10,
            status: BoxStatus.proposal,
            automation: BoxAutomationMetadata(
              suggestedLabelId: 1,
              reviewReasons: ['classifier_ambiguous'],
              pipelineVersion: 'v1',
              policyVersion: 'policy-v1',
              detectorSha256: 'detector-hash',
            ),
          ),
          BoundingBox(
            id: 'gray',
            x: 60,
            y: 1,
            width: 10,
            height: 10,
            status: BoxStatus.proposal,
          ),
        ],
      ),
    ],
  );
}

AnnotationProject _project() {
  return AnnotationProject.empty(name: 'demo').copyWith(
    labels: const [
      LabelClass(
        id: 7,
        name: 'Car',
        color: 0xff1976d2,
        supercategory: 'vehicle',
      ),
      LabelClass(id: 1, name: 'Person', color: 0xffe64a19),
    ],
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
            id: 'labeled-1',
            x: 10,
            y: 12,
            width: 30,
            height: 40,
            status: BoxStatus.labeled,
            labelId: 1,
          ),
          BoundingBox(
            id: 'proposal-1',
            x: 40,
            y: 20,
            width: 20,
            height: 20,
            status: BoxStatus.proposal,
          ),
        ],
      ),
      AnnotatedImage(
        id: 2,
        sourcePath: 'b.jpg',
        displayName: 'b.jpg',
        width: 200,
        height: 120,
        status: ImageStatus.needsReview,
        boxes: [
          BoundingBox(
            id: 'labeled-2',
            x: 5,
            y: 8,
            width: 20,
            height: 10,
            status: BoxStatus.labeled,
            labelId: 7,
          ),
        ],
      ),
      AnnotatedImage(
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
