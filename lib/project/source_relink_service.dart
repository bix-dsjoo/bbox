import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../annotation/models.dart';
import '../image_import/image_scanner.dart';

enum SourceAvailability { unknown, available, missing }

class SourceCandidateMetadata {
  const SourceCandidateMetadata({
    required this.width,
    required this.height,
    this.sha256,
  });

  final int width;
  final int height;
  final String? sha256;
}

typedef SourceCandidateMetadataLoader =
    Future<SourceCandidateMetadata?> Function(
      String path, {
      required bool includeHash,
    });

class SourceRelinkResult {
  const SourceRelinkResult({
    required this.matchedPaths,
    required this.matchedImportedFrom,
    required this.unresolvedImageIds,
    required this.ambiguousImageIds,
    this.unreadableCandidatePaths = const {},
  });

  final Map<int, String> matchedPaths;
  final Map<int, String> matchedImportedFrom;
  final Set<int> unresolvedImageIds;
  final Set<int> ambiguousImageIds;
  final Set<String> unreadableCandidatePaths;

  int get matchedCount => matchedPaths.length;
}

class SourceRelinkService {
  const SourceRelinkService({
    this.maxConcurrentCandidateLoads = 4,
    this.metadataLoader,
  }) : assert(maxConcurrentCandidateLoads > 0);

  final int maxConcurrentCandidateLoads;
  final SourceCandidateMetadataLoader? metadataLoader;

  Future<Map<int, SourceAvailability>> inspectSources(
    Iterable<AnnotatedImage> images,
  ) async {
    final entries = await _mapBounded(
      images.toList(growable: false),
      maxConcurrentCandidateLoads,
      (image) async => MapEntry(
        image.id,
        await File(image.sourcePath).exists()
            ? SourceAvailability.available
            : SourceAvailability.missing,
      ),
    );
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
    final uniquePaths = {
      for (final path in paths) _pathKey(path),
    }.toList(growable: false);
    final inspected = await _mapBounded(
      uniquePaths,
      maxConcurrentCandidateLoads,
      (path) => _inspectCandidate(path, includeHash),
    );
    final candidates = [
      for (final inspection in inspected)
        if (inspection.metadata != null) inspection.metadata!,
    ];
    final byPath = {
      for (final candidate in candidates) _pathKey(candidate.path): candidate,
    };

    final proposals = <int, List<_CandidateMetadata>>{};
    for (final image in images) {
      final preferred = preferredPaths[image.id];
      final preferredCandidate = preferred == null
          ? null
          : byPath[_pathKey(preferred)];
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
    final ownersByPath = <String, Set<int>>{};
    for (final entry in proposals.entries) {
      for (final candidate in entry.value) {
        ownersByPath
            .putIfAbsent(_pathKey(candidate.path), () => <int>{})
            .add(entry.key);
      }
    }
    for (final owners in ownersByPath.values) {
      if (owners.length > 1) ambiguous.addAll(owners);
    }

    final single = <int, _CandidateMetadata>{};
    for (final entry in proposals.entries) {
      if (entry.value.length > 1) {
        ambiguous.add(entry.key);
      } else if (entry.value.length == 1) {
        single[entry.key] = entry.value.single;
      }
    }

    for (final imageId in ambiguous) {
      single.remove(imageId);
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
      unreadableCandidatePaths: {
        for (final inspection in inspected)
          if (inspection.metadata == null) inspection.path,
      },
    );
  }

  bool _matches(AnnotatedImage image, _CandidateMetadata candidate) {
    final expectedHash = image.contentSha256;
    if (expectedHash != null) return candidate.sha256 == expectedHash;
    return candidate.fileNameKey == image.displayName.toLowerCase() &&
        candidate.width == image.width &&
        candidate.height == image.height;
  }

  Future<_CandidateInspection> _inspectCandidate(
    String path,
    bool includeHash,
  ) async {
    try {
      final loaded = await (metadataLoader ?? _loadCandidateMetadata)(
        path,
        includeHash: includeHash,
      );
      if (loaded == null) return _CandidateInspection.unreadable(path);
      return _CandidateInspection.readable(
        _CandidateMetadata(
          path: path,
          fileNameKey: p.basename(path).toLowerCase(),
          width: loaded.width,
          height: loaded.height,
          sha256: loaded.sha256,
        ),
      );
    } catch (_) {
      return _CandidateInspection.unreadable(path);
    }
  }
}

Future<SourceCandidateMetadata?> _loadCandidateMetadata(
  String path, {
  required bool includeHash,
}) async {
  final file = File(path);
  final bytes = await file.readAsBytes();
  final dimensions = await Isolate.run<({int width, int height})?>(() {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    return (width: decoded.width, height: decoded.height);
  });
  if (dimensions == null) return null;
  final digest = includeHash ? await sha256.bind(file.openRead()).first : null;
  return SourceCandidateMetadata(
    width: dimensions.width,
    height: dimensions.height,
    sha256: digest?.toString(),
  );
}

String _pathKey(String path) => p.normalize(p.absolute(path));

Future<List<R>> _mapBounded<T, R>(
  List<T> values,
  int maxConcurrent,
  Future<R> Function(T value) transform,
) async {
  if (values.isEmpty) return <R>[];
  final results = List<R?>.filled(values.length, null);
  var nextIndex = 0;

  Future<void> worker() async {
    while (nextIndex < values.length) {
      final index = nextIndex++;
      results[index] = await transform(values[index]);
    }
  }

  final workerCount = maxConcurrent < values.length
      ? maxConcurrent
      : values.length;
  await Future.wait([
    for (var index = 0; index < workerCount; index++) worker(),
  ]);
  return [for (final result in results) result as R];
}

class _CandidateInspection {
  _CandidateInspection.readable(_CandidateMetadata metadata)
    : path = metadata.path,
      metadata = metadata;

  const _CandidateInspection.unreadable(this.path) : metadata = null;

  final String path;
  final _CandidateMetadata? metadata;
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
