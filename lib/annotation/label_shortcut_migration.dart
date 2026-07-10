import 'annotation_rules.dart';
import 'models.dart';

AnnotationProject migrateMissingLabelShortcuts(AnnotationProject project) {
  final usedShortcuts = <String>{};
  for (final label in project.labels) {
    final shortcut = label.shortcut;
    if (shortcut != null && quickLabelShortcutSet.contains(shortcut)) {
      usedShortcuts.add(shortcut);
    }
  }

  final freeShortcuts = quickLabelShortcutSet
      .where((shortcut) => !usedShortcuts.contains(shortcut))
      .iterator;
  var changed = false;
  final migratedLabels = <LabelClass>[];

  for (final label in project.labels) {
    final shortcut = label.shortcut;
    if (shortcut != null && quickLabelShortcutSet.contains(shortcut)) {
      migratedLabels.add(label);
      continue;
    }

    if (freeShortcuts.moveNext()) {
      migratedLabels.add(label.copyWith(shortcut: freeShortcuts.current));
      changed = true;
    } else {
      migratedLabels.add(label.copyWith(shortcut: null));
      changed = changed || shortcut != null;
    }
  }

  return changed ? project.copyWith(labels: migratedLabels) : project;
}
