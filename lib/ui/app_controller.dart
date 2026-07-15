import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../annotation/annotation_rules.dart';
import '../annotation/box_display_order.dart';
import '../annotation/default_labels.dart';
import '../annotation/label_shortcut_migration.dart';
import '../annotation/models.dart';
import '../detector/auto_box_service.dart';
import '../detector/box_label_cache.dart';
import '../detector/bread_worker_client.dart';
import '../detector/detector.dart';
import '../detector/worker_protocol.dart';
import '../export/coco_exporter.dart';
import '../image_import/image_scanner.dart';
import '../project/project_library.dart';
import '../project/project_snapshot_service.dart';
import '../project/project_store.dart';
import '../project/source_relink_service.dart';
import 'workbench_copy.dart';

enum SaveStatus { saved, saving, failed }

enum ProjectActivity { idle, importing, validating, exporting }

class ImageViewLoadState {
  const ImageViewLoadState({this.imageId, this.isLoading = false});

  final int? imageId;
  final bool isLoading;
}

enum SelectedImageViewState { unknown, ready, missing }

typedef ProjectSaveOperation =
    Future<AnnotationProject> Function(
      AnnotationProject project,
      String projectFilePath,
    );

class ImageImportProgress {
  const ImageImportProgress({
    required this.total,
    required this.processed,
    required this.added,
    required this.skipped,
    this.errors = 0,
  });

  final int total;
  final int processed;
  final int added;
  final int skipped;
  final int errors;

  bool get isComplete => total > 0 ? processed >= total : true;
}

class AppController extends ChangeNotifier {
  AppController({
    ProjectLibrary? projectLibrary,
    ProjectSnapshotService? projectSnapshotService,
    SourceRelinkService? sourceRelinkService,
    ProjectSaveOperation? projectSaver,
    AutoBoxRuntime? autoBoxRuntime,
    BoxLabelCache? boxLabelCache,
  }) : _projectLibrary = projectLibrary ?? ProjectLibrary.appData(),
       _projectSnapshotService =
           projectSnapshotService ?? ProjectSnapshotService(),
       _sourceRelinkService =
           sourceRelinkService ?? const SourceRelinkService(),
       _projectSaver = projectSaver ?? ProjectStore.save,
       _autoBoxRuntime = autoBoxRuntime ?? defaultAutoBoxService(),
       _boxLabelCache = boxLabelCache ?? BoxLabelCache() {
    _autoBoxRuntime.addListener(_handleAutoBoxRuntimeChanged);
  }

  final ProjectLibrary _projectLibrary;
  final ProjectSnapshotService _projectSnapshotService;
  final SourceRelinkService _sourceRelinkService;
  final ProjectSaveOperation _projectSaver;
  final AutoBoxRuntime _autoBoxRuntime;
  final BoxLabelCache _boxLabelCache;

  AnnotationProject? _project;
  int? _selectedImageId;
  String? _selectedBoxId;
  Object? lastError;
  Future<void> _autoSaveChain = Future<void>.value();
  List<ProjectLibraryEntry> _projectLibraryEntries = const [];
  bool _isProjectLibraryLoading = false;
  String? _currentLibraryProjectId;
  SaveStatus _saveStatus = SaveStatus.saved;
  Object? _lastSaveError;
  ProjectActivity _projectActivity = ProjectActivity.idle;
  ImageImportProgress? _imageImportProgress;
  ImageViewLoadState _imageViewLoadState = const ImageViewLoadState();
  String? lastUserMessage;
  int _projectEpoch = 0;
  int _nextAutoBoxRequestToken = 0;
  int? _activeAutoBoxRequestToken;
  Timer? _classificationDebounce;
  int _classificationGeneration = 0;
  bool _classificationInFlight = false;
  bool _classificationPending = false;
  final Map<int, String> _pipelineVersionsByImageId = {};
  Map<int, SourceAvailability> _sourceAvailability = const {};
  int _sourceRefreshGeneration = 0;
  bool _isDisposed = false;

  final List<AnnotationProject> _undoStack = [];
  final List<AnnotationProject> _redoStack = [];

  AnnotationProject? get project => _project;

  List<ProjectLibraryEntry> get projectLibraryEntries => _projectLibraryEntries;

  bool get isProjectLibraryLoading => _isProjectLibraryLoading;

  SaveStatus get saveStatus => _saveStatus;

  Object? get lastSaveError => _lastSaveError;

  Map<int, SourceAvailability> get sourceAvailability =>
      Map.unmodifiable(_sourceAvailability);

  int get missingSourceCount => _sourceAvailability.values
      .where((value) => value == SourceAvailability.missing)
      .length;

  SourceAvailability get selectedSourceAvailability =>
      _sourceAvailability[selectedImageId] ?? SourceAvailability.unknown;

  void clearLastUserMessage() {
    if (lastUserMessage == null) {
      return;
    }
    lastUserMessage = null;
    notifyListeners();
  }

  int? get selectedImageId => _selectedImageId;

  String? get selectedBoxId => _selectedBoxId;

  bool get hasProject => _project != null;

  ProjectActivity get projectActivity => _projectActivity;

  ProjectActivity get activity => _projectActivity;

  ImageImportProgress? get imageImportProgress => _imageImportProgress;

  ImageImportProgress? get lastImportProgress => _imageImportProgress;

  ImageViewLoadState get imageViewLoadState => _imageViewLoadState;

  bool get isAutoBoxRunning => _activeAutoBoxRequestToken != null;

  bool get isAutomationRunning => isAutoBoxRunning;

  AutoBoxState get autoBoxState => _autoBoxRuntime.state;

  bool get canRunAutoBoxes {
    final image = selectedImage;
    final serviceReady =
        autoBoxState == AutoBoxState.ready ||
        autoBoxState == AutoBoxState.failed;
    return image != null &&
        image.status != ImageStatus.error &&
        image.width > 0 &&
        image.height > 0 &&
        !isAutomationRunning &&
        serviceReady;
  }

  Future<void> warmUpAutoBoxes() => _autoBoxRuntime.warmUp();

  Future<void> shutdownAutoBoxes() => _autoBoxRuntime.shutdown();

  SelectedImageViewState get selectedImageViewState =>
      switch (selectedSourceAvailability) {
        SourceAvailability.available => SelectedImageViewState.ready,
        SourceAvailability.missing => SelectedImageViewState.missing,
        SourceAvailability.unknown => SelectedImageViewState.unknown,
      };

  AnnotatedImage? get selectedImage {
    final project = _project;
    final selectedImageId = _selectedImageId;
    if (project == null || selectedImageId == null) {
      return null;
    }
    for (final image in project.images) {
      if (image.id == selectedImageId) {
        return image;
      }
    }
    return null;
  }

  BoundingBox? get selectedBox {
    final image = selectedImage;
    final selectedBoxId = _selectedBoxId;
    if (image == null || selectedBoxId == null) {
      return null;
    }
    for (final box in image.visibleBoxes) {
      if (box.id == selectedBoxId) {
        return box;
      }
    }
    return null;
  }

  bool get canConfirmSelectedImage {
    final image = selectedImage;
    return image != null && AnnotationRules.canConfirm(image);
  }

  String? get selectedImageCompletionBlockerReason {
    final image = selectedImage;
    if (image == null) {
      return null;
    }
    if (image.status == ImageStatus.error ||
        image.width <= 0 ||
        image.height <= 0) {
      return WorkbenchCopy.completionBlockedInvalidImage;
    }
    var invalidCount = 0;
    var unlabeledCount = 0;
    for (final box in image.visibleBoxes) {
      if (!AnnotationRules.isBoxValid(
        box,
        imageWidth: image.width,
        imageHeight: image.height,
      )) {
        invalidCount++;
      }
      if (box.status != BoxStatus.labeled || box.labelId == null) {
        unlabeledCount++;
      }
    }
    if (invalidCount > 0) {
      return WorkbenchCopy.invalidBoxCount(invalidCount);
    }
    if (unlabeledCount > 0) {
      return WorkbenchCopy.unlabeledBoxCount(unlabeledCount);
    }
    return null;
  }

  bool get canUndo => _undoStack.isNotEmpty;

  bool get canRedo => _redoStack.isNotEmpty;

  void createProject(String name, {String? projectFilePath}) {
    _undoStack.clear();
    _redoStack.clear();
    _projectEpoch++;
    _project = AnnotationProject.empty(name: name).copyWith(
      projectFilePath: projectFilePath,
      status: ProjectStatus.ready,
      labels: createDefaultLabels(),
    );
    _resetSourceAvailability(_project);
    _currentLibraryProjectId = _libraryProjectIdForPath(projectFilePath);
    _selectedImageId = null;
    _selectedBoxId = null;
    _projectActivity = ProjectActivity.idle;
    _imageImportProgress = null;
    _imageViewLoadState = const ImageViewLoadState();
    _activeAutoBoxRequestToken = null;
    _saveStatus = SaveStatus.saved;
    _lastSaveError = null;
    notifyListeners();
  }

  void loadProject(AnnotationProject project) {
    _undoStack.clear();
    _redoStack.clear();
    _projectEpoch++;
    final migratedProject = migrateMissingLabelShortcuts(project);
    final migrated = !identical(migratedProject, project);
    _project = migratedProject;
    _resetSourceAvailability(_project);
    _currentLibraryProjectId = _libraryProjectIdForPath(
      _project!.projectFilePath,
    );
    _selectedImageId = _project!.images.isEmpty
        ? null
        : _project!.images.first.id;
    _selectedBoxId = null;
    _projectActivity = ProjectActivity.idle;
    _imageImportProgress = null;
    _imageViewLoadState = ImageViewLoadState(
      imageId: _selectedImageId,
      isLoading: false,
    );
    _activeAutoBoxRequestToken = null;
    _saveStatus = SaveStatus.saved;
    _lastSaveError = null;
    if (migrated && _project!.projectFilePath != null) {
      _scheduleAutoSave();
    }
    notifyListeners();
  }

  Future<void> openProject(String projectFilePath) async {
    final requestEpoch = _projectEpoch;
    final opened = await ProjectStore.load(projectFilePath);
    if (requestEpoch != _projectEpoch) return;
    loadProject(opened);
    await refreshSourceAvailability();
  }

  Future<void> loadProjectLibrary() async {
    _isProjectLibraryLoading = true;
    notifyListeners();
    try {
      _projectLibraryEntries = await _projectLibrary.listProjects();
    } finally {
      _isProjectLibraryLoading = false;
      notifyListeners();
    }
  }

  Future<void> createLibraryProject(String name) async {
    _undoStack.clear();
    _redoStack.clear();
    final created = await _projectLibrary.createProject(name);
    _projectEpoch++;
    _project = created;
    _resetSourceAvailability(_project);
    _currentLibraryProjectId = _libraryProjectIdForPath(
      _project!.projectFilePath,
    );
    _selectedImageId = null;
    _selectedBoxId = null;
    _projectActivity = ProjectActivity.idle;
    _imageImportProgress = null;
    _imageViewLoadState = const ImageViewLoadState();
    _activeAutoBoxRequestToken = null;
    _projectLibraryEntries = await _projectLibrary.listProjects();
    _saveStatus = SaveStatus.saved;
    _lastSaveError = null;
    notifyListeners();
  }

  Future<void> openLibraryProject(String id) async {
    final requestEpoch = _projectEpoch;
    final opened = await _projectLibrary.openProject(id);
    if (requestEpoch != _projectEpoch) return;
    loadProject(opened);
    _currentLibraryProjectId = id;
    _projectLibraryEntries = await _projectLibrary.listProjects();
    _saveStatus = SaveStatus.saved;
    _lastSaveError = null;
    notifyListeners();
    await refreshSourceAvailability();
  }

  Future<void> renameLibraryProject(String id, String name) async {
    final renamed = await _projectLibrary.renameProject(id, name);
    if (_currentLibraryProjectId == id ||
        _project?.projectFilePath == renamed.projectFilePath) {
      _projectEpoch++;
      _project = renamed;
      _currentLibraryProjectId = id;
    }
    _projectLibraryEntries = await _projectLibrary.listProjects();
    _saveStatus = SaveStatus.saved;
    _lastSaveError = null;
    notifyListeners();
  }

  Future<void> deleteLibraryProject(String id) async {
    await _projectLibrary.deleteProject(id);
    _projectLibraryEntries = await _projectLibrary.listProjects();
    if (_currentLibraryProjectId == id) {
      _projectEpoch++;
      _project = null;
      _resetSourceAvailability(null);
      _currentLibraryProjectId = null;
      _selectedImageId = null;
      _selectedBoxId = null;
      _undoStack.clear();
      _redoStack.clear();
      _projectActivity = ProjectActivity.idle;
      _imageImportProgress = null;
      _imageViewLoadState = const ImageViewLoadState();
      _activeAutoBoxRequestToken = null;
      _saveStatus = SaveStatus.saved;
      _lastSaveError = null;
    }
    notifyListeners();
  }

  @visibleForTesting
  void debugSetImageViewLoadState(ImageViewLoadState state) {
    _imageViewLoadState = state;
    notifyListeners();
  }

  @visibleForTesting
  void debugSetImportProgressForTest(ImageImportProgress? progress) {
    _imageImportProgress = progress;
    _projectActivity = ProjectActivity.importing;
    notifyListeners();
  }

  @visibleForTesting
  void debugSetProjectActivityForTest(ProjectActivity activity) {
    _projectActivity = activity;
    notifyListeners();
  }

  @visibleForTesting
  void debugSetProjectForTest(AnnotationProject project) {
    _projectEpoch++;
    _project = project;
    _resetSourceAvailability(_project);
    _repairSelection();
    notifyListeners();
  }

  Future<void> saveProject([String? projectFilePath]) async {
    _saveStatus = SaveStatus.saving;
    _lastSaveError = null;
    notifyListeners();
    try {
      final targetPath = projectFilePath ?? _requireProject().projectFilePath;
      if (targetPath == null) {
        throw StateError('Project path is required.');
      }
      await _autoSaveChain;
      _project = await ProjectStore.save(_requireProject(), targetPath);
      _currentLibraryProjectId = _libraryProjectIdForPath(
        _project!.projectFilePath,
      );
      await _refreshLibraryEntryIfNeeded();
      _saveStatus = SaveStatus.saved;
      _lastSaveError = null;
      notifyListeners();
    } catch (error) {
      lastError = error;
      _lastSaveError = error;
      _saveStatus = SaveStatus.failed;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> saveProjectSnapshot(String targetPath) async {
    final requestEpoch = _projectEpoch;
    try {
      await _waitForAutoSaveIdle();
      if (_isDisposed || requestEpoch != _projectEpoch) return;
      await _projectSnapshotService.writeSnapshot(
        _requireProject(),
        targetPath,
      );
      if (_isDisposed || requestEpoch != _projectEpoch) return;
      lastUserMessage = 'Project snapshot saved to $targetPath';
      notifyListeners();
    } catch (error) {
      if (_isDisposed || requestEpoch != _projectEpoch) return;
      lastError = error;
      lastUserMessage =
          'Could not save the project snapshot. Check the destination path, permissions, and disk space, then try again.';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> importProjectSnapshot(String sourcePath) async {
    final requestEpoch = _projectEpoch;
    try {
      await _waitForAutoSaveIdle();
      if (_isDisposed || requestEpoch != _projectEpoch) return;
      final source = await _projectSnapshotService.readSnapshot(sourcePath);
      if (_isDisposed || requestEpoch != _projectEpoch) return;
      final imported = await _projectLibrary.importProject(source);
      if (_isDisposed || requestEpoch != _projectEpoch) return;
      final entries = await _projectLibrary.listProjects();
      await _waitForAutoSaveIdle();
      if (_isDisposed || requestEpoch != _projectEpoch) return;
      loadProject(imported);
      _currentLibraryProjectId = _libraryProjectIdForPath(
        imported.projectFilePath,
      );
      _projectLibraryEntries = entries;
      await _refreshSourceAvailabilityAfterPrimaryOperation(
        projectEpoch: _projectEpoch,
        warning:
            'Project imported, but source availability could not be checked. Check storage access and refresh availability.',
      );
    } catch (error) {
      if (_isDisposed || requestEpoch != _projectEpoch) return;
      lastError = error;
      lastUserMessage =
          'Could not import the project snapshot. Verify the file and choose a writable project library, then try again.';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> addImagesFromFolder(
    String folderPath, {
    Detector? detector,
  }) async {
    _projectActivity = ProjectActivity.importing;
    _imageImportProgress = null;
    notifyListeners();
    try {
      final scanned = await ImageScanner.scanFolder(folderPath);
      await _addScannedImages(scanned, importedFrom: folderPath);
    } catch (_) {
      _projectActivity = ProjectActivity.idle;
      _imageImportProgress = null;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> addImageFiles(
    List<String> filePaths, {
    Detector? detector,
  }) async {
    _projectActivity = ProjectActivity.importing;
    _imageImportProgress = null;
    notifyListeners();
    try {
      final scanned = await ImageScanner.scanFiles(filePaths);
      await _addScannedImages(scanned);
    } catch (_) {
      _projectActivity = ProjectActivity.idle;
      _imageImportProgress = null;
      notifyListeners();
      rethrow;
    }
  }

  @Deprecated('Use addImagesFromFolder instead.')
  Future<void> importImagesFromFolder(String folderPath, {Detector? detector}) {
    return addImagesFromFolder(folderPath, detector: detector);
  }

  Future<List<String>> validateSourceFiles() async {
    await refreshSourceAvailability();
    final project = _project;
    if (project == null) return const [];
    return [
      for (final image in project.images)
        if (_sourceAvailability[image.id] == SourceAvailability.missing)
          image.sourcePath,
    ];
  }

  Future<void> refreshSourceAvailability({bool reportFailure = true}) async {
    final project = _project;
    if (project == null || _isDisposed) return;
    final projectEpoch = _projectEpoch;
    final generation = ++_sourceRefreshGeneration;
    _projectActivity = ProjectActivity.validating;
    notifyListeners();
    try {
      final inspected = await _sourceRelinkService.inspectSources(
        project.images,
      );
      if (_isDisposed ||
          projectEpoch != _projectEpoch ||
          generation != _sourceRefreshGeneration) {
        return;
      }
      final current = _project;
      if (current == null) return;
      _sourceAvailability = {
        for (final image in current.images)
          image.id: inspected[image.id] ?? SourceAvailability.unknown,
      };
    } catch (error) {
      if (!_isDisposed &&
          reportFailure &&
          projectEpoch == _projectEpoch &&
          generation == _sourceRefreshGeneration) {
        lastError = error;
        lastUserMessage =
            'Could not check source files. Check file access and reconnect the storage location, then try again.';
      }
      rethrow;
    } finally {
      if (!_isDisposed &&
          projectEpoch == _projectEpoch &&
          generation == _sourceRefreshGeneration &&
          _projectActivity == ProjectActivity.validating) {
        _projectActivity = ProjectActivity.idle;
        notifyListeners();
      }
    }
  }

  Future<SourceRelinkResult> relinkSourceFiles(List<String> paths) async {
    return _relink(
      (missingImages) => _sourceRelinkService.relinkFiles(
        missingImages: missingImages,
        candidatePaths: paths,
      ),
    );
  }

  Future<SourceRelinkResult> relinkSelectedSourceFile(String path) async {
    final image = selectedImage;
    if (image == null ||
        _sourceAvailability[image.id] != SourceAvailability.missing) {
      return const SourceRelinkResult(
        matchedPaths: {},
        matchedImportedFrom: {},
        unresolvedImageIds: {},
        ambiguousImageIds: {},
      );
    }
    return _relink(
      (missingImages) => _sourceRelinkService.relinkFiles(
        missingImages: [image],
        candidatePaths: [path],
      ),
      requestedImages: [image],
    );
  }

  Future<SourceRelinkResult> relinkSourceFolder(String folderPath) async {
    return _relink(
      (missingImages) => _sourceRelinkService.relinkFolder(
        missingImages: missingImages,
        folderPath: folderPath,
      ),
    );
  }

  List<AnnotatedImage> _missingImages() => [
    for (final image in _requireProject().images)
      if (_sourceAvailability[image.id] == SourceAvailability.missing) image,
  ];

  Future<SourceRelinkResult> _relink(
    Future<SourceRelinkResult> Function(List<AnnotatedImage> missingImages)
    operation, {
    List<AnnotatedImage>? requestedImages,
  }) async {
    final projectEpoch = _projectEpoch;
    final missingImages = requestedImages ?? _missingImages();
    final originalPaths = {
      for (final image in missingImages) image.id: image.sourcePath,
    };
    _projectActivity = ProjectActivity.validating;
    notifyListeners();
    try {
      final result = await operation(missingImages);
      if (_isDisposed || projectEpoch != _projectEpoch) return result;
      var appliedCount = 0;
      if (result.matchedPaths.isNotEmpty) {
        final project = _requireProject();
        final appliedPaths = <int, String>{};
        final appliedImportedFrom = <int, String>{};
        for (final image in project.images) {
          final matchedPath = result.matchedPaths[image.id];
          if (matchedPath != null &&
              originalPaths[image.id] == image.sourcePath) {
            appliedPaths[image.id] = matchedPath;
            final importedFrom = result.matchedImportedFrom[image.id];
            if (importedFrom != null) {
              appliedImportedFrom[image.id] = importedFrom;
            }
          }
        }
        appliedCount = appliedPaths.length;
        if (appliedPaths.isNotEmpty) {
          _project = _projectWithRelinkedSources(
            project,
            appliedPaths,
            appliedImportedFrom,
          );
          for (var index = 0; index < _undoStack.length; index++) {
            _undoStack[index] = _projectWithRelinkedSources(
              _undoStack[index],
              appliedPaths,
              appliedImportedFrom,
            );
          }
          for (var index = 0; index < _redoStack.length; index++) {
            _redoStack[index] = _projectWithRelinkedSources(
              _redoStack[index],
              appliedPaths,
              appliedImportedFrom,
            );
          }
          _classificationDebounce?.cancel();
          _classificationGeneration++;
          _classificationPending = false;
          _scheduleAutoSave();
        }
      }
      final refreshed = await _refreshSourceAvailabilityAfterPrimaryOperation(
        projectEpoch: projectEpoch,
        warning:
            'Reconnected $appliedCount source file(s), but source availability could not be checked. Check storage access and refresh availability.',
      );
      if (refreshed && !_isDisposed && projectEpoch == _projectEpoch) {
        lastUserMessage = appliedCount > 0
            ? 'Reconnected $appliedCount source file(s).'
            : 'No source files were reconnected. Review unresolved or ambiguous matches and choose a specific file if needed.';
        notifyListeners();
      }
      return result;
    } catch (error) {
      if (!_isDisposed && projectEpoch == _projectEpoch) {
        lastError = error;
        lastUserMessage =
            'Could not reconnect source files. Check the selected files, folder access, and image dimensions, then try again.';
        notifyListeners();
      }
      rethrow;
    } finally {
      if (!_isDisposed &&
          projectEpoch == _projectEpoch &&
          _projectActivity == ProjectActivity.validating) {
        _projectActivity = ProjectActivity.idle;
        notifyListeners();
      }
    }
  }

  Future<bool> _refreshSourceAvailabilityAfterPrimaryOperation({
    required int projectEpoch,
    required String warning,
  }) async {
    try {
      await refreshSourceAvailability(reportFailure: false);
      return !_isDisposed && projectEpoch == _projectEpoch;
    } catch (error) {
      if (!_isDisposed && projectEpoch == _projectEpoch) {
        lastError = error;
        lastUserMessage = warning;
        notifyListeners();
      }
      return false;
    }
  }

  AnnotationProject _projectWithRelinkedSources(
    AnnotationProject project,
    Map<int, String> matchedPaths,
    Map<int, String> matchedImportedFrom,
  ) {
    return project.copyWith(
      images: [
        for (final image in project.images)
          if (matchedPaths.containsKey(image.id))
            image.copyWith(
              sourcePath: matchedPaths[image.id],
              importedFrom: matchedImportedFrom[image.id],
            )
          else
            image,
      ],
    );
  }

  void removeImageFromProject(int imageId) {
    final project = _project;
    if (project == null) {
      return;
    }
    final exists = project.images.any((image) => image.id == imageId);
    if (!exists) {
      return;
    }
    _recordUndo();
    final nextImages = <AnnotatedImage>[
      for (final image in project.images)
        if (image.id != imageId) image,
    ];
    _project = project.copyWith(
      images: nextImages,
      status: ProjectStatus.ready,
    );
    _sourceAvailability = Map<int, SourceAvailability>.from(_sourceAvailability)
      ..remove(imageId);
    _repairSelectionAfterRemoval();
    _imageViewLoadState = ImageViewLoadState(
      imageId: _selectedImageId,
      isLoading: false,
    );
    _scheduleAutoSave();
    notifyListeners();
  }

  void selectImage(int imageId) {
    _selectedImageId = imageId;
    _selectedBoxId = null;
    _imageViewLoadState = ImageViewLoadState(
      imageId: imageId,
      isLoading: false,
    );
    notifyListeners();
  }

  void selectBox(String? boxId) {
    _selectedBoxId = boxId;
    notifyListeners();
  }

  void addBox({
    required double x,
    required double y,
    required double width,
    required double height,
  }) {
    final image = selectedImage;
    if (image == null) {
      return;
    }
    _recordUndo();
    final box = AnnotationRules.clampBox(
      BoundingBox(
        id: 'manual-${DateTime.now().microsecondsSinceEpoch}',
        x: x,
        y: y,
        width: width,
        height: height,
        status: BoxStatus.proposal,
      ),
      imageWidth: image.width,
      imageHeight: image.height,
      minSize: 2,
    );
    _replaceSelectedImage(
      image.copyWith(
        status: ImageStatus.needsReview,
        boxes: [...image.boxes, box],
      ),
    );
    _selectedBoxId = box.id;
    _scheduleAutoSave();
    notifyListeners();
    scheduleSelectedBoxClassification();
  }

  void moveSelectedBox(double dx, double dy) {
    _editSelectedBox((image, box) {
      return AnnotationRules.clampBox(
        box.copyWith(x: box.x + dx, y: box.y + dy),
        imageWidth: image.width,
        imageHeight: image.height,
      );
    });
  }

  void resizeSelectedBox(double width, double height) {
    _editSelectedBox((image, box) {
      final maxWidth = image.width - box.x;
      final maxHeight = image.height - box.y;
      return AnnotationRules.clampBox(
        box.copyWith(
          width: width.clamp(2, maxWidth).toDouble(),
          height: height.clamp(2, maxHeight).toDouble(),
        ),
        imageWidth: image.width,
        imageHeight: image.height,
      );
    });
  }

  void setSelectedBoxGeometry({
    required double x,
    required double y,
    required double width,
    required double height,
  }) {
    _editSelectedBox((image, box) {
      return AnnotationRules.clampBox(
        box.copyWith(x: x, y: y, width: width, height: height),
        imageWidth: image.width,
        imageHeight: image.height,
      );
    });
  }

  void deleteSelectedBox() {
    final image = selectedImage;
    final boxId = _selectedBoxId;
    if (image == null || boxId == null) {
      return;
    }
    _recordUndo();
    _replaceSelectedImage(AnnotationRules.deleteBox(image, boxId: boxId));
    _selectedBoxId = null;
    _scheduleAutoSave();
    notifyListeners();
  }

  int? nextImageNeedingWorkId({int? afterImageId}) {
    final project = _project;
    if (project == null || project.images.isEmpty) {
      return null;
    }
    final startIndex = afterImageId == null
        ? -1
        : project.images.indexWhere((image) => image.id == afterImageId);
    for (var index = startIndex + 1; index < project.images.length; index++) {
      final image = project.images[index];
      if (_imageNeedsWork(image)) {
        return image.id;
      }
    }
    final endIndex = startIndex < 0 ? project.images.length : startIndex;
    for (var index = 0; index < endIndex; index++) {
      final image = project.images[index];
      if (_imageNeedsWork(image)) {
        return image.id;
      }
    }
    return null;
  }

  String? nextBoxNeedingLabelId(AnnotatedImage image, {String? afterBoxId}) {
    final boxes = BoxDisplayOrder.sorted(image);
    if (boxes.isEmpty) {
      return null;
    }
    final startIndex = afterBoxId == null
        ? -1
        : boxes.indexWhere((box) => box.id == afterBoxId);
    for (var index = startIndex + 1; index < boxes.length; index++) {
      final box = boxes[index];
      if (_boxNeedsLabel(box)) {
        return box.id;
      }
    }
    final endIndex = startIndex < 0 ? boxes.length : startIndex;
    for (var index = 0; index < endIndex; index++) {
      final box = boxes[index];
      if (_boxNeedsLabel(box)) {
        return box.id;
      }
    }
    return null;
  }

  Future<void> detectSelectedImage({
    bool replaceExisting = false,
    Detector? detector,
    DetectionOptions options = const DetectionOptions(),
  }) async {
    final project = _project;
    final image = selectedImage;
    if (project == null ||
        image == null ||
        image.status == ImageStatus.error ||
        isAutomationRunning) {
      return;
    }
    if (image.visibleBoxes.isNotEmpty && !replaceExisting) {
      lastUserMessage = WorkbenchCopy.autoBoxesReplacementConfirmationRequired;
      notifyListeners();
      return;
    }
    final activeDetector = detector ?? _autoBoxRuntime;
    final requestProjectEpoch = _projectEpoch;
    final requestImageId = image.id;
    final requestSourcePath = image.sourcePath;
    final previousProject = project;
    final previousImage = image;
    final previousSelectedBoxId = _selectedBoxId;
    final requestToken = ++_nextAutoBoxRequestToken;
    _activeAutoBoxRequestToken = requestToken;
    lastUserMessage = WorkbenchCopy.autoBoxesRunning;
    notifyListeners();

    try {
      final result = await _detectWithProgress(
        activeDetector,
        image,
        options: options,
      );

      if (!_isCurrentAutoBoxRequest(
        requestProjectEpoch,
        requestImageId,
        requestSourcePath,
      )) {
        _clearStaleAutoBoxActivity(requestToken);
        return;
      }

      if (result.errorMessage != null) {
        _project = previousProject;
        _selectedBoxId = previousSelectedBoxId;
        lastError = result.errorMessage;
        lastUserMessage = WorkbenchCopy.autoBoxesFailed;
        return;
      }

      _undoStack.add(previousProject);
      _redoStack.clear();
      _project = previousProject;
      final previousHash = previousImage.contentSha256;
      if (previousHash != null &&
          result.imageSha256 != null &&
          previousHash != result.imageSha256) {
        _boxLabelCache.invalidateImage(previousHash);
      }
      if (result.pipelineVersion case final pipelineVersion?) {
        _pipelineVersionsByImageId[previousImage.id] = pipelineVersion;
      }
      final detectedBoxes = _normalizeDetectionLabelIds(project, result.boxes);
      final updated = previousImage.copyWith(
        status: ImageStatus.needsReview,
        boxes: detectedBoxes,
        contentSha256: result.imageSha256,
        errorMessage: null,
      );
      _replaceSelectedImage(updated);
      _project = _project!.copyWith(detectorName: result.detectorName);
      _selectedBoxId = updated.visibleBoxes.isEmpty
          ? null
          : updated.visibleBoxes.first.id;
      lastUserMessage = detectedBoxes.isEmpty
          ? WorkbenchCopy.autoBoxesEmpty
          : WorkbenchCopy.autoBoxesCreated(detectedBoxes.length);
      _scheduleAutoSave();
    } catch (error) {
      if (!_isCurrentAutoBoxRequest(
        requestProjectEpoch,
        requestImageId,
        requestSourcePath,
      )) {
        _clearStaleAutoBoxActivity(requestToken);
        return;
      }
      _project = previousProject;
      _selectedBoxId = previousSelectedBoxId;
      if (error is AutoBoxCancelledException) {
        lastError = null;
        lastUserMessage = WorkbenchCopy.autoBoxesCancelled;
      } else {
        lastError = error;
        lastUserMessage = _autoBoxErrorMessage(error);
      }
    } finally {
      if (_activeAutoBoxRequestToken == requestToken) {
        _activeAutoBoxRequestToken = null;
        if (!_isDisposed) notifyListeners();
      }
    }
  }

  Future<void> cancelAutoBoxes() async {
    if (!isAutomationRunning) {
      return;
    }
    await _autoBoxRuntime.cancelActiveRequest();
  }

  void acceptSelectedSuggestedLabel() {
    final image = selectedImage;
    final boxId = selectedBoxId;
    if (image == null ||
        boxId == null ||
        selectedBox?.requiresLabelReview != true) {
      return;
    }
    _recordUndo();
    _replaceSelectedImage(
      AnnotationRules.acceptSuggestedLabel(
        image,
        boxId: boxId,
      ).copyWith(status: ImageStatus.needsReview),
    );
    _scheduleAutoSave();
    notifyListeners();
  }

  void scheduleSelectedBoxClassification({String? pipelineVersion}) {
    final image = selectedImage;
    final box = selectedBox;
    if (image == null || box == null || box.isDeleted) {
      return;
    }
    _classificationDebounce?.cancel();
    final generation = ++_classificationGeneration;
    final projectEpoch = _projectEpoch;
    final imageId = image.id;
    final sourcePath = image.sourcePath;
    final boxId = box.id;
    final resolvedPipelineVersion =
        pipelineVersion ??
        box.automation?.pipelineVersion ??
        _pipelineVersionsByImageId[imageId] ??
        '';
    _classificationPending = true;
    _classificationDebounce = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(
        _classifyEditedBox(
          generation: generation,
          projectEpoch: projectEpoch,
          imageId: imageId,
          sourcePath: sourcePath,
          boxId: boxId,
          x: box.x,
          y: box.y,
          width: box.width,
          height: box.height,
          pipelineVersion: resolvedPipelineVersion,
        ),
      ),
    );
  }

  Future<void> _classifyEditedBox({
    required int generation,
    required int projectEpoch,
    required int imageId,
    required String sourcePath,
    required String boxId,
    required double x,
    required double y,
    required double width,
    required double height,
    required String pipelineVersion,
  }) async {
    if (generation != _classificationGeneration ||
        projectEpoch != _projectEpoch) {
      return;
    }
    if (_classificationInFlight) return;
    _classificationPending = false;
    _classificationInFlight = true;
    try {
      final image = _imageById(imageId);
      final box = _boxById(image, boxId);
      if (image == null ||
          image.sourcePath != sourcePath ||
          box == null ||
          !_sameGeometry(box, x, y, width, height)) {
        return;
      }

      final imageHash = image.contentSha256;
      final cacheKey = imageHash == null || pipelineVersion.isEmpty
          ? null
          : BoxLabelCacheKey(
              imageSha256: imageHash,
              x: x,
              y: y,
              width: width,
              height: height,
              pipelineVersion: pipelineVersion,
            );
      final cached = cacheKey == null
          ? null
          : _boxLabelCache.getEntry(cacheKey);
      if (cached != null) {
        _applyClassificationDecision(
          image: image,
          box: cached.applyTo(box),
          generation: generation,
          projectEpoch: projectEpoch,
          sourcePath: sourcePath,
          x: x,
          y: y,
          width: width,
          height: height,
        );
        return;
      }

      try {
        final result = await _autoBoxRuntime.classifyBoxes(image, [box]);
        if (generation != _classificationGeneration ||
            projectEpoch != _projectEpoch) {
          return;
        }
        final currentImage = _imageById(imageId);
        final currentBox = _boxById(currentImage, boxId);
        if (currentImage == null ||
            currentImage.sourcePath != sourcePath ||
            currentBox == null ||
            !_sameGeometry(currentBox, x, y, width, height) ||
            currentBox.status != BoxStatus.proposal ||
            currentBox.labelId != null ||
            result.boxes.isEmpty) {
          return;
        }
        final responseBox = result.boxes.firstWhere(
          (candidate) => candidate.id == boxId,
          orElse: () => result.boxes.single,
        );
        final project = _project!;
        final normalized = _normalizeDetectionLabelIds(project, [
          responseBox,
        ]).single.copyWith(id: boxId, x: x, y: y, width: width, height: height);
        final resultPipeline = result.pipelineVersion ?? pipelineVersion;
        if (resultPipeline.isNotEmpty) {
          _pipelineVersionsByImageId[imageId] = resultPipeline;
        }
        final resultHash = result.imageSha256 ?? currentImage.contentSha256;
        if (currentImage.contentSha256 != null &&
            resultHash != null &&
            currentImage.contentSha256 != resultHash) {
          _boxLabelCache.invalidateImage(currentImage.contentSha256!);
        }
        final resultKey = resultHash == null || resultPipeline.isEmpty
            ? null
            : BoxLabelCacheKey(
                imageSha256: resultHash,
                x: x,
                y: y,
                width: width,
                height: height,
                pipelineVersion: resultPipeline,
              );
        if (resultKey != null &&
            (normalized.isAutoLabeled || normalized.requiresLabelReview)) {
          _boxLabelCache.putBox(resultKey, normalized);
        }
        _applyClassificationDecision(
          image: currentImage.copyWith(contentSha256: resultHash),
          box: normalized,
          generation: generation,
          projectEpoch: projectEpoch,
          sourcePath: sourcePath,
          x: x,
          y: y,
          width: width,
          height: height,
        );
      } catch (_) {
        // A failed refresh leaves the box as an explicit gray proposal.
      }
    } finally {
      _classificationInFlight = false;
      if (_classificationPending && projectEpoch == _projectEpoch) {
        scheduleSelectedBoxClassification();
      }
    }
  }

  void _applyClassificationDecision({
    required AnnotatedImage image,
    required BoundingBox box,
    required int generation,
    required int projectEpoch,
    required String sourcePath,
    required double x,
    required double y,
    required double width,
    required double height,
  }) {
    final currentImage = _imageById(image.id);
    final currentBox = _boxById(currentImage, box.id);
    if (generation != _classificationGeneration ||
        projectEpoch != _projectEpoch ||
        currentImage == null ||
        currentImage.sourcePath != sourcePath ||
        currentBox == null ||
        !_sameGeometry(currentBox, x, y, width, height)) {
      return;
    }
    _replaceSelectedImage(
      image.copyWith(
        status: ImageStatus.needsReview,
        boxes: [
          for (final existing in image.boxes)
            if (existing.id == box.id) box else existing,
        ],
      ),
    );
    _scheduleAutoSave();
    notifyListeners();
  }

  void clearSelectedImageBoxes() {
    final image = selectedImage;
    if (image == null) {
      return;
    }
    _recordUndo();
    _replaceSelectedImage(
      image.copyWith(
        status: ImageStatus.needsReview,
        boxes: const [],
        errorMessage: null,
      ),
    );
    _selectedBoxId = null;
    _scheduleAutoSave();
    notifyListeners();
  }

  LabelClass addLabel(String name, int color, {String? shortcut}) {
    final project = _requireProject();
    _recordUndo();
    final updated = AnnotationRules.addLabel(
      project,
      name: name,
      color: color,
      shortcut: shortcut,
    );
    _project = updated;
    _scheduleAutoSave();
    notifyListeners();
    return updated.labels.last;
  }

  void updateLabel({
    required int labelId,
    required String name,
    required int color,
    String? shortcut,
  }) {
    final project = _requireProject();
    _recordUndo();
    _project = AnnotationRules.updateLabel(
      project,
      labelId: labelId,
      name: name,
      color: color,
      shortcut: shortcut,
    );
    _scheduleAutoSave();
    notifyListeners();
  }

  void assignSelectedBoxLabel(int labelId) {
    final image = selectedImage;
    final boxId = _selectedBoxId;
    if (image == null || boxId == null) {
      return;
    }
    _recordUndo();
    final updatedImage = AnnotationRules.assignLabel(
      image,
      boxId: boxId,
      labelId: labelId,
    );
    _replaceSelectedImage(updatedImage);
    _selectedBoxId =
        nextBoxNeedingLabelId(updatedImage, afterBoxId: boxId) ?? boxId;
    _scheduleAutoSave();
    notifyListeners();
  }

  void confirmSelectedImage() {
    final image = selectedImage;
    if (image == null) {
      return;
    }
    _recordUndo();
    _replaceSelectedImage(AnnotationRules.confirmImage(image));
    _scheduleAutoSave();
    notifyListeners();
  }

  void completeSelectedImageAndSelectNext() {
    final image = selectedImage;
    if (image == null) {
      return;
    }
    _recordUndo();
    final confirmedImage = AnnotationRules.confirmImage(image);
    _replaceSelectedImage(confirmedImage);
    final nextImageId = nextImageNeedingWorkId(afterImageId: image.id);
    if (nextImageId != null) {
      _selectedImageId = nextImageId;
      _selectedBoxId = null;
      _imageViewLoadState = ImageViewLoadState(
        imageId: nextImageId,
        isLoading: false,
      );
    } else {
      _selectedImageId = image.id;
      _selectedBoxId = null;
      lastUserMessage = WorkbenchCopy.allWorkImagesCompleted;
    }
    _scheduleAutoSave();
    notifyListeners();
  }

  CocoExportSummary exportSummary({
    CocoExportOptions options = const CocoExportOptions(),
  }) {
    return CocoExporter.validate(_requireProject(), options: options);
  }

  Map<String, Object?> buildCoco({
    CocoExportOptions options = const CocoExportOptions(),
  }) {
    return CocoExporter.build(_requireProject(), options: options);
  }

  Future<void> exportCocoFile(String filePath) async {
    final json = const JsonEncoder.withIndent('  ').convert(buildCoco());
    await File(filePath).writeAsString(json, encoding: utf8, flush: true);
  }

  Future<void> returnToProjectHome() async {
    await saveProject();
    _clearActiveProject();
    await loadProjectLibrary();
  }

  void undo() {
    if (_undoStack.isEmpty || _project == null) {
      return;
    }
    _classificationDebounce?.cancel();
    _classificationGeneration++;
    _classificationPending = false;
    _redoStack.add(_project!);
    _project = _undoStack.removeLast();
    _repairSelection();
    _resetSourceAvailability(_project);
    _refreshSourceAvailabilityInBackground();
    notifyListeners();
  }

  void redo() {
    if (_redoStack.isEmpty || _project == null) {
      return;
    }
    _classificationDebounce?.cancel();
    _classificationGeneration++;
    _classificationPending = false;
    _undoStack.add(_project!);
    _project = _redoStack.removeLast();
    _repairSelection();
    _resetSourceAvailability(_project);
    _refreshSourceAvailabilityInBackground();
    notifyListeners();
  }

  void _clearActiveProject() {
    _projectEpoch++;
    _project = null;
    _resetSourceAvailability(null);
    _currentLibraryProjectId = null;
    _selectedImageId = null;
    _selectedBoxId = null;
    _projectActivity = ProjectActivity.idle;
    _imageImportProgress = null;
    _imageViewLoadState = const ImageViewLoadState();
    _activeAutoBoxRequestToken = null;
    _undoStack.clear();
    _redoStack.clear();
    _saveStatus = SaveStatus.saved;
    _lastSaveError = null;
    notifyListeners();
  }

  AnnotationProject _requireProject() {
    final project = _project;
    if (project == null) {
      throw StateError('No project is open.');
    }
    return project;
  }

  void _recordUndo() {
    final project = _project;
    if (project == null) {
      return;
    }
    _undoStack.add(project);
    _redoStack.clear();
  }

  Future<void> _addScannedImages(
    List<ScannedImage> scannedImages, {
    String? importedFrom,
  }) async {
    final project = _requireProject();
    if (scannedImages.isEmpty) {
      _projectActivity = ProjectActivity.idle;
      _imageImportProgress = null;
      notifyListeners();
      return;
    }
    final existing = <String, bool>{}
      ..addEntries(
        project.images.map((image) => MapEntry(_sourcePathKey(image), true)),
      );
    _recordUndo();
    _project = project.copyWith(status: ProjectStatus.scanning);
    _projectActivity = ProjectActivity.importing;
    _imageImportProgress = ImageImportProgress(
      total: scannedImages.length,
      processed: 0,
      added: 0,
      skipped: 0,
      errors: 0,
    );
    notifyListeners();
    var processed = 0;
    var added = 0;
    var skipped = 0;
    var errors = 0;
    var nextId = project.nextImageId;
    final nextImages = <AnnotatedImage>[...project.images];
    final addedImageIds = <int>[];
    try {
      for (final scanned in scannedImages) {
        processed += 1;
        final sourcePath = File(scanned.sourcePath).absolute.path;
        final sourceKey = _sourcePathKeyFromSource(sourcePath);
        if (existing.containsKey(sourceKey)) {
          skipped += 1;
          _imageImportProgress = ImageImportProgress(
            total: scannedImages.length,
            processed: processed,
            added: added,
            skipped: skipped,
            errors: errors,
          );
          notifyListeners();
          continue;
        }
        existing[sourceKey] = true;
        final importedImage = AnnotatedImage(
          id: nextId++,
          sourcePath: sourcePath,
          displayName: scanned.displayName,
          importedFrom:
              scanned.importedFrom ?? importedFrom ?? p.dirname(sourcePath),
          width: scanned.width,
          height: scanned.height,
          status: scanned.hasError
              ? ImageStatus.error
              : ImageStatus.needsReview,
          errorMessage: scanned.errorMessage,
        );
        nextImages.add(importedImage);
        addedImageIds.add(importedImage.id);
        added += 1;
        if (scanned.hasError) {
          errors += 1;
        }
        _imageImportProgress = ImageImportProgress(
          total: scannedImages.length,
          processed: processed,
          added: added,
          skipped: skipped,
          errors: errors,
        );
        notifyListeners();
      }
      _project = _project!.copyWith(
        status: ProjectStatus.ready,
        images: nextImages,
      );
      _sourceRefreshGeneration++;
      _sourceAvailability = {
        ..._sourceAvailability,
        for (final imageId in addedImageIds)
          imageId: SourceAvailability.available,
      };
      _repairSelectionAfterImport(nextImages);
      _scheduleAutoSave();
    } finally {
      _projectActivity = ProjectActivity.idle;
      _imageImportProgress = ImageImportProgress(
        total: scannedImages.length,
        processed: processed,
        added: added,
        skipped: skipped,
        errors: errors,
      );
      lastUserMessage = WorkbenchCopy.importComplete(added, skipped, errors);
      notifyListeners();
    }
  }

  void _repairSelection() {
    final project = _project;
    if (project == null || project.images.isEmpty) {
      _selectedImageId = null;
      _selectedBoxId = null;
      _imageViewLoadState = const ImageViewLoadState();
      return;
    }
    final imageExists = project.images.any(
      (image) => image.id == _selectedImageId,
    );
    if (!imageExists) {
      _selectedImageId = project.images.first.id;
      _selectedBoxId = null;
      _imageViewLoadState = ImageViewLoadState(
        imageId: _selectedImageId,
        isLoading: false,
      );
    }
    final image = selectedImage;
    final boxExists =
        image?.visibleBoxes.any((box) => box.id == _selectedBoxId) ?? false;
    if (!boxExists) {
      _selectedBoxId = null;
    }
  }

  void _repairSelectionAfterImport(List<AnnotatedImage> importedImages) {
    if (_selectedImageId == null && importedImages.isNotEmpty) {
      _selectedImageId = importedImages.first.id;
      _selectedBoxId = null;
      _imageViewLoadState = ImageViewLoadState(
        imageId: _selectedImageId,
        isLoading: false,
      );
      return;
    }
    _repairSelection();
  }

  void _repairSelectionAfterRemoval() {
    final project = _project;
    if (project == null || project.images.isEmpty) {
      _selectedImageId = null;
      _selectedBoxId = null;
      _imageViewLoadState = const ImageViewLoadState();
      return;
    }
    final imageExists = project.images.any(
      (image) => image.id == _selectedImageId,
    );
    if (!imageExists) {
      _selectedImageId = project.images.first.id;
      _selectedBoxId = null;
      _imageViewLoadState = ImageViewLoadState(
        imageId: _selectedImageId,
        isLoading: false,
      );
      return;
    }
  }

  void _replaceSelectedImage(AnnotatedImage updatedImage) {
    final project = _requireProject();
    _project = project.copyWith(
      images: [
        for (final image in project.images)
          if (image.id == updatedImage.id) updatedImage else image,
      ],
    );
  }

  bool _imageNeedsWork(AnnotatedImage image) {
    if (image.status == ImageStatus.error ||
        image.status == ImageStatus.confirmed) {
      return false;
    }
    return image.status == ImageStatus.needsReview ||
        image.visibleBoxes.any(_boxNeedsLabel);
  }

  AnnotatedImage? _imageById(int imageId) {
    final project = _project;
    if (project == null) {
      return null;
    }
    for (final image in project.images) {
      if (image.id == imageId) {
        return image;
      }
    }
    return null;
  }

  BoundingBox? _boxById(AnnotatedImage? image, String boxId) {
    if (image == null) {
      return null;
    }
    for (final box in image.visibleBoxes) {
      if (box.id == boxId) {
        return box;
      }
    }
    return null;
  }

  bool _sameGeometry(
    BoundingBox box,
    double x,
    double y,
    double width,
    double height,
  ) {
    return box.x == x &&
        box.y == y &&
        box.width == width &&
        box.height == height;
  }

  bool _boxNeedsLabel(BoundingBox box) {
    return !box.isDeleted &&
        (box.status != BoxStatus.labeled || box.labelId == null);
  }

  List<BoundingBox> _normalizeDetectionLabelIds(
    AnnotationProject project,
    List<BoundingBox> boxes,
  ) {
    final validLabelIds = project.labels.map((label) => label.id).toSet();
    return [
      for (final box in boxes)
        if ((box.labelId == null || validLabelIds.contains(box.labelId)) &&
            (box.automation?.suggestedLabelId == null ||
                validLabelIds.contains(box.automation!.suggestedLabelId)))
          box
        else
          box.copyWith(
            status: BoxStatus.proposal,
            labelId: null,
            labelSource: null,
            automation: box.automation?.copyWith(
              suggestedLabelId: null,
              reviewReasons: const ['label_registry_mismatch'],
            ),
          ),
    ];
  }

  Future<DetectionResult> _detectWithProgress(
    Detector detector,
    AnnotatedImage image, {
    required DetectionOptions options,
  }) {
    return detector.detect(
      image,
      imagePath: image.sourcePath,
      options: options,
    );
  }

  bool _isCurrentAutoBoxRequest(
    int requestProjectEpoch,
    int requestImageId,
    String requestSourcePath,
  ) {
    return !_isDisposed &&
        _project != null &&
        _projectEpoch == requestProjectEpoch &&
        _selectedImageId == requestImageId &&
        _imageById(requestImageId)?.sourcePath == requestSourcePath;
  }

  void _clearStaleAutoBoxActivity(int requestToken) {
    if (_isDisposed) return;
    final activeToken = _activeAutoBoxRequestToken;
    if (activeToken != null && activeToken != requestToken) {
      return;
    }
    if (lastUserMessage == WorkbenchCopy.autoBoxesRunning) {
      lastUserMessage = null;
      notifyListeners();
    }
  }

  String _autoBoxErrorMessage(Object error) {
    if (error is FileSystemException) {
      return WorkbenchCopy.autoBoxesFileUnavailable;
    }
    if (error is WorkerRequestException) {
      return error.code == 'decode_failed'
          ? WorkbenchCopy.autoBoxesDecodeFailed
          : WorkbenchCopy.autoBoxesWorkerFailed;
    }
    if (error is AutoBoxStartupException) {
      return WorkbenchCopy.autoBoxesModelUnavailable;
    }
    if (error is WorkerProtocolException ||
        error is WorkerTransportException ||
        error is TimeoutException ||
        error is StateError) {
      return WorkbenchCopy.autoBoxesWorkerFailed;
    }
    return WorkbenchCopy.autoBoxesFailed;
  }

  void _handleAutoBoxRuntimeChanged() {
    if (!_isDisposed) notifyListeners();
  }

  void _editSelectedBox(
    BoundingBox Function(AnnotatedImage image, BoundingBox box) edit,
  ) {
    final image = selectedImage;
    final box = selectedBox;
    if (image == null || box == null) {
      return;
    }
    _recordUndo();
    final pipelineVersion =
        box.automation?.pipelineVersion ?? _pipelineVersionsByImageId[image.id];
    final editedBox = edit(image, box);
    final shouldReclassify =
        box.labelSource == LabelSource.auto ||
        box.automation != null ||
        (box.status == BoxStatus.proposal && box.labelId == null);
    final updatedBox = shouldReclassify
        ? editedBox.copyWith(
            status: BoxStatus.proposal,
            labelId: null,
            labelSource: null,
            automation: null,
          )
        : editedBox;
    _replaceSelectedImage(
      image.copyWith(
        status: ImageStatus.needsReview,
        boxes: [
          for (final existing in image.boxes)
            if (existing.id == updatedBox.id) updatedBox else existing,
        ],
      ),
    );
    _scheduleAutoSave();
    notifyListeners();
    if (shouldReclassify) {
      scheduleSelectedBoxClassification(pipelineVersion: pipelineVersion);
    }
  }

  void _scheduleAutoSave() {
    final projectSnapshot = _project;
    final path = projectSnapshot?.projectFilePath;
    if (projectSnapshot == null || path == null || _isDisposed) {
      return;
    }
    final projectEpoch = _projectEpoch;
    final libraryProjectId = _currentLibraryProjectId;
    _saveStatus = SaveStatus.saving;
    _lastSaveError = null;
    notifyListeners();
    _autoSaveChain = _autoSaveChain.then((_) async {
      try {
        final saved = await _projectSaver(projectSnapshot, path);
        await _refreshLibraryEntryForAutoSave(
          saved,
          libraryProjectId: libraryProjectId,
        );
        if (_isDisposed ||
            projectEpoch != _projectEpoch ||
            _project?.projectFilePath != path) {
          return;
        }
        if (!identical(_project, projectSnapshot)) return;
        _project = saved;
        _currentLibraryProjectId = _libraryProjectIdForPath(
          saved.projectFilePath,
        );
        _saveStatus = SaveStatus.saved;
        _lastSaveError = null;
        notifyListeners();
      } catch (error) {
        if (_isDisposed ||
            projectEpoch != _projectEpoch ||
            _project?.projectFilePath != path) {
          return;
        }
        lastError = error;
        _lastSaveError = error;
        _saveStatus = SaveStatus.failed;
        notifyListeners();
      }
    });
    unawaited(_autoSaveChain);
  }

  Future<void> _waitForAutoSaveIdle() async {
    while (true) {
      final pending = _autoSaveChain;
      await pending;
      if (identical(pending, _autoSaveChain)) return;
    }
  }

  void _refreshSourceAvailabilityInBackground() {
    unawaited(_consumeSourceAvailabilityRefresh());
  }

  Future<void> _consumeSourceAvailabilityRefresh() async {
    try {
      await refreshSourceAvailability();
    } catch (_) {
      // The refresh method already exposes an actionable warning to the UI.
    }
  }

  void _resetSourceAvailability(AnnotationProject? project) {
    _sourceRefreshGeneration++;
    _sourceAvailability = {
      for (final image in project?.images ?? const <AnnotatedImage>[])
        image.id: SourceAvailability.unknown,
    };
  }

  Future<void> _refreshLibraryEntryForAutoSave(
    AnnotationProject project, {
    required String? libraryProjectId,
  }) async {
    if (libraryProjectId == null) return;
    await _projectLibrary.refreshEntry(project);
    final entries = await _projectLibrary.listProjects();
    if (!_isDisposed) {
      _projectLibraryEntries = entries;
    }
  }

  Future<void> _refreshLibraryEntryIfNeeded() async {
    final project = _project;
    if (project == null || _currentLibraryProjectId == null) {
      return;
    }
    await _projectLibrary.refreshEntry(project);
    _projectLibraryEntries = await _projectLibrary.listProjects();
  }

  String _sourcePathKeyFromSource(String sourcePath) {
    return p.normalize(sourcePath).toLowerCase();
  }

  String _sourcePathKey(AnnotatedImage image) =>
      _sourcePathKeyFromSource(image.sourcePath);

  String? _libraryProjectIdForPath(String? projectFilePath) {
    if (projectFilePath == null || projectFilePath.trim().isEmpty) {
      return null;
    }
    final normalizedRoot = p.normalize(
      Directory(_projectLibrary.projectsRootPath).absolute.path,
    );
    final normalizedPath = p.normalize(File(projectFilePath).absolute.path);
    if (!p.isWithin(normalizedRoot, normalizedPath)) {
      return null;
    }
    return p.basename(p.dirname(projectFilePath));
  }

  @override
  void dispose() {
    _isDisposed = true;
    _projectEpoch++;
    _sourceRefreshGeneration++;
    _classificationDebounce?.cancel();
    _classificationGeneration++;
    _classificationPending = false;
    _autoBoxRuntime.removeListener(_handleAutoBoxRuntimeChanged);
    unawaited(_autoBoxRuntime.shutdown());
    super.dispose();
  }
}
