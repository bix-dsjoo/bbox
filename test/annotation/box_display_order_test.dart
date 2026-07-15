import 'package:bbox_labeler/annotation/box_display_order.dart';
import 'package:bbox_labeler/annotation/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('orders rows top-to-bottom and boxes left-to-right', () {
    final image = _image(const [
      BoundingBox(
        id: 'bottom-left',
        x: 8,
        y: 60,
        width: 20,
        height: 20,
        status: BoxStatus.proposal,
      ),
      BoundingBox(
        id: 'top-right',
        x: 70,
        y: 12,
        width: 20,
        height: 20,
        status: BoxStatus.proposal,
      ),
      BoundingBox(
        id: 'top-left',
        x: 10,
        y: 10,
        width: 20,
        height: 20,
        status: BoxStatus.proposal,
      ),
    ]);

    expect(BoxDisplayOrder.sorted(image).map((box) => box.id), [
      'top-left',
      'top-right',
      'bottom-left',
    ]);
    expect(BoxDisplayOrder.numbers(image), {
      'top-left': 1,
      'top-right': 2,
      'bottom-left': 3,
    });
  });

  test('uses a fixed row anchor so chained y offsets do not merge rows', () {
    final image = _image(const [
      BoundingBox(
        id: 'a',
        x: 60,
        y: 0,
        width: 20,
        height: 20,
        status: BoxStatus.proposal,
      ),
      BoundingBox(
        id: 'b',
        x: 40,
        y: 9,
        width: 20,
        height: 20,
        status: BoxStatus.proposal,
      ),
      BoundingBox(
        id: 'c',
        x: 20,
        y: 18,
        width: 20,
        height: 20,
        status: BoxStatus.proposal,
      ),
    ]);

    expect(BoxDisplayOrder.sorted(image).map((box) => box.id), ['b', 'a', 'c']);
  });
}

AnnotatedImage _image(List<BoundingBox> boxes) => AnnotatedImage(
  id: 1,
  sourcePath: 'a.jpg',
  displayName: 'a.jpg',
  width: 200,
  height: 100,
  status: ImageStatus.needsReview,
  boxes: boxes,
);
