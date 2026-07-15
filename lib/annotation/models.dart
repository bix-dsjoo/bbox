enum ProjectStatus {
  empty,
  ready,
  scanning,
  detecting,
  dirty,
  exporting,
  error,
}

enum ImageStatus { queued, detecting, needsReview, confirmed, error }

enum BoxStatus { proposal, labeled, deleted }

enum LabelSource { auto, user }

String _enumName(Object value) => value.toString().split('.').last;

T _enumValue<T>(Iterable<T> values, String name, T fallback) {
  for (final value in values) {
    if (_enumName(value as Object) == name) {
      return value;
    }
  }
  return fallback;
}

class LabelCandidate {
  const LabelCandidate({required this.labelId, required this.score});

  final int labelId;
  final double score;

  Map<String, Object?> toJson() => {'labelId': labelId, 'score': score};

  factory LabelCandidate.fromJson(Map<String, Object?> json) {
    return LabelCandidate(
      labelId: json['labelId'] as int,
      score: (json['score'] as num).toDouble(),
    );
  }
}

class BoxAutomationMetadata {
  const BoxAutomationMetadata({
    this.suggestedLabelId,
    this.candidates = const [],
    this.reviewReasons = const [],
    required this.pipelineVersion,
    required this.policyVersion,
    required this.detectorSha256,
    this.classifierSha256,
    this.verifierSha256,
    this.embeddingUsed = false,
  });

  final int? suggestedLabelId;
  final List<LabelCandidate> candidates;
  final List<String> reviewReasons;
  final String pipelineVersion;
  final String policyVersion;
  final String detectorSha256;
  final String? classifierSha256;
  final String? verifierSha256;
  final bool embeddingUsed;

  BoxAutomationMetadata copyWith({
    Object? suggestedLabelId = _unchanged,
    List<LabelCandidate>? candidates,
    List<String>? reviewReasons,
  }) {
    return BoxAutomationMetadata(
      suggestedLabelId: identical(suggestedLabelId, _unchanged)
          ? this.suggestedLabelId
          : suggestedLabelId as int?,
      candidates: candidates ?? this.candidates,
      reviewReasons: reviewReasons ?? this.reviewReasons,
      pipelineVersion: pipelineVersion,
      policyVersion: policyVersion,
      detectorSha256: detectorSha256,
      classifierSha256: classifierSha256,
      verifierSha256: verifierSha256,
      embeddingUsed: embeddingUsed,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'suggestedLabelId': suggestedLabelId,
      'candidates': candidates.map((candidate) => candidate.toJson()).toList(),
      'reviewReasons': reviewReasons,
      'pipelineVersion': pipelineVersion,
      'policyVersion': policyVersion,
      'detectorSha256': detectorSha256,
      'classifierSha256': classifierSha256,
      'verifierSha256': verifierSha256,
      'embeddingUsed': embeddingUsed,
    };
  }

  factory BoxAutomationMetadata.fromJson(Map<String, Object?> json) {
    final candidates = json['candidates'] as List<Object?>? ?? const [];
    final reasons = json['reviewReasons'] as List<Object?>? ?? const [];
    return BoxAutomationMetadata(
      suggestedLabelId: json['suggestedLabelId'] as int?,
      candidates: candidates
          .cast<Map<String, Object?>>()
          .map(LabelCandidate.fromJson)
          .toList(growable: false),
      reviewReasons: reasons.cast<String>().toList(growable: false),
      pipelineVersion: json['pipelineVersion'] as String,
      policyVersion: json['policyVersion'] as String,
      detectorSha256: json['detectorSha256'] as String,
      classifierSha256: json['classifierSha256'] as String?,
      verifierSha256: json['verifierSha256'] as String?,
      embeddingUsed: json['embeddingUsed'] as bool? ?? false,
    );
  }
}

class LabelClass {
  const LabelClass({
    required this.id,
    required this.name,
    required this.color,
    this.shortcut,
    this.supercategory = 'object',
  });

  final int id;
  final String name;
  final int color;
  final String? shortcut;
  final String supercategory;

  LabelClass copyWith({
    int? id,
    String? name,
    int? color,
    Object? shortcut = _unchanged,
    String? supercategory,
  }) {
    return LabelClass(
      id: id ?? this.id,
      name: name ?? this.name,
      color: color ?? this.color,
      shortcut: identical(shortcut, _unchanged)
          ? this.shortcut
          : shortcut as String?,
      supercategory: supercategory ?? this.supercategory,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'color': color,
      'shortcut': shortcut,
      'supercategory': supercategory,
    };
  }

  factory LabelClass.fromJson(Map<String, Object?> json) {
    return LabelClass(
      id: json['id'] as int,
      name: json['name'] as String,
      color: json['color'] as int,
      shortcut: json['shortcut'] as String?,
      supercategory: json['supercategory'] as String? ?? 'object',
    );
  }
}

class BoundingBox {
  const BoundingBox({
    required this.id,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.status,
    this.labelId,
    this.labelSource,
    this.automation,
    this.confidence,
  });

  final String id;
  final double x;
  final double y;
  final double width;
  final double height;
  final BoxStatus status;
  final int? labelId;
  final LabelSource? labelSource;
  final BoxAutomationMetadata? automation;
  final double? confidence;

  double get area => width * height;

  bool get isDeleted => status == BoxStatus.deleted;

  bool get requiresLabelReview =>
      status == BoxStatus.proposal &&
      labelId == null &&
      automation?.suggestedLabelId != null &&
      automation!.reviewReasons.isNotEmpty;

  bool get isAutoLabeled =>
      status == BoxStatus.labeled &&
      labelId != null &&
      labelSource == LabelSource.auto;

  int? get displayLabelId => labelId ?? automation?.suggestedLabelId;

  BoundingBox copyWith({
    String? id,
    double? x,
    double? y,
    double? width,
    double? height,
    BoxStatus? status,
    Object? labelId = _unchanged,
    Object? labelSource = _unchanged,
    Object? automation = _unchanged,
    Object? confidence = _unchanged,
  }) {
    return BoundingBox(
      id: id ?? this.id,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      status: status ?? this.status,
      labelId: identical(labelId, _unchanged) ? this.labelId : labelId as int?,
      labelSource: identical(labelSource, _unchanged)
          ? this.labelSource
          : labelSource as LabelSource?,
      automation: identical(automation, _unchanged)
          ? this.automation
          : automation as BoxAutomationMetadata?,
      confidence: identical(confidence, _unchanged)
          ? this.confidence
          : confidence as double?,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'status': _enumName(status),
      'labelId': labelId,
      'labelSource': labelSource == null ? null : _enumName(labelSource!),
      'automation': automation?.toJson(),
      'confidence': confidence,
    };
  }

  factory BoundingBox.fromJson(Map<String, Object?> json) {
    return BoundingBox(
      id: json['id'] as String,
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
      status: _enumValue(
        BoxStatus.values,
        json['status'] as String,
        BoxStatus.proposal,
      ),
      labelId: json['labelId'] as int?,
      labelSource: json['labelSource'] == null
          ? null
          : _enumValue(
              LabelSource.values,
              json['labelSource'] as String,
              LabelSource.user,
            ),
      automation: json['automation'] == null
          ? null
          : BoxAutomationMetadata.fromJson(
              json['automation'] as Map<String, Object?>,
            ),
      confidence: (json['confidence'] as num?)?.toDouble(),
    );
  }
}

class AnnotatedImage {
  const AnnotatedImage({
    required this.id,
    required this.sourcePath,
    required this.displayName,
    this.importedFrom,
    required this.width,
    required this.height,
    required this.status,
    this.boxes = const [],
    this.contentSha256,
    this.errorMessage,
  });

  final int id;
  final String sourcePath;
  final String displayName;
  final String? importedFrom;
  final int width;
  final int height;
  final ImageStatus status;
  final List<BoundingBox> boxes;
  final String? contentSha256;
  final String? errorMessage;

  Iterable<BoundingBox> get visibleBoxes =>
      boxes.where((box) => !box.isDeleted);

  int get boxCount => visibleBoxes.length;

  int get unlabeledBoxCount => visibleBoxes
      .where((box) => box.status == BoxStatus.proposal || box.labelId == null)
      .length;

  int get labeledBoxCount => visibleBoxes
      .where((box) => box.status == BoxStatus.labeled && box.labelId != null)
      .length;

  AnnotatedImage copyWith({
    int? id,
    String? sourcePath,
    String? displayName,
    int? width,
    int? height,
    ImageStatus? status,
    List<BoundingBox>? boxes,
    Object? contentSha256 = _unchanged,
    Object? importedFrom = _unchanged,
    Object? errorMessage = _unchanged,
  }) {
    return AnnotatedImage(
      id: id ?? this.id,
      sourcePath: sourcePath ?? this.sourcePath,
      displayName: displayName ?? this.displayName,
      importedFrom: identical(importedFrom, _unchanged)
          ? this.importedFrom
          : importedFrom as String?,
      width: width ?? this.width,
      height: height ?? this.height,
      status: status ?? this.status,
      boxes: boxes ?? this.boxes,
      contentSha256: identical(contentSha256, _unchanged)
          ? this.contentSha256
          : contentSha256 as String?,
      errorMessage: identical(errorMessage, _unchanged)
          ? this.errorMessage
          : errorMessage as String?,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'sourcePath': sourcePath,
      'displayName': displayName,
      'importedFrom': importedFrom,
      'width': width,
      'height': height,
      'status': _enumName(status),
      'boxes': boxes.map((box) => box.toJson()).toList(),
      'contentSha256': contentSha256,
      'errorMessage': errorMessage,
    };
  }

  factory AnnotatedImage.fromJson(Map<String, Object?> json) {
    final boxesJson = json['boxes'] as List<Object?>? ?? const [];
    return AnnotatedImage(
      id: json['id'] as int,
      sourcePath: json['sourcePath'] as String,
      displayName: json['displayName'] as String,
      importedFrom: json['importedFrom'] as String?,
      width: json['width'] as int,
      height: json['height'] as int,
      status: _enumValue(
        ImageStatus.values,
        json['status'] as String,
        ImageStatus.queued,
      ),
      boxes: boxesJson
          .cast<Map<String, Object?>>()
          .map(BoundingBox.fromJson)
          .toList(growable: false),
      contentSha256: json['contentSha256'] as String?,
      errorMessage: json['errorMessage'] as String?,
    );
  }
}

class AnnotationProject {
  const AnnotationProject({
    required this.name,
    this.schemaVersion = 1,
    this.projectFilePath,
    this.status = ProjectStatus.empty,
    this.labels = const [],
    this.images = const [],
    this.detectorName = 'dummy',
    this.lastSavedAt,
  });

  factory AnnotationProject.empty({required String name}) {
    return AnnotationProject(name: name);
  }

  final int schemaVersion;
  final String name;
  final String? projectFilePath;
  final ProjectStatus status;
  final List<LabelClass> labels;
  final List<AnnotatedImage> images;
  final String detectorName;
  final DateTime? lastSavedAt;

  int get nextLabelId => labels.isEmpty
      ? 1
      : labels.map((label) => label.id).reduce((a, b) => a > b ? a : b) + 1;

  int get nextImageId => images.isEmpty
      ? 1
      : images.map((image) => image.id).reduce((a, b) => a > b ? a : b) + 1;

  AnnotationProject withLabel(LabelClass label) {
    return copyWith(labels: [...labels, label]);
  }

  AnnotationProject copyWith({
    int? schemaVersion,
    String? name,
    Object? projectFilePath = _unchanged,
    ProjectStatus? status,
    List<LabelClass>? labels,
    List<AnnotatedImage>? images,
    String? detectorName,
    Object? lastSavedAt = _unchanged,
  }) {
    return AnnotationProject(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      name: name ?? this.name,
      projectFilePath: identical(projectFilePath, _unchanged)
          ? this.projectFilePath
          : projectFilePath as String?,
      status: status ?? this.status,
      labels: labels ?? this.labels,
      images: images ?? this.images,
      detectorName: detectorName ?? this.detectorName,
      lastSavedAt: identical(lastSavedAt, _unchanged)
          ? this.lastSavedAt
          : lastSavedAt as DateTime?,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'name': name,
      'projectFilePath': projectFilePath,
      'status': _enumName(status),
      'labels': labels.map((label) => label.toJson()).toList(),
      'images': images.map((image) => image.toJson()).toList(),
      'detectorName': detectorName,
      'lastSavedAt': lastSavedAt?.toIso8601String(),
    };
  }

  factory AnnotationProject.fromJson(Map<String, Object?> json) {
    final labelsJson = json['labels'] as List<Object?>? ?? const [];
    final imagesJson = json['images'] as List<Object?>? ?? const [];
    return AnnotationProject(
      schemaVersion: json['schemaVersion'] as int? ?? 1,
      name: json['name'] as String,
      projectFilePath: json['projectFilePath'] as String?,
      status: _enumValue(
        ProjectStatus.values,
        json['status'] as String? ?? 'empty',
        ProjectStatus.empty,
      ),
      labels: labelsJson
          .cast<Map<String, Object?>>()
          .map(LabelClass.fromJson)
          .toList(growable: false),
      images: imagesJson
          .cast<Map<String, Object?>>()
          .map(AnnotatedImage.fromJson)
          .toList(growable: false),
      detectorName: json['detectorName'] as String? ?? 'dummy',
      lastSavedAt: json['lastSavedAt'] == null
          ? null
          : DateTime.parse(json['lastSavedAt'] as String),
    );
  }
}

const Object _unchanged = Object();
