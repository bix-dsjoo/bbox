import 'package:filepicker_windows/filepicker_windows.dart';

abstract class ImageImportPicker {
  const ImageImportPicker();

  Future<String?> pickImageFolder();

  Future<List<String>> pickImageFiles();
}

const imageFileFilterSpecification = {
  '이미지 파일 (*.jpg;*.jpeg;*.png)': '*.jpg;*.jpeg;*.png',
};

List<String> normalizePickedImagePaths(List<String> paths) {
  return [
    for (final path in paths)
      if (path.trim().isNotEmpty) path.trim(),
  ];
}

class WindowsImageImportPicker extends ImageImportPicker {
  const WindowsImageImportPicker();

  @override
  Future<String?> pickImageFolder() async {
    final picker = DirectoryPicker()
      ..title = '이미지 폴더 선택'
      ..forceFileSystemItems = true;
    return picker.getDirectory()?.path;
  }

  @override
  Future<List<String>> pickImageFiles() async {
    final picker = OpenFilePicker()
      ..title = '이미지 파일 선택'
      ..filterSpecification = imageFileFilterSpecification
      ..defaultFilterIndex = 0
      ..defaultExtension = 'jpg'
      ..fileMustExist = true
      ..forceFileSystemItems = true;
    final files = picker.getFiles();
    return normalizePickedImagePaths([for (final file in files) file.path]);
  }
}
