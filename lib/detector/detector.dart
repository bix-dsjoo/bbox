import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

import '../annotation/models.dart';

class DetectionResult {
  const DetectionResult({
    required this.detectorName,
    required this.boxes,
    this.imageSha256,
    this.pipelineVersion,
    this.policyVersion,
    this.detectorSha256,
    this.classifierSha256,
    this.verifierSha256,
    this.stageErrors = const [],
    this.errorMessage,
  });

  final String detectorName;
  final List<BoundingBox> boxes;
  final String? imageSha256;
  final String? pipelineVersion;
  final String? policyVersion;
  final String? detectorSha256;
  final String? classifierSha256;
  final String? verifierSha256;
  final List<WorkerStageError> stageErrors;
  final String? errorMessage;
}

class WorkerStageError {
  const WorkerStageError({
    required this.stage,
    required this.code,
    required this.message,
  });

  final String stage;
  final String code;
  final String message;
}

class DetectionOptions {
  const DetectionOptions({this.maxProposals});

  final int? maxProposals;
}

int? boundedMaxProposals(int? value) {
  if (value == null) {
    return null;
  }
  return value.clamp(1, 100).toInt();
}

abstract class Detector {
  String get name;

  Future<DetectionResult> detect(
    AnnotatedImage image, {
    String? imagePath,
    DetectionOptions options = const DetectionOptions(),
  });
}

class DummyDetector implements Detector {
  const DummyDetector();

  @override
  String get name => 'dummy-algorithm';

  @override
  Future<DetectionResult> detect(
    AnnotatedImage image, {
    String? imagePath,
    DetectionOptions options = const DetectionOptions(),
  }) async {
    if (image.width < 20 || image.height < 20) {
      return DetectionResult(detectorName: name, boxes: const []);
    }

    final width = image.width / 2;
    final height = image.height / 2;
    final x = (image.width - width) / 2;
    final y = (image.height - height) / 2;

    final boxes = [
      BoundingBox(
        id: 'det-${image.id}-1',
        x: x,
        y: y,
        width: width,
        height: height,
        status: BoxStatus.proposal,
        confidence: 0.35,
      ),
    ];
    final limit = boundedMaxProposals(options.maxProposals);
    final limitedBoxes = limit == null
        ? boxes
        : boxes.take(limit).toList(growable: false);

    return DetectionResult(detectorName: name, boxes: limitedBoxes);
  }
}

class DarkBackgroundDetector implements Detector {
  const DarkBackgroundDetector({
    this.maxAnalysisDimension = 1024,
    this.minAreaRatio = 0.001,
    this.maxAreaRatio = 0.4,
    this.padding = 2,
    this.maxProposals = 30,
    this.splitLargeComponents = true,
    this.splitPeakThresholdRatio = 0.55,
    this.splitSeedSeparationRatio = 0.38,
    this.maxSplitSeedsPerComponent = 4,
  });

  final int maxAnalysisDimension;
  final double minAreaRatio;
  final double maxAreaRatio;
  final int padding;
  final int maxProposals;
  final bool splitLargeComponents;
  final double splitPeakThresholdRatio;
  final double splitSeedSeparationRatio;
  final int maxSplitSeedsPerComponent;

  @override
  String get name => 'dark-background-contour';

  @override
  Future<DetectionResult> detect(
    AnnotatedImage image, {
    String? imagePath,
    DetectionOptions options = const DetectionOptions(),
  }) async {
    if (imagePath == null) {
      return DetectionResult(
        detectorName: name,
        boxes: const [],
        errorMessage: 'image path is required',
      );
    }

    final proposalLimit =
        boundedMaxProposals(options.maxProposals ?? maxProposals) ?? 1;

    final decoded = img.decodeImage(await File(imagePath).readAsBytes());
    if (decoded == null) {
      return DetectionResult(
        detectorName: name,
        boxes: const [],
        errorMessage: 'decode failed',
      );
    }

    final source = img.bakeOrientation(decoded);
    final scale = _analysisScale(source.width, source.height);
    final analysisImage = scale < 1
        ? img.copyResize(
            source,
            width: (source.width * scale).round(),
            height: (source.height * scale).round(),
            interpolation: img.Interpolation.average,
          )
        : source;

    final mask = _foregroundMask(analysisImage);
    final components = _components(
      mask,
      analysisImage.width,
      analysisImage.height,
    );
    final imageArea = analysisImage.width * analysisImage.height;
    final minArea = math.max(16, (imageArea * minAreaRatio).round());
    final maxArea = imageArea * maxAreaRatio;
    final inverseScale = 1 / scale;

    final candidates =
        components
            .where((component) {
              return component.area >= minArea && component.area <= maxArea;
            })
            .expand((component) {
              if (!splitLargeComponents) {
                return [component];
              }
              return _splitComponent(
                component,
                imageWidth: analysisImage.width,
                imageHeight: analysisImage.height,
                minArea: minArea,
              );
            })
            .where((component) {
              return component.area >= minArea && component.area <= maxArea;
            })
            .toList()
          ..sort((a, b) {
            final topCompare = a.minY.compareTo(b.minY);
            return topCompare == 0 ? a.minX.compareTo(b.minX) : topCompare;
          });

    final boxes = <BoundingBox>[];
    for (final component in candidates.take(proposalLimit)) {
      final paddedMinX = math.max(0, component.minX - padding);
      final paddedMinY = math.max(0, component.minY - padding);
      final paddedMaxX = math.min(
        analysisImage.width - 1,
        component.maxX + padding,
      );
      final paddedMaxY = math.min(
        analysisImage.height - 1,
        component.maxY + padding,
      );
      final x = paddedMinX * inverseScale;
      final y = paddedMinY * inverseScale;
      final width = (paddedMaxX - paddedMinX + 1) * inverseScale;
      final height = (paddedMaxY - paddedMinY + 1) * inverseScale;
      boxes.add(
        BoundingBox(
          id: 'det-${image.id}-${boxes.length + 1}',
          x: x.clamp(0, image.width.toDouble()).toDouble(),
          y: y.clamp(0, image.height.toDouble()).toDouble(),
          width: width.clamp(1, image.width.toDouble()).toDouble(),
          height: height.clamp(1, image.height.toDouble()).toDouble(),
          status: BoxStatus.proposal,
          confidence: _confidence(
            component.area,
            width * height / inverseScale / inverseScale,
          ),
        ),
      );
    }

    return DetectionResult(detectorName: name, boxes: boxes);
  }

  double _analysisScale(int width, int height) {
    final longestSide = math.max(width, height);
    if (longestSide <= maxAnalysisDimension) {
      return 1;
    }
    return maxAnalysisDimension / longestSide;
  }

  List<bool> _foregroundMask(img.Image image) {
    final background = _estimateBorderLuminance(image);
    final threshold = (background + 35).clamp(48, 120).toDouble();
    final mask = List<bool>.filled(image.width * image.height, false);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        final r = pixel.r.toDouble();
        final g = pixel.g.toDouble();
        final b = pixel.b.toDouble();
        final maxChannel = math.max(r, math.max(g, b));
        final minChannel = math.min(r, math.min(g, b));
        final luminance = 0.299 * r + 0.587 * g + 0.114 * b;
        final saturation = maxChannel - minChannel;
        mask[y * image.width + x] =
            luminance >= threshold &&
            (maxChannel >= threshold + 8 || saturation >= 18);
      }
    }
    return mask;
  }

  double _estimateBorderLuminance(img.Image image) {
    var sum = 0.0;
    var count = 0;
    void add(int x, int y) {
      final pixel = image.getPixel(x, y);
      sum += 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b;
      count++;
    }

    for (var x = 0; x < image.width; x++) {
      add(x, 0);
      add(x, image.height - 1);
    }
    for (var y = 1; y < image.height - 1; y++) {
      add(0, y);
      add(image.width - 1, y);
    }
    return count == 0 ? 0 : sum / count;
  }

  List<_Component> _components(List<bool> mask, int width, int height) {
    final visited = List<bool>.filled(mask.length, false);
    final components = <_Component>[];
    final queue = Queue<int>();

    for (var index = 0; index < mask.length; index++) {
      if (!mask[index] || visited[index]) {
        continue;
      }
      final startX = index % width;
      final startY = index ~/ width;
      final component = _Component(startX, startY);
      visited[index] = true;
      queue.add(index);

      while (queue.isNotEmpty) {
        final current = queue.removeFirst();
        final x = current % width;
        final y = current ~/ width;
        component.include(x, y, index: current);

        void visit(int nx, int ny) {
          if (nx < 0 || nx >= width || ny < 0 || ny >= height) {
            return;
          }
          final neighbor = ny * width + nx;
          if (!mask[neighbor] || visited[neighbor]) {
            return;
          }
          visited[neighbor] = true;
          queue.add(neighbor);
        }

        visit(x - 1, y);
        visit(x + 1, y);
        visit(x, y - 1);
        visit(x, y + 1);
      }
      components.add(component);
    }
    return components;
  }

  List<_Component> _splitComponent(
    _Component component, {
    required int imageWidth,
    required int imageHeight,
    required int minArea,
  }) {
    if (component.area < minArea * 2.2 || maxSplitSeedsPerComponent < 2) {
      return [component];
    }

    final width = component.maxX - component.minX + 1;
    final height = component.maxY - component.minY + 1;
    if (width < 40 || height < 40) {
      return [component];
    }

    final localMask = List<bool>.filled(width * height, false);
    for (final index in component.pixelIndexes) {
      final x = index % imageWidth;
      final y = index ~/ imageWidth;
      localMask[(y - component.minY) * width + (x - component.minX)] = true;
    }

    final distances = _distanceTransform(localMask, width, height);
    final maxDistance = distances.fold<int>(0, math.max);
    if (maxDistance < 80) {
      return [component];
    }

    final threshold = math.max(
      60,
      (maxDistance * splitPeakThresholdRatio).round(),
    );
    final minSeedDistance = math.max(
      16,
      (math.min(width, height) * splitSeedSeparationRatio).round(),
    );
    final seeds = _distancePeaks(
      distances,
      localMask,
      width,
      height,
      threshold: threshold,
      minSeedDistance: minSeedDistance,
    );
    if (seeds.length < 2) {
      return [component];
    }

    final limitedSeeds = seeds.take(maxSplitSeedsPerComponent).toList();
    final split = List<_Component?>.filled(limitedSeeds.length, null);
    for (final index in component.pixelIndexes) {
      final x = index % imageWidth;
      final y = index ~/ imageWidth;
      final localX = x - component.minX;
      final localY = y - component.minY;
      var bestSeedIndex = 0;
      var bestDistanceSquared = 1 << 62;
      for (var seedIndex = 0; seedIndex < limitedSeeds.length; seedIndex++) {
        final seed = limitedSeeds[seedIndex];
        final dx = localX - seed.x;
        final dy = localY - seed.y;
        final distanceSquared = dx * dx + dy * dy;
        if (distanceSquared < bestDistanceSquared) {
          bestDistanceSquared = distanceSquared;
          bestSeedIndex = seedIndex;
        }
      }
      split[bestSeedIndex] ??= _Component(x, y);
      split[bestSeedIndex]!.include(x, y, index: index);
    }

    final validSplit = split
        .whereType<_Component>()
        .where((candidate) => candidate.area >= minArea)
        .toList();
    if (validSplit.length < 2) {
      return [component];
    }
    return validSplit;
  }

  List<int> _distanceTransform(List<bool> mask, int width, int height) {
    const largeDistance = 1 << 20;
    final distances = List<int>.filled(mask.length, 0);
    for (var index = 0; index < mask.length; index++) {
      distances[index] = mask[index] ? largeDistance : 0;
    }

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final index = y * width + x;
        if (!mask[index]) {
          continue;
        }
        var best = distances[index];
        if (x > 0) best = math.min(best, distances[index - 1] + 10);
        if (y > 0) best = math.min(best, distances[index - width] + 10);
        if (x > 0 && y > 0) {
          best = math.min(best, distances[index - width - 1] + 14);
        }
        if (x < width - 1 && y > 0) {
          best = math.min(best, distances[index - width + 1] + 14);
        }
        distances[index] = best;
      }
    }

    for (var y = height - 1; y >= 0; y--) {
      for (var x = width - 1; x >= 0; x--) {
        final index = y * width + x;
        if (!mask[index]) {
          continue;
        }
        var best = distances[index];
        if (x < width - 1) best = math.min(best, distances[index + 1] + 10);
        if (y < height - 1) {
          best = math.min(best, distances[index + width] + 10);
        }
        if (x < width - 1 && y < height - 1) {
          best = math.min(best, distances[index + width + 1] + 14);
        }
        if (x > 0 && y < height - 1) {
          best = math.min(best, distances[index + width - 1] + 14);
        }
        distances[index] = best;
      }
    }
    return distances;
  }

  List<_Seed> _distancePeaks(
    List<int> distances,
    List<bool> mask,
    int width,
    int height, {
    required int threshold,
    required int minSeedDistance,
  }) {
    final candidates = <_Seed>[];
    for (var y = 1; y < height - 1; y++) {
      for (var x = 1; x < width - 1; x++) {
        final index = y * width + x;
        final distance = distances[index];
        if (!mask[index] || distance < threshold) {
          continue;
        }
        var isPeak = true;
        for (var dy = -1; dy <= 1 && isPeak; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) {
              continue;
            }
            if (distances[(y + dy) * width + x + dx] > distance) {
              isPeak = false;
              break;
            }
          }
        }
        if (isPeak) {
          candidates.add(_Seed(x: x, y: y, distance: distance));
        }
      }
    }
    candidates.sort((a, b) => b.distance.compareTo(a.distance));

    final selected = <_Seed>[];
    final minDistanceSquared = minSeedDistance * minSeedDistance;
    for (final candidate in candidates) {
      var farEnough = true;
      for (final existing in selected) {
        final dx = candidate.x - existing.x;
        final dy = candidate.y - existing.y;
        if (dx * dx + dy * dy < minDistanceSquared) {
          farEnough = false;
          break;
        }
      }
      if (farEnough) {
        selected.add(candidate);
      }
    }
    return selected;
  }

  double _confidence(int foregroundArea, double boxArea) {
    if (boxArea <= 0) {
      return 0.0;
    }
    return (foregroundArea / boxArea).clamp(0.2, 0.95).toDouble();
  }
}

class _Component {
  _Component(int x, int y) : minX = x, maxX = x, minY = y, maxY = y;

  int minX;
  int maxX;
  int minY;
  int maxY;
  int area = 0;
  final List<int> pixelIndexes = [];

  void include(int x, int y, {required int index}) {
    area++;
    pixelIndexes.add(index);
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
}

class _Seed {
  const _Seed({required this.x, required this.y, required this.distance});

  final int x;
  final int y;
  final int distance;
}
