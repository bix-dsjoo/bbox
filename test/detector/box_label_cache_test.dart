import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/detector/box_label_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const metadata = BoxAutomationMetadata(
    suggestedLabelId: 1,
    reviewReasons: ['low_margin'],
    pipelineVersion: 'v1',
    policyVersion: 'policy-v1',
    detectorSha256: 'detector-hash',
  );

  test('same image hash geometry and pipeline hits cache', () {
    final cache = BoxLabelCache();
    final key = _key();

    cache.put(key, metadata);

    expect(cache.get(key), same(metadata));
    expect(cache.get(_key(x: 11)), isNull);
    expect(cache.get(_key(pipelineVersion: 'v2')), isNull);
  });

  test('invalidating image hash removes only matching entries', () {
    final cache = BoxLabelCache();
    cache.put(_key(), metadata);
    cache.put(_key(imageSha256: 'other-hash'), metadata);

    cache.invalidateImage('image-hash');

    expect(cache.get(_key()), isNull);
    expect(cache.get(_key(imageSha256: 'other-hash')), same(metadata));
  });
}

BoxLabelCacheKey _key({
  String imageSha256 = 'image-hash',
  double x = 10,
  String pipelineVersion = 'v1',
}) {
  return BoxLabelCacheKey(
    imageSha256: imageSha256,
    x: x,
    y: 12,
    width: 20,
    height: 24,
    pipelineVersion: pipelineVersion,
  );
}
