import '../annotation/models.dart';

class BoxLabelCacheKey {
  const BoxLabelCacheKey({
    required this.imageSha256,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.pipelineVersion,
  });

  final String imageSha256;
  final double x;
  final double y;
  final double width;
  final double height;
  final String pipelineVersion;

  @override
  int get hashCode =>
      Object.hash(imageSha256, x, y, width, height, pipelineVersion);

  @override
  bool operator ==(Object other) {
    return other is BoxLabelCacheKey &&
        imageSha256 == other.imageSha256 &&
        x == other.x &&
        y == other.y &&
        width == other.width &&
        height == other.height &&
        pipelineVersion == other.pipelineVersion;
  }
}

class BoxLabelCacheEntry {
  const BoxLabelCacheEntry({
    required this.status,
    required this.labelId,
    required this.labelSource,
    required this.automation,
  });

  factory BoxLabelCacheEntry.fromBox(BoundingBox box) {
    return BoxLabelCacheEntry(
      status: box.status,
      labelId: box.labelId,
      labelSource: box.labelSource,
      automation: box.automation!,
    );
  }

  final BoxStatus status;
  final int? labelId;
  final LabelSource? labelSource;
  final BoxAutomationMetadata automation;

  BoundingBox applyTo(BoundingBox box) => box.copyWith(
    status: status,
    labelId: labelId,
    labelSource: labelSource,
    automation: automation,
  );
}

class BoxLabelCache {
  final Map<BoxLabelCacheKey, BoxLabelCacheEntry> _entries = {};

  BoxAutomationMetadata? get(BoxLabelCacheKey key) => _entries[key]?.automation;

  void put(BoxLabelCacheKey key, BoxAutomationMetadata metadata) {
    _entries[key] = BoxLabelCacheEntry(
      status: BoxStatus.proposal,
      labelId: null,
      labelSource: null,
      automation: metadata,
    );
  }

  BoxLabelCacheEntry? getEntry(BoxLabelCacheKey key) => _entries[key];

  void putBox(BoxLabelCacheKey key, BoundingBox box) {
    if (box.automation == null) {
      return;
    }
    _entries[key] = BoxLabelCacheEntry.fromBox(box);
  }

  void invalidateImage(String imageSha256) {
    _entries.removeWhere((key, _) => key.imageSha256 == imageSha256);
  }

  void clear() => _entries.clear();
}
