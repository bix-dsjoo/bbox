import 'package:bbox_labeler/annotation/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('project json does not write removed legacy settings', () {
    const project = AnnotationProject(name: 'Bread project');
    final removedKey =
        'auto'
        'Label';

    final json = project.toJson();

    expect(json.containsKey(removedKey), isFalse);
  });

  test('project json ignores removed legacy settings', () {
    final removedKey =
        'auto'
        'Label';
    final removedPathKey =
        'train'
        'FolderPath';
    final loaded = AnnotationProject.fromJson({
      'schemaVersion': 1,
      'name': 'Old project',
      'status': 'ready',
      'labels': <Object?>[],
      'images': <Object?>[],
      'detectorName': 'dummy',
      removedKey: {
        removedPathKey: 'C:/workspace/bbox/legacy-references',
        'extractorName': 'efficientnet_b0',
      },
    });

    expect(loaded.toJson().containsKey(removedKey), isFalse);
  });
}
