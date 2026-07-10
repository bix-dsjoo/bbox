import 'dart:io';

import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/detector/detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  group('DarkBackgroundDetector', () {
    test(
      'returns proposal boxes for bright objects on a dark background',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'bbox_dark_detector_test',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final imagePath = '${tempDir.path}${Platform.pathSeparator}bread.png';
        final fixture = img.Image(width: 100, height: 80);
        img.fill(fixture, color: img.ColorRgb8(10, 12, 14));
        _fillRect(fixture, x: 10, y: 12, width: 20, height: 18);
        _fillRect(fixture, x: 62, y: 38, width: 24, height: 22);
        await File(imagePath).writeAsBytes(img.encodePng(fixture));

        const image = AnnotatedImage(
          id: 7,
          sourcePath: 'bread.png',
          displayName: 'bread.png',
          width: 100,
          height: 80,
          status: ImageStatus.detecting,
        );

        final result = await const DarkBackgroundDetector().detect(
          image,
          imagePath: imagePath,
        );

        expect(result.detectorName, 'dark-background-contour');
        expect(result.errorMessage, isNull);
        expect(result.boxes, hasLength(2));
        expect(
          result.boxes.every((box) => box.status == BoxStatus.proposal),
          isTrue,
        );
        expect(result.boxes.every((box) => box.labelId == null), isTrue);
        expect(result.boxes.map((box) => box.id), ['det-7-1', 'det-7-2']);
        expect(result.boxes[0].x, closeTo(8, 1));
        expect(result.boxes[0].y, closeTo(10, 1));
        expect(result.boxes[0].width, closeTo(24, 2));
        expect(result.boxes[0].height, closeTo(22, 2));
        expect(result.boxes[1].x, closeTo(60, 1));
        expect(result.boxes[1].y, closeTo(36, 1));
        expect(result.boxes[1].width, closeTo(28, 2));
        expect(result.boxes[1].height, closeTo(26, 2));
      },
    );

    test(
      'splits large connected foreground blobs into object proposals',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'bbox_dark_detector_split_test',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final imagePath =
            '${tempDir.path}${Platform.pathSeparator}touching.png';
        final fixture = img.Image(width: 140, height: 90);
        img.fill(fixture, color: img.ColorRgb8(10, 12, 14));
        _fillCircle(fixture, centerX: 44, centerY: 45, radius: 24);
        _fillCircle(fixture, centerX: 94, centerY: 45, radius: 24);
        _fillRect(fixture, x: 55, y: 39, width: 28, height: 12);
        await File(imagePath).writeAsBytes(img.encodePng(fixture));

        const image = AnnotatedImage(
          id: 8,
          sourcePath: 'touching.png',
          displayName: 'touching.png',
          width: 140,
          height: 90,
          status: ImageStatus.detecting,
        );

        final result = await const DarkBackgroundDetector().detect(
          image,
          imagePath: imagePath,
        );

        expect(result.boxes, hasLength(2));
        expect(result.boxes[0].x, lessThan(35));
        expect(result.boxes[0].x + result.boxes[0].width, lessThan(85));
        expect(result.boxes[1].x, greaterThan(55));
        expect(result.boxes[1].x + result.boxes[1].width, greaterThan(105));
      },
    );

    test(
      'clamps DetectionOptions maxProposals and lets options override constructor defaults',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'bbox_dark_detector_options_test',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final imagePath = '${tempDir.path}${Platform.pathSeparator}many.png';
        final fixture = img.Image(width: 180, height: 120);
        img.fill(fixture, color: img.ColorRgb8(10, 12, 14));
        _fillRect(fixture, x: 8, y: 10, width: 18, height: 16);
        _fillRect(fixture, x: 42, y: 14, width: 18, height: 16);
        _fillRect(fixture, x: 76, y: 18, width: 18, height: 16);
        _fillRect(fixture, x: 110, y: 22, width: 18, height: 16);
        await File(imagePath).writeAsBytes(img.encodePng(fixture));

        const image = AnnotatedImage(
          id: 9,
          sourcePath: 'many.png',
          displayName: 'many.png',
          width: 180,
          height: 120,
          status: ImageStatus.detecting,
        );

        const detector = DarkBackgroundDetector(maxProposals: 2);

        final zeroLimited = await detector.detect(
          image,
          imagePath: imagePath,
          options: const DetectionOptions(maxProposals: 0),
        );
        final expanded = await detector.detect(
          image,
          imagePath: imagePath,
          options: const DetectionOptions(maxProposals: 4),
        );

        expect(zeroLimited.errorMessage, isNull);
        expect(zeroLimited.boxes, hasLength(1));
        expect(expanded.errorMessage, isNull);
        expect(expanded.boxes, hasLength(4));
      },
    );
  });
}

void _fillRect(
  img.Image image, {
  required int x,
  required int y,
  required int width,
  required int height,
}) {
  for (var yy = y; yy < y + height; yy++) {
    for (var xx = x; xx < x + width; xx++) {
      image.setPixel(xx, yy, img.ColorRgb8(230, 170, 70));
    }
  }
}

void _fillCircle(
  img.Image image, {
  required int centerX,
  required int centerY,
  required int radius,
}) {
  final radiusSquared = radius * radius;
  for (var y = centerY - radius; y <= centerY + radius; y++) {
    for (var x = centerX - radius; x <= centerX + radius; x++) {
      if (x < 0 || y < 0 || x >= image.width || y >= image.height) {
        continue;
      }
      final dx = x - centerX;
      final dy = y - centerY;
      if (dx * dx + dy * dy <= radiusSquared) {
        image.setPixel(x, y, img.ColorRgb8(230, 170, 70));
      }
    }
  }
}
