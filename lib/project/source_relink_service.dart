import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../annotation/models.dart';
import '../image_import/image_scanner.dart';

enum SourceAvailability { unknown, available, missing }

class SourceRelinkResult {
  const SourceRelinkResult({
    required this.matchedPaths,
    required this.matchedImportedFrom,
    required this.unresolvedImageIds,
    required this.ambiguousImageIds,
  });

  final Map<int, String> matchedPaths;
  final Map<int, String> matchedImportedFrom;
  final Set<int> unresolvedImageIds;
  final Set<int> ambiguousImageIds;

  int get matchedCount => matchedPaths.length;
}

class SourceRelinkService {
  const SourceRelinkService();

  Future<Map<int, SourceAvailability>> inspectSources(
    Iterable<AnnotatedImage> images,
  ) async {
    final entries = await Future.wait([
      for (final image in images)
        File(image.sourcePath).exists().then(
          (exists) => MapEntry(
            image.id,
            exists ? SourceAvailability.available : SourceAvailability.missing,
          ),
        ),
    ]);
    return Map.fromEntries(entries);
  }

  Future<SourceRelinkResult> relinkFiles({
    required List<AnnotatedImage> missingImages,
    required List<String> candidatePaths,
  }) async =>
      _match(missingImages, candidatePaths, importedFromForMatch: p.dirname);

  Future<SourceRelinkResult> relinkFolder({
    required List<AnnotatedImage> missingImages,
    required String folderPath,
  }) async {
    final root = Directory(folderPath);
    if (!await root.exists()) {
      throw FileSystemException('Image folder does not exist.', folderPath);
    }
    final candidates = await root
        .list(recursive: true, followLinks: false)
        .where(
          (entity) =>
              entity is File && ImageScanner.isSupportedImagePath(entity.path),
        )
        .cast<File>()
        .map((file) => file.path)
        .toList();
    final preferred = <int, String>{};
    for (final image in missingImages) {
      final importedFrom = image.importedFrom;
      if (importedFrom == null) continue;
      if (!p.isWithin(
        p.normalize(importedFrom),
        p.normalize(image.sourcePath),
      )) {
        continue;
      }
      final relative = p.relative(image.sourcePath, from: importedFrom);
      if (p.isAbsolute(relative)) continue;
      final candidate = p.join(folderPath, relative);
      if (await File(candidate).exists()) preferred[image.id] = candidate;
    }
    return _match(
      missingImages,
      candidates,
      preferredPaths: preferred,
      importedFromForMatch: (_) => folderPath,
    );
  }

  Future<SourceRelinkResult> _match(
    List<AnnotatedImage> images,
    List<String> paths, {
    Map<int, String> preferredPaths = const {},
    required String Function(String path) importedFromForMatch,
  }) async {
    final includeHash = images.any((image) => image.contentSha256 != null);
    final uniquePaths = <String, String>{
      for (final path in paths)
        p.normalize(path).toLowerCase(): p.normalize(path),
    }.values.toList(growable: false);
    final inspected = await Future.wait([
      for (final path in uniquePaths) _inspectCandidate(path, includeHash),
    ]);
    final candidates = inspected.whereType<_CandidateMetadata>().toList();
    final byPath = {
      for (final candidate in candidates)
        p.normalize(candidate.path).toLowerCase(): candidate,
    };

    final proposals = <int, List<_CandidateMetadata>>{};
    for (final image in images) {
      final preferred = preferredPaths[image.id];
      final preferredCandidate = preferred == null
          ? null
          : byPath[p.normalize(preferred).toLowerCase()];
      if (preferredCandidate != null && _matches(image, preferredCandidate)) {
        proposals[image.id] = [preferredCandidate];
        continue;
      }
      proposals[image.id] = [
        for (final candidate in candidates)
          if (_matches(image, candidate)) candidate,
      ];
    }

    final ambiguous = <int>{};
    final single = <int, _CandidateMetadata>{};
    for (final entry in proposals.entries) {
      if (entry.value.length > 1) {
        ambiguous.add(entry.key);
      } else if (entry.value.length == 1) {
        single[entry.key] = entry.value.single;
      }
    }

    final ownersByPath = <String, List<int>>{};
    for (final entry in single.entries) {
      final key = p.normalize(entry.value.path).toLowerCase();
      ownersByPath.putIfAbsent(key, () => []).add(entry.key);
    }
    for (final owners in ownersByPath.values) {
      if (owners.length > 1) {
        ambiguous.addAll(owners);
        for (final imageId in owners) {
          single.remove(imageId);
        }
      }
    }

    final matchedPaths = <int, String>{};
    final matchedImportedFrom = <int, String>{};
    for (final entry in single.entries) {
      if (ambiguous.contains(entry.key)) continue;
      matchedPaths[entry.key] = entry.value.path;
      matchedImportedFrom[entry.key] = importedFromForMatch(entry.value.path);
    }
    final unresolved = {
      for (final image in images)
        if (!matchedPaths.containsKey(image.id) &&
            !ambiguous.contains(image.id))
          image.id,
    };
    return SourceRelinkResult(
      matchedPaths: matchedPaths,
      matchedImportedFrom: matchedImportedFrom,
      unresolvedImageIds: unresolved,
      ambiguousImageIds: ambiguous,
    );
  }

  bool _matches(AnnotatedImage image, _CandidateMetadata candidate) {
    final expectedHash = image.contentSha256;
    if (expectedHash != null) return candidate.sha256 == expectedHash;
    return candidate.fileNameKey == image.displayName.toLowerCase() &&
        candidate.width == image.width &&
        candidate.height == image.height;
  }

  Future<_CandidateMetadata?> _inspectCandidate(
    String path,
    bool includeHash,
  ) async {
    try {
      final bytes = await File(path).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      return _CandidateMetadata(
        path: p.normalize(path),
        fileNameKey: p.basename(path).toLowerCase(),
        width: decoded.width,
        height: decoded.height,
        sha256: includeHash ? sha256.convert(bytes).toString() : null,
      );
    } on FileSystemException {
      return null;
    }
  }
}

class _CandidateMetadata {
  const _CandidateMetadata({
    required this.path,
    required this.fileNameKey,
    required this.width,
    required this.height,
    required this.sha256,
  });

  final String path;
  final String fileNameKey;
  final int width;
  final int height;
  final String? sha256;
}
