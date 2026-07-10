import 'package:bbox_labeler/annotation/label_shortcut_migration.dart';
import 'package:bbox_labeler/annotation/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('migrateMissingLabelShortcuts', () {
    test('fills missing shortcuts without changing label ids or names', () {
      final project = AnnotationProject.empty(name: 'Old').copyWith(
        labels: const [
          LabelClass(id: 10, name: 'Bread', color: 0xff111111),
          LabelClass(id: 20, name: 'Cream', color: 0xff222222),
        ],
      );

      final migrated = migrateMissingLabelShortcuts(project);

      expect(migrated.labels[0].id, 10);
      expect(migrated.labels[0].name, 'Bread');
      expect(migrated.labels[0].shortcut, '1');
      expect(migrated.labels[1].id, 20);
      expect(migrated.labels[1].name, 'Cream');
      expect(migrated.labels[1].shortcut, '2');
    });

    test('preserves valid existing shortcuts and fills free slots', () {
      final project = AnnotationProject.empty(name: 'Mixed').copyWith(
        labels: const [
          LabelClass(id: 1, name: 'Bread', color: 0xff111111, shortcut: '3'),
          LabelClass(id: 2, name: 'Cream', color: 0xff222222),
        ],
      );

      final migrated = migrateMissingLabelShortcuts(project);

      expect(migrated.labels[0].shortcut, '3');
      expect(migrated.labels[1].shortcut, '1');
    });

    test('does not change box label ids or category ids', () {
      final project = AnnotationProject.empty(name: 'Old').copyWith(
        labels: const [
          LabelClass(id: 10, name: 'Bread', color: 0xff111111),
          LabelClass(id: 20, name: 'Cream', color: 0xff222222),
        ],
        images: const [
          AnnotatedImage(
            id: 1,
            sourcePath: 'a.jpg',
            displayName: 'a.jpg',
            width: 100,
            height: 100,
            status: ImageStatus.needsReview,
            boxes: [
              BoundingBox(
                id: 'box-1',
                x: 1,
                y: 2,
                width: 3,
                height: 4,
                status: BoxStatus.labeled,
                labelId: 20,
              ),
            ],
          ),
        ],
      );

      final migrated = migrateMissingLabelShortcuts(project);

      expect(migrated.images.single.boxes.single.labelId, 20);
      expect(migrated.labels.map((label) => label.id), [10, 20]);
    });
  });
}
