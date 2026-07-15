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
typedef SourcePathKey = String Function(String path);
typedef SourceCandidateLookupObserver = void Function();
typedef SourceOwnershipWorkObserver = void Function(int workUnits);

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
    this.pathKey = _defaultSourcePathKey,
    this.onCandidateLookup,
    this.onOwnershipWork,
  });

  final int maxConcurrentCandidateLoads;
  final SourceCandidateMetadataLoader? metadataLoader;
  final SourcePathKey pathKey;
  final SourceCandidateLookupObserver? onCandidateLookup;
  final SourceOwnershipWorkObserver? onOwnershipWork;

  Future<Map<int, SourceAvailability>> inspectSources(
    Iterable<AnnotatedImage> images,
  ) async {
    _validateConcurrency();
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
  }) async {
    _validateConcurrency();
    return _match(
      missingImages,
      candidatePaths,
      importedFromForMatch: p.dirname,
    );
  }

  Future<SourceRelinkResult> relinkFolder({
    required List<AnnotatedImage> missingImages,
    required String folderPath,
  }) async {
    _validateConcurrency();
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
    final uniquePathsByKey = <String, String>{};
    for (final path in paths) {
      final normalizedPath = p.normalize(p.absolute(path));
      uniquePathsByKey.putIfAbsent(
        pathKey(normalizedPath),
        () => normalizedPath,
      );
    }
    final uniquePaths = uniquePathsByKey.values.toList(growable: false);
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
      for (final candidate in candidates) pathKey(candidate.path): candidate,
    };
    final buckets = <_CandidateBucketKey, List<_CandidateMetadata>>{};
    for (final candidate in candidates) {
      for (final key in candidate.bucketKeys) {
        buckets.putIfAbsent(key, () => <_CandidateMetadata>[]).add(candidate);
      }
    }

    final preferredByImage = <int, _CandidateMetadata>{};
    final generalOwners = <_CandidateBucketKey, List<int>>{};
    for (final image in images) {
      final preferred = preferredPaths[image.id];
      final preferredCandidate = preferred == null
          ? null
          : byPath[pathKey(preferred)];
      final imageKey = _CandidateBucketKey.forImage(image);
      if (preferredCandidate != null &&
          preferredCandidate.bucketKeys.contains(imageKey)) {
        preferredByImage[image.id] = preferredCandidate;
        continue;
      }
      onCandidateLookup?.call();
      generalOwners.putIfAbsent(imageKey, () => <int>[]).add(image.id);
    }

    final ambiguous = <int>{};
    final single = <int, _CandidateMetadata>{};
    void markAmbiguous(Iterable<int> imageIds) {
      final ids = imageIds is List<int>
          ? imageIds
          : imageIds.toList(growable: false);
      onOwnershipWork?.call(ids.length);
      ambiguous.addAll(ids);
    }

    for (final entry in generalOwners.entries) {
      final bucket = buckets[entry.key] ?? const <_CandidateMetadata>[];
      if (bucket.isEmpty) {
        continue;
      }
      if (bucket.length != 1 || entry.value.length != 1) {
        markAmbiguous(entry.value);
      } else {
        single[entry.value.single] = bucket.single;
      }
    }

    final preferredOwnersByPath = <String, List<int>>{};
    final preferredOwnersByBucket = <_CandidateBucketKey, List<int>>{};
    for (final entry in preferredByImage.entries) {
      preferredOwnersByPath
          .putIfAbsent(pathKey(entry.value.path), () => <int>[])
          .add(entry.key);
      for (final bucketKey in entry.value.bucketKeys) {
        preferredOwnersByBucket
            .putIfAbsent(bucketKey, () => <int>[])
            .add(entry.key);
      }
    }
    for (final entry in preferredOwnersByPath.entries) {
      if (entry.value.length > 1) markAmbiguous(entry.value);
    }
    for (final entry in preferredOwnersByBucket.entries) {
      final general = generalOwners[entry.key];
      if (general == null || general.isEmpty) continue;
      markAmbiguous(entry.value);
      markAmbiguous(general);
    }
    for (final entry in preferredByImage.entries) {
      if (!ambiguous.contains(entry.key)) single[entry.key] = entry.value;
    }

    final provisionalOwnersByPath = <String, List<int>>{};
    for (final entry in single.entries) {
      provisionalOwnersByPath
          .putIfAbsent(pathKey(entry.value.path), () => <int>[])
          .add(entry.key);
    }
    for (final owners in provisionalOwnersByPath.values) {
      if (owners.length > 1) markAmbiguous(owners);
    }
    single.removeWhere((imageId, _) => ambiguous.contains(imageId));

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

  void _validateConcurrency() {
    if (maxConcurrentCandidateLoads <= 0) {
      throw ArgumentError.value(
        maxConcurrentCandidateLoads,
        'maxConcurrentCandidateLoads',
        'must be positive',
      );
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

String sourcePathKey(String path, {required bool isWindows}) {
  final normalized = p.normalize(p.absolute(path));
  return isWindows ? normalized.toLowerCase() : normalized;
}

String _defaultSourcePathKey(String path) =>
    sourcePathKey(path, isWindows: Platform.isWindows);

Future<List<R>> _mapBounded<T, R>(
  List<T> values,
  int maxConcurrent,
  Future<R> Function(T value) transform,
) async {
  if (maxConcurrent <= 0) {
    throw ArgumentError.value(
      maxConcurrent,
      'maxConcurrent',
      'must be positive',
    );
  }
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

  Iterable<_CandidateBucketKey> get bucketKeys sync* {
    final hash = sha256;
    if (hash != null) yield _CandidateBucketKey.hash(hash);
    yield _CandidateBucketKey.file(fileNameKey, width, height);
  }
}

class _CandidateBucketKey {
  const _CandidateBucketKey._({
    this.sha256,
    this.fileNameKey,
    this.width,
    this.height,
  });

  const _CandidateBucketKey.hash(String sha256) : this._(sha256: sha256);

  const _CandidateBucketKey.file(String fileNameKey, int width, int height)
    : this._(fileNameKey: fileNameKey, width: width, height: height);

  factory _CandidateBucketKey.forImage(AnnotatedImage image) {
    final hash = image.contentSha256;
    return hash != null
        ? _CandidateBucketKey.hash(hash)
        : _CandidateBucketKey.file(
            image.displayName.toLowerCase(),
            image.width,
            image.height,
          );
  }

  final String? sha256;
  final String? fileNameKey;
  final int? width;
  final int? height;

  @override
  bool operator ==(Object other) =>
      other is _CandidateBucketKey &&
      other.sha256 == sha256 &&
      other.fileNameKey == fileNameKey &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(sha256, fileNameKey, width, height);
}
