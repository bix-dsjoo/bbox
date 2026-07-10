import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/detector/detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DummyDetector', () {
    test(
      'returns deterministic proposal boxes within original image bounds',
      () async {
        const image = AnnotatedImage(
          id: 3,
          sourcePath: 'photo.jpg',
          displayName: 'photo.jpg',
          width: 200,
          height: 100,
          status: ImageStatus.detecting,
        );

        final result = await const DummyDetector().detect(image);

        expect(result.detectorName, 'dummy-algorithm');
        expect(result.boxes, hasLength(1));
        final box = result.boxes.single;
        expect(box.id, 'det-3-1');
        expect(box.status, BoxStatus.proposal);
        expect(box.labelId, isNull);
        expect(box.confidence, 0.35);
        expect(box.x, 50);
        expect(box.y, 25);
        expect(box.width, 100);
        expect(box.height, 50);
      },
    );

    test('returns no proposals for tiny images', () async {
      const image = AnnotatedImage(
        id: 4,
        sourcePath: 'tiny.jpg',
        displayName: 'tiny.jpg',
        width: 12,
        height: 12,
        status: ImageStatus.detecting,
      );

      final result = await const DummyDetector().detect(image);

      expect(result.boxes, isEmpty);
    });

    test(
      'clamps invalid max proposal options into the supported range',
      () async {
        const image = AnnotatedImage(
          id: 8,
          sourcePath: 'photo.jpg',
          displayName: 'photo.jpg',
          width: 200,
          height: 100,
          status: ImageStatus.detecting,
        );

        final result = await const DummyDetector().detect(
          image,
          options: const DetectionOptions(maxProposals: 0),
        );

        expect(result.boxes, hasLength(1));
      },
    );

    test('clamps max proposal options above the supported range', () async {
      const image = AnnotatedImage(
        id: 9,
        sourcePath: 'photo.jpg',
        displayName: 'photo.jpg',
        width: 200,
        height: 100,
        status: ImageStatus.detecting,
      );

      final result = await const DummyDetector().detect(
        image,
        options: const DetectionOptions(maxProposals: 999),
      );

      expect(result.boxes, hasLength(1));
    });
  });
}
