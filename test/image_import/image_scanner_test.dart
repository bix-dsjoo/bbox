import 'dart:io';

import 'package:bbox_labeler/image_import/image_scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  group('ImageScanner', () {
    test(
      'scanFiles reads supported images and records source metadata',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'bbox_scan_files',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final imageFile = File(
          '${tempDir.path}${Platform.pathSeparator}photo.jpg',
        );
        await imageFile.writeAsBytes(
          img.encodeJpg(img.Image(width: 32, height: 24)),
        );

        final scanned = await ImageScanner.scanFiles([
          imageFile.path,
        ], importedFrom: tempDir.path);

        expect(scanned, hasLength(1));
        expect(scanned.single.sourcePath, imageFile.absolute.path);
        expect(scanned.single.displayName, 'photo.jpg');
        expect(scanned.single.importedFrom, tempDir.path);
        expect(scanned.single.width, 32);
        expect(scanned.single.height, 24);
      },
    );

    test(
      'scanFolder returns absolute source paths from nested folders',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'bbox_scan_folder',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final nested = Directory(
          '${tempDir.path}${Platform.pathSeparator}nested',
        );
        await nested.create();
        final imageFile = File('${nested.path}${Platform.pathSeparator}a.png');
        await imageFile.writeAsBytes(
          img.encodePng(img.Image(width: 12, height: 10)),
        );

        final scanned = await ImageScanner.scanFolder(tempDir.path);

        expect(scanned.single.sourcePath, imageFile.absolute.path);
        expect(scanned.single.displayName, 'a.png');
        expect(scanned.single.importedFrom, tempDir.path);
      },
    );

    test('marks corrupt supported files as scan errors', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'bbox_image_scan_error_test',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final corruptPath = '${tempDir.path}${Platform.pathSeparator}broken.png';
      await File(corruptPath).writeAsString('not really a png');

      final images = await ImageScanner.scanFolder(tempDir.path);

      expect(images.single.displayName, 'broken.png');
      expect(images.single.errorMessage, contains('decode'));
    });
  });
}
