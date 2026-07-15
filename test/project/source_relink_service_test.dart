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
    final missingPath = p.join(tempDir.path, 'old', 'bread.png');
    final image = _image(sourcePath: missingPath);

    final result = await service.relinkFiles(
      missingImages: [image],
      candidatePaths: [candidate.path],
    );

    expect(result.matchedPaths, {1: p.normalize(candidate.path)});
    expect(result.matchedImportedFrom, {1: p.dirname(candidate.path)});
    expect(result.matchedCount, 1);
    expect(result.unresolvedImageIds, isEmpty);
    expect(result.ambiguousImageIds, isEmpty);
    expect(image.sourcePath, missingPath);
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
    final originalRoot = p.join(tempDir.path, 'old source');
    final image = _image(
      sourcePath: p.join(originalRoot, '중첩 batch', 'bread.png'),
      importedFrom: originalRoot,
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
      missingImages: [
        _image(sourcePath: p.join(tempDir.path, 'old', 'bread.png')),
      ],
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
        _image(
          sourcePath: p.join(tempDir.path, 'old', 'bread.png'),
          contentSha256: expectedHash,
        ),
      ],
      candidatePaths: [different.path, matching.path],
    );

    expect(result.matchedPaths, {1: p.normalize(matching.path)});
    expect(result.ambiguousImageIds, isEmpty);
  });

  test(
    'one candidate shared by hash and legacy signature is ambiguous for both',
    () async {
      final candidatePath = p.join(tempDir.path, 'candidate', 'bread.png');
      final seamService = SourceRelinkService(
        metadataLoader: (path, {required includeHash}) async {
          expect(includeHash, isTrue);
          return const SourceCandidateMetadata(
            width: 32,
            height: 24,
            sha256: 'shared-hash',
          );
        },
      );

      final result = await seamService.relinkFiles(
        missingImages: [
          _image(
            id: 1,
            sourcePath: p.join(tempDir.path, 'old-hash', 'bread.png'),
            contentSha256: 'shared-hash',
          ),
          _image(
            id: 2,
            sourcePath: p.join(tempDir.path, 'old-legacy', 'bread.png'),
          ),
        ],
        candidatePaths: [candidatePath],
      );

      expect(result.matchedPaths, isEmpty);
      expect(result.unresolvedImageIds, isEmpty);
      expect(result.ambiguousImageIds, {1, 2});
    },
  );

  test(
    'explicit single-file relink resolves only the selected image',
    () async {
      final selectedCandidate = await _writePng(
        p.join(tempDir.path, '선택 파일', 'bread.png'),
        width: 32,
        height: 24,
      );

      final result = await service.relinkFiles(
        missingImages: [
          _image(id: 9, sourcePath: p.join(tempDir.path, 'old', 'bread.png')),
        ],
        candidatePaths: [selectedCandidate.path],
      );

      expect(result.matchedPaths, {9: p.normalize(selectedCandidate.path)});
      expect(result.unresolvedImageIds, isEmpty);
      expect(result.ambiguousImageIds, isEmpty);
    },
  );

  test('reports unresolved images and rejects a missing folder', () async {
    final unresolved = await service.relinkFiles(
      missingImages: [
        _image(sourcePath: p.join(tempDir.path, 'old', 'bread.png')),
      ],
      candidatePaths: [p.join(tempDir.path, 'not-there.png')],
    );

    expect(unresolved.matchedPaths, isEmpty);
    expect(unresolved.unresolvedImageIds, {1});
    expect(unresolved.ambiguousImageIds, isEmpty);
    await expectLater(
      service.relinkFolder(
        missingImages: [
          _image(sourcePath: p.join(tempDir.path, 'old', 'bread.png')),
        ],
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
        _image(id: 1, sourcePath: p.join(tempDir.path, 'old-a', 'bread.png')),
        _image(id: 2, sourcePath: p.join(tempDir.path, 'old-b', 'bread.png')),
      ],
      candidatePaths: [candidate.path],
    );

    expect(result.matchedPaths, isEmpty);
    expect(result.unresolvedImageIds, isEmpty);
    expect(result.ambiguousImageIds, {1, 2});
  });

  test(
    'shared preferred candidate makes every proposing image ambiguous',
    () async {
      final replacementRoot = await Directory(
        p.join(tempDir.path, 'replacement'),
      ).create();
      await _writePng(
        p.join(replacementRoot.path, 'batch', 'bread.png'),
        width: 32,
        height: 24,
      );
      await _writePng(
        p.join(replacementRoot.path, 'other', 'bread.png'),
        width: 32,
        height: 24,
      );
      final originalRoot = p.join(tempDir.path, 'original');

      final result = await service.relinkFolder(
        missingImages: [
          _image(
            id: 1,
            sourcePath: p.join(originalRoot, 'batch', 'bread.png'),
            importedFrom: originalRoot,
          ),
          _image(
            id: 2,
            sourcePath: p.join(tempDir.path, 'other-old', 'bread.png'),
          ),
        ],
        folderPath: replacementRoot.path,
      );

      expect(result.matchedPaths, isEmpty);
      expect(result.unresolvedImageIds, isEmpty);
      expect(result.ambiguousImageIds, {1, 2});
    },
  );

  test('case-distinct paths remain distinct candidate identities', () async {
    final loadedPaths = <String>[];
    final caseUpper = p.join(tempDir.path, 'case', 'Bread.png');
    final caseLower = p.join(tempDir.path, 'case', 'bread.png');
    final seamService = SourceRelinkService(
      pathKey: (path) => sourcePathKey(path, isWindows: false),
      metadataLoader: (path, {required includeHash}) async {
        loadedPaths.add(path);
        return const SourceCandidateMetadata(width: 32, height: 24);
      },
    );

    final result = await seamService.relinkFiles(
      missingImages: [
        _image(
          sourcePath: p.join(tempDir.path, 'old', 'bread.png'),
          displayName: 'bread.png',
        ),
      ],
      candidatePaths: [caseUpper, caseLower],
    );

    expect(loadedPaths.toSet(), {p.absolute(caseUpper), p.absolute(caseLower)});
    expect(result.matchedPaths, isEmpty);
    expect(result.ambiguousImageIds, {1});
  });

  test(
    'Windows path keys collapse case while non-Windows keys preserve it',
    () {
      const upper = r'C:\Data\Bread.PNG';
      const lower = r'c:\data\bread.png';

      expect(
        sourcePathKey(upper, isWindows: true),
        sourcePathKey(lower, isWindows: true),
      );
      expect(
        sourcePathKey(upper, isWindows: false),
        isNot(sourcePathKey(lower, isWindows: false)),
      );
    },
  );

  test('Windows-equivalent candidate paths are loaded only once', () async {
    var loads = 0;
    final seamService = SourceRelinkService(
      pathKey: (path) => sourcePathKey(path, isWindows: true),
      metadataLoader: (path, {required includeHash}) async {
        loads += 1;
        return const SourceCandidateMetadata(width: 32, height: 24);
      },
    );

    final result = await seamService.relinkFiles(
      missingImages: [
        _image(sourcePath: r'C:\old\bread.png', displayName: 'bread.png'),
      ],
      candidatePaths: const [r'C:\Data\bread.png', r'c:\data\BREAD.PNG'],
    );

    expect(loads, 1);
    expect(result.matchedCount, 1);
    expect(result.ambiguousImageIds, isEmpty);
  });

  test('corrupt candidate is diagnosed without hiding a valid match', () async {
    final corrupt = File(p.join(tempDir.path, 'corrupt', 'bread.png'));
    await corrupt.parent.create(recursive: true);
    await corrupt.writeAsString('not an image');
    final valid = await _writePng(
      p.join(tempDir.path, 'valid', 'bread.png'),
      width: 32,
      height: 24,
    );

    final result = await service.relinkFiles(
      missingImages: [
        _image(sourcePath: p.join(tempDir.path, 'old', 'bread.png')),
      ],
      candidatePaths: [corrupt.path, valid.path],
    );

    expect(result.matchedPaths, {1: p.absolute(valid.path)});
    expect(result.unreadableCandidatePaths, {p.absolute(corrupt.path)});
    expect(result.ambiguousImageIds, isEmpty);
  });

  test(
    'candidate metadata loading honors the configured concurrency bound',
    () async {
      var activeLoads = 0;
      var peakLoads = 0;
      final candidatePaths = [
        for (var index = 0; index < 6; index++)
          p.join(tempDir.path, 'candidate-$index.png'),
      ];
      final seamService = SourceRelinkService(
        maxConcurrentCandidateLoads: 2,
        metadataLoader: (path, {required includeHash}) async {
          expect(includeHash, isFalse);
          activeLoads++;
          if (activeLoads > peakLoads) peakLoads = activeLoads;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          activeLoads--;
          return const SourceCandidateMetadata(width: 32, height: 24);
        },
      );

      final result = await seamService.relinkFiles(
        missingImages: [
          for (var index = 0; index < candidatePaths.length; index++)
            _image(
              id: index + 1,
              sourcePath: p.join(tempDir.path, 'old', 'candidate-$index.png'),
            ),
        ],
        candidatePaths: candidatePaths,
      );

      expect(peakLoads, 2);
      expect(result.matchedCount, candidatePaths.length);
    },
  );

  test(
    'rejects non-positive candidate concurrency on every public path',
    () async {
      const invalid = SourceRelinkService(maxConcurrentCandidateLoads: 0);

      await expectLater(
        invalid.inspectSources(const []),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        invalid.relinkFiles(missingImages: const [], candidatePaths: const []),
        throwsA(isA<ArgumentError>()),
      );
    },
  );

  test(
    'collision-heavy matching performs one indexed lookup per image',
    () async {
      const count = 600;
      var metadataLoads = 0;
      var lookups = 0;
      final seamService = SourceRelinkService(
        onCandidateLookup: () => lookups += 1,
        metadataLoader: (path, {required includeHash}) async {
          metadataLoads += 1;
          return const SourceCandidateMetadata(width: 32, height: 24);
        },
      );
      final candidates = [
        for (var index = 0; index < count; index++)
          p.join(tempDir.path, 'candidate-$index', 'bread.png'),
      ];
      final images = [
        for (var index = 0; index < count; index++)
          _image(
            id: index + 1,
            sourcePath: p.join(tempDir.path, 'old-$index', 'bread.png'),
          ),
      ];

      final result = await seamService.relinkFiles(
        missingImages: images,
        candidatePaths: candidates,
      );

      expect(metadataLoads, count);
      expect(lookups, count);
      expect(result.matchedPaths, isEmpty);
      expect(result.ambiguousImageIds, hasLength(count));
    },
  );

  test(
    'preferred and general collision ownership work stays near linear',
    () async {
      const preferredCount = 120;
      const generalCount = 120;
      final replacementRoot = await Directory(
        p.join(tempDir.path, 'replacement-heavy'),
      ).create();
      final originalRoot = p.join(tempDir.path, 'original-heavy');
      for (var index = 0; index < preferredCount; index++) {
        final file = File(
          p.join(replacementRoot.path, 'batch-$index', 'bread.png'),
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(const [0]);
      }
      var ownershipWork = 0;
      final seamService = SourceRelinkService(
        onOwnershipWork: (units) => ownershipWork += units,
        metadataLoader: (path, {required includeHash}) async =>
            const SourceCandidateMetadata(width: 32, height: 24),
      );
      final images = [
        for (var index = 0; index < preferredCount; index++)
          _image(
            id: index + 1,
            sourcePath: p.join(originalRoot, 'batch-$index', 'bread.png'),
            importedFrom: originalRoot,
          ),
        for (var index = 0; index < generalCount; index++)
          _image(
            id: preferredCount + index + 1,
            sourcePath: p.join(tempDir.path, 'legacy-$index', 'bread.png'),
          ),
      ];

      final result = await seamService.relinkFolder(
        missingImages: images,
        folderPath: replacementRoot.path,
      );

      expect(result.matchedPaths, isEmpty);
      expect(result.ambiguousImageIds, hasLength(images.length));
      expect(
        ownershipWork,
        lessThanOrEqualTo((preferredCount + generalCount) * 12),
      );
    },
  );
}

AnnotatedImage _image({
  int id = 1,
  required String sourcePath,
  String? displayName,
  String? importedFrom,
  int width = 32,
  int height = 24,
  ImageStatus status = ImageStatus.confirmed,
  String? contentSha256,
}) {
  return AnnotatedImage(
    id: id,
    sourcePath: sourcePath,
    displayName: displayName ?? p.basename(sourcePath),
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
