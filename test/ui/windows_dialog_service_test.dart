import 'package:bbox_labeler/ui/windows_dialog_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WindowsDialogService', () {
    test('uses Korean-first dialog copy and filters', () {
      expect(WindowsDialogService.folderPickerTitle, '폴더 선택');
      expect(WindowsDialogService.imageFilePickerTitle, '이미지 파일 선택');
      expect(
        WindowsDialogService.imageFileDialogFilter,
        '이미지 파일 (*.jpg;*.jpeg;*.png)|*.jpg;*.jpeg;*.png|모든 파일 (*.*)|*.*',
      );
      expect(
        WindowsDialogService.saveDialogFilter,
        'COCO JSON (*.json)|*.json|모든 파일 (*.*)|*.*',
      );
      expect(
        WindowsDialogService.debugBuildPickImageFilesScript(),
        contains("\$dialog.Title = '이미지 파일 선택'"),
      );
      expect(
        WindowsDialogService.debugBuildPickImageFilesScript(),
        contains("모든 파일 (*.*)"),
      );
      expect(
        WindowsDialogService.debugBuildPickImageFilesScript(title: '사용자 지정'),
        contains("\$dialog.Title = '사용자 지정'"),
      );
    });

    test('parses multiple selected file paths from dialog output', () {
      final paths = WindowsDialogService.debugParseImageFileOutput(
        'C:\\images\\a.jpg`nC:\\images\\b.png\r\nC:\\images\\c.jpeg',
      );

      expect(paths, [
        'C:\\images\\a.jpg',
        'C:\\images\\b.png',
        'C:\\images\\c.jpeg',
      ]);
    });
  });
}
