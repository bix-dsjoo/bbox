import '../annotation/annotation_rules.dart';
import '../annotation/models.dart';

enum CocoExportScope { allImages, confirmedOnly }

class CocoExportOptions {
  const CocoExportOptions({
    this.scope = CocoExportScope.allImages,
    this.includeEmptyImages = true,
  });

  final CocoExportScope scope;
  final bool includeEmptyImages;
}

class CocoExportSummary {
  const CocoExportSummary({
    required this.unconfirmedImageCount,
    this.autoLabeledBoxCount = 0,
    this.userLabeledBoxCount = 0,
    this.reviewRequiredBoxCount = 0,
    required this.unlabeledProposalBoxCount,
    required this.errorImageCount,
    required this.blockingErrors,
  });

  final int unconfirmedImageCount;
  final int autoLabeledBoxCount;
  final int userLabeledBoxCount;
  final int reviewRequiredBoxCount;
  final int unlabeledProposalBoxCount;
  final int errorImageCount;
  final List<String> blockingErrors;

  bool get hasWarnings =>
      unconfirmedImageCount > 0 ||
      reviewRequiredBoxCount > 0 ||
      unlabeledProposalBoxCount > 0 ||
      errorImageCount > 0;

  bool get hasBlockingErrors => blockingErrors.isNotEmpty;
}

class CocoExportException implements Exception {
  CocoExportException(this.errors);

  final List<String> errors;

  @override
  String toString() => errors.join('\n');
}

class CocoExporter {
  const CocoExporter._();

  static CocoExportSummary validate(
    AnnotationProject project, {
    CocoExportOptions options = const CocoExportOptions(),
  }) {
    final images = _selectImages(project, options);
    var unconfirmed = 0;
    var autoLabeled = 0;
    var userLabeled = 0;
    var reviewRequired = 0;
    var unlabeledProposals = 0;
    var errors = 0;
    final blockingErrors = <String>[];

    for (final image in project.images) {
      if (image.status == ImageStatus.error) {
        errors++;
      }
    }

    for (final image in images) {
      if (image.status != ImageStatus.error &&
          image.status != ImageStatus.confirmed) {
        unconfirmed++;
      }
      for (final box in image.visibleBoxes) {
        if (box.status == BoxStatus.labeled && box.labelId != null) {
          if (box.labelSource == LabelSource.auto) {
            autoLabeled++;
          } else {
            userLabeled++;
          }
        } else if (box.requiresLabelReview) {
          reviewRequired++;
        } else {
          unlabeledProposals++;
        }
        if (box.status == BoxStatus.labeled) {
          if (!AnnotationRules.isBoxValid(
            box,
            imageWidth: image.width,
            imageHeight: image.height,
          )) {
            blockingErrors.add(
              'Invalid labeled box ${box.id} in ${image.displayName}',
            );
          }
          if (!_hasLabel(project, box.labelId)) {
            blockingErrors.add(
              'Missing label ${box.labelId} for box ${box.id}',
            );
          }
        }
      }
    }

    return CocoExportSummary(
      unconfirmedImageCount: unconfirmed,
      autoLabeledBoxCount: autoLabeled,
      userLabeledBoxCount: userLabeled,
      reviewRequiredBoxCount: reviewRequired,
      unlabeledProposalBoxCount: unlabeledProposals,
      errorImageCount: errors,
      blockingErrors: blockingErrors,
    );
  }

  static Map<String, Object?> build(
    AnnotationProject project, {
    CocoExportOptions options = const CocoExportOptions(),
  }) {
    final summary = validate(project, options: options);
    if (summary.hasBlockingErrors) {
      throw CocoExportException(summary.blockingErrors);
    }

    final categories = [...project.labels]
      ..sort((a, b) => a.id.compareTo(b.id));
    final images = _selectImages(project, options)
        .where((image) => image.status != ImageStatus.error)
        .where(
          (image) => options.includeEmptyImages || image.labeledBoxCount > 0,
        )
        .toList();

    var annotationId = 1;
    final annotations = <Map<String, Object?>>[];
    for (final image in images) {
      for (final box in image.visibleBoxes) {
        if (box.status != BoxStatus.labeled || box.labelId == null) {
          continue;
        }
        annotations.add({
          'id': annotationId++,
          'image_id': image.id,
          'category_id': box.labelId,
          'bbox': [box.x, box.y, box.width, box.height],
          'area': box.area,
          'iscrowd': 0,
        });
      }
    }

    return {
      'info': {
        'description': 'COCO export from bbox_labeler',
        'version': '1.0',
      },
      'licenses': <Object?>[],
      'images': [
        for (final image in images)
          {
            'id': image.id,
            'file_name': image.displayName,
            'width': image.width,
            'height': image.height,
          },
      ],
      'annotations': annotations,
      'categories': [
        for (final label in categories)
          {
            'id': label.id,
            'name': label.name,
            'supercategory': label.supercategory,
          },
      ],
    };
  }

  static List<AnnotatedImage> _selectImages(
    AnnotationProject project,
    CocoExportOptions options,
  ) {
    return project.images
        .where((image) {
          if (options.scope == CocoExportScope.confirmedOnly &&
              image.status != ImageStatus.confirmed) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  static bool _hasLabel(AnnotationProject project, int? labelId) {
    return labelId != null &&
        project.labels.any((label) => label.id == labelId);
  }
}
