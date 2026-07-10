import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

class ScannedImage {
  const ScannedImage({
    required this.sourcePath,
    required this.displayName,
    this.importedFrom,
    required this.width,
    required this.height,
    this.errorMessage,
  });

  final String sourcePath;
  final String displayName;
  final String? importedFrom;
  final int width;
  final int height;
  final String? errorMessage;

  bool get hasError => errorMessage != null;
}

class ImageScanner {
  const ImageScanner._();

  static const Set<String> supportedExtensions = {'.jpg', '.jpeg', '.png'};

  static Future<List<ScannedImage>> scanFiles(
    List<String> filePaths, {
    String? importedFrom,
  }) async {
    final files = filePaths
        .map((path) => File(path).absolute)
        .where((file) => isSupportedImagePath(file.path))
        .toList();
    files.sort(
      (a, b) => p
          .normalize(a.path)
          .toLowerCase()
          .compareTo(p.normalize(b.path).toLowerCase()),
    );
    final images = <ScannedImage>[];
    for (final file in files) {
      images.add(await _scanFile(file, importedFrom: importedFrom));
    }
    return images;
  }

  static Future<List<ScannedImage>> scanFolder(String folderPath) async {
    final root = Directory(folderPath);
    if (!await root.exists()) {
      throw FileSystemException('Image folder does not exist.', folderPath);
    }

    final files = await root
        .list(recursive: true, followLinks: false)
        .where((entity) => entity is File && isSupportedImagePath(entity.path))
        .cast<File>()
        .toList();
    return scanFiles(
      files.map((file) => file.path).toList(),
      importedFrom: root.path,
    );
  }

  static bool isSupportedImagePath(String filePath) {
    return supportedExtensions.contains(p.extension(filePath).toLowerCase());
  }

  static Future<ScannedImage> _scanFile(
    File file, {
    String? importedFrom,
  }) async {
    try {
      final bytes = await file.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        return ScannedImage(
          sourcePath: file.absolute.path,
          displayName: p.basename(file.path),
          importedFrom: importedFrom,
          width: 0,
          height: 0,
          errorMessage: 'decode failed',
        );
      }
      return ScannedImage(
        sourcePath: file.absolute.path,
        displayName: p.basename(file.path),
        importedFrom: importedFrom,
        width: decoded.width,
        height: decoded.height,
      );
    } catch (error) {
      return ScannedImage(
        sourcePath: file.absolute.path,
        displayName: p.basename(file.path),
        importedFrom: importedFrom,
        width: 0,
        height: 0,
        errorMessage: 'decode failed: $error',
      );
    }
  }
}
