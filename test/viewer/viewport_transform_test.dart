import 'package:bbox_labeler/viewer/viewport_transform.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ViewportTransform', () {
    test('fits image into viewport and centers unused space', () {
      final transform = ViewportTransform.fit(
        imageSize: const Size(400, 200),
        viewportSize: const Size(1000, 600),
      );

      expect(transform.scale, 2.5);
      expect(transform.imageOrigin, const Offset(0, 50));
      expect(
        transform.originalToScreen(const Offset(200, 100)),
        const Offset(500, 300),
      );
      expect(
        transform.screenToOriginal(const Offset(500, 300)),
        const Offset(200, 100),
      );
    });

    test('applies zoom and pan without changing original coordinates', () {
      final transform = ViewportTransform.fit(
        imageSize: const Size(400, 200),
        viewportSize: const Size(1000, 600),
        zoom: 2,
        pan: const Offset(10, -20),
      );

      expect(transform.scale, 5);
      expect(transform.imageOrigin, const Offset(-490, -220));
      expect(
        transform.originalToScreen(const Offset(100, 50)),
        const Offset(10, 30),
      );
      expect(
        transform.screenToOriginal(const Offset(10, 30)),
        const Offset(100, 50),
      );
    });

    test('converts original and display rectangles round trip', () {
      final transform = ViewportTransform.fit(
        imageSize: const Size(200, 100),
        viewportSize: const Size(400, 400),
      );
      const original = Rect.fromLTWH(25, 10, 50, 20);

      final screen = transform.originalRectToScreen(original);

      expect(screen, const Rect.fromLTWH(50, 120, 100, 40));
      expect(transform.screenRectToOriginal(screen), original);
    });

    test('clamps display points to original image bounds', () {
      final transform = ViewportTransform.fit(
        imageSize: const Size(200, 100),
        viewportSize: const Size(400, 400),
      );

      expect(
        transform.clampOriginalPoint(const Offset(-10, 150)),
        const Offset(0, 100),
      );
      expect(
        transform.clampOriginalPoint(const Offset(210, -2)),
        const Offset(200, 0),
      );
    });

    test('fits portrait image with symmetric horizontal padding', () {
      final transform = ViewportTransform.fitInside(
        imageSize: const Size(3024, 4032),
        viewportSize: const Size(600, 600),
        paddingFactor: 0.92,
      );

      expect(transform.scale, closeTo(0.13690476, 0.000001));
      expect(transform.renderedImageSize.width, closeTo(414, 0.5));
      expect(transform.renderedImageSize.height, closeTo(552, 0.5));
      expect(transform.imageOrigin.dx, closeTo(93, 0.5));
      expect(transform.imageOrigin.dy, closeTo(24, 0.5));
    });

    test('converts overlay rectangles through the same origin and scale', () {
      final transform = ViewportTransform.fitInside(
        imageSize: const Size(3024, 4032),
        viewportSize: const Size(600, 600),
        paddingFactor: 0.92,
      );

      final original = Rect.fromLTWH(100, 200, 500, 600);
      final screen = transform.originalRectToScreen(original);
      final restored = transform.screenRectToOriginal(screen);

      expect(restored.left, closeTo(original.left, 0.0001));
      expect(restored.top, closeTo(original.top, 0.0001));
      expect(restored.width, closeTo(original.width, 0.0001));
      expect(restored.height, closeTo(original.height, 0.0001));
    });
  });
}
