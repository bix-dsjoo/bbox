import 'package:bbox_labeler/ui/image_import_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ImageImportPicker helpers', () {
    test('image filter allows supported image extensions', () {
      final filter = imageFileFilterSpecification;

      expect(filter, {'이미지 파일 (*.jpg;*.jpeg;*.png)': '*.jpg;*.jpeg;*.png'});
    });

    test('normalizes picked file paths from XFile-like paths', () {
      final paths = normalizePickedImagePaths([
        'C:\\images\\b.png',
        'C:\\images\\a.jpg',
        '',
      ]);

      expect(paths, ['C:\\images\\b.png', 'C:\\images\\a.jpg']);
    });
  });
}
