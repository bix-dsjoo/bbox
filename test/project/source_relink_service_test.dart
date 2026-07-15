import 'dart:io';

import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/project/source_relink_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  const service = SourceRelinkService();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('bbox-source-relink-');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'availability inspects absolute sources without mutating status',
    () async {
      final existing = await _writePng(
        p.join(tempDir.path, 'existing.png'),
        width: 32,
        height: 24,
      );
      final missingPath = p.join(tempDir.path, 'missing.png');
      final availableImage = _image(
        id: 1,
        sourcePath: existing.absolute.path,
        status: ImageStatus.needsReview,
      );
      final missingImage = _image(
        id: 2,
        sourcePath: missingPath,
        status: ImageStatus.confirmed,
      );

      final result = await service.inspectSources([
        availableImage,
        missingImage,
      ]);

      expect(result, {
        availableImage.id: SourceAvailability.available,
        missingImage.id: SourceAvailability.missing,
      });
      expect(availableImage.status, ImageStatus.needsReview);
      expect(missingImage.status, ImageStatus.confirmed);
    },
  );

  test('file relink matches a unique filename and dimensions', () async {
    final candidate = await _writePng(
      p.join(tempDir.path, 'bread.png'),
      width: 32,
      height: 24,
    );
    final image = _image(sourcePath: r'C:\old\bread.png');

    final result = await service.relinkFiles(
      missingImages: [image],
      candidatePaths: [candidate.path],
    );

    expect(result.matchedPaths, {1: p.normalize(candidate.path)});
    expect(result.matchedImportedFrom, {1: p.dirname(candidate.path)});
    expect(result.matchedCount, 1);
    expect(result.unresolvedImageIds, isEmpty);
    expect(result.ambiguousImageIds, isEmpty);
    expect(image.sourcePath, r'C:\old\bread.png');
    expect(image.status, ImageStatus.confirmed);
    expect(image.boxes.single.labelId, 7);
  });

  test('folder relink prefers the original relative path', () async {
    final replacementRoot = await Directory(
      p.join(tempDir.path, '새 데이터 폴더'),
    ).create();
    final preferred = await _writePng(
      p.join(replacementRoot.path, '중첩 batch', 'bread.png'),
      width: 32,
      height: 24,
    );
    await _writePng(
      p.join(replacementRoot.path, 'other', 'bread.png'),
      width: 32,
      height: 24,
    );
    final image = _image(
      sourcePath: p.join(r'C:\old source', '중첩 batch', 'bread.png'),
      importedFrom: r'C:\old source',
    );

    final result = await service.relinkFolder(
      missingImages: [image],
      folderPath: replacementRoot.path,
    );

    expect(result.matchedPaths, {1: p.normalize(preferred.path)});
    expect(result.matchedImportedFrom, {1: replacementRoot.path});
    expect(result.ambiguousImageIds, isEmpty);
  });

  test('does not auto-link ambiguous candidates', () async {
    final candidateA = await _writePng(
      p.join(tempDir.path, 'a', 'bread.png'),
      width: 32,
      height: 24,
    );
    final candidateB = await _writePng(
      p.join(tempDir.path, 'b', 'bread.png'),
      width: 32,
      height: 24,
    );

    final result = await service.relinkFiles(
      missingImages: [_image(sourcePath: r'C:\old\bread.png')],
      candidatePaths: [candidateA.path, candidateB.path],
    );

    expect(result.matchedPaths, isEmpty);
    expect(result.unresolvedImageIds, isEmpty);
    expect(result.ambiguousImageIds, {1});
  });

  test('hash takes priority over duplicate filename and dimensions', () async {
    final matching = await _writePng(
      p.join(tempDir.path, 'matching', 'bread.png'),
      width: 32,
      height: 24,
      red: 255,
    );
    final different = await _writePng(
      p.join(tempDir.path, 'different', 'bread.png'),
      width: 32,
      height: 24,
      blue: 255,
    );
    final expectedHash = sha256
        .convert(await matching.readAsBytes())
        .toString();

    final result = await service.relinkFiles(
      missingImages: [
        _image(sourcePath: r'C:\old\bread.png', contentSha256: expectedHash),
      ],
      candidatePaths: [different.path, matching.path],
    );

    expect(result.matchedPaths, {1: p.normalize(matching.path)});
    expect(result.ambiguousImageIds, isEmpty);
  });

  test(
    'explicit single-file relink resolves only the selected image',
    () async {
      final selectedCandidate = await _writePng(
        p.join(tempDir.path, '선택 파일', 'bread.png'),
        width: 32,
        height: 24,
      );

      final result = await service.relinkFiles(
        missingImages: [_image(id: 9, sourcePath: r'C:\old\bread.png')],
        candidatePaths: [selectedCandidate.path],
      );

      expect(result.matchedPaths, {9: p.normalize(selectedCandidate.path)});
      expect(result.unresolvedImageIds, isEmpty);
      expect(result.ambiguousImageIds, isEmpty);
    },
  );

  test('reports unresolved images and rejects a missing folder', () async {
    final unresolved = await service.relinkFiles(
      missingImages: [_image(sourcePath: r'C:\old\bread.png')],
      candidatePaths: [p.join(tempDir.path, 'not-there.png')],
    );

    expect(unresolved.matchedPaths, isEmpty);
    expect(unresolved.unresolvedImageIds, {1});
    expect(unresolved.ambiguousImageIds, isEmpty);
    await expectLater(
      service.relinkFolder(
        missingImages: [_image(sourcePath: r'C:\old\bread.png')],
        folderPath: p.join(tempDir.path, 'missing folder'),
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('does not assign one candidate to multiple source images', () async {
    final candidate = await _writePng(
      p.join(tempDir.path, 'bread.png'),
      width: 32,
      height: 24,
    );

    final result = await service.relinkFiles(
      missingImages: [
        _image(id: 1, sourcePath: r'C:\old-a\bread.png'),
        _image(id: 2, sourcePath: r'C:\old-b\bread.png'),
      ],
      candidatePaths: [candidate.path],
    );

    expect(result.matchedPaths, isEmpty);
    expect(result.unresolvedImageIds, isEmpty);
    expect(result.ambiguousImageIds, {1, 2});
  });
}

AnnotatedImage _image({
  int id = 1,
  required String sourcePath,
  String? importedFrom,
  int width = 32,
  int height = 24,
  ImageStatus status = ImageStatus.confirmed,
  String? contentSha256,
}) {
  return AnnotatedImage(
    id: id,
    sourcePath: sourcePath,
    displayName: p.basename(sourcePath),
    importedFrom: importedFrom,
    width: width,
    height: height,
    status: status,
    boxes: const [
      BoundingBox(
        id: 'box-1',
        x: 1,
        y: 2,
        width: 3,
        height: 4,
        status: BoxStatus.labeled,
        labelId: 7,
      ),
    ],
    contentSha256: contentSha256,
  );
}

Future<File> _writePng(
  String path, {
  required int width,
  required int height,
  int red = 0,
  int blue = 0,
}) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final image = img.Image(width: width, height: height);
  image.setPixelRgba(0, 0, red, 0, blue, 255);
  await file.writeAsBytes(img.encodePng(image), flush: true);
  return file;
}
