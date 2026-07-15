import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../annotation/models.dart';
import 'bread_worker_client.dart';
import 'detector.dart';
import 'worker_protocol.dart';

enum AutoBoxState { idle, starting, ready, running, restarting, failed }

class ImagePayload {
  const ImagePayload({required this.length, required this.bytes});

  final int length;
  final Stream<List<int>> bytes;
}

typedef ImagePayloadOpener = Future<ImagePayload> Function(String path);
typedef BreadWorkerClientFactory = BreadWorkerClient Function();

class AutoBoxBusyException implements Exception {
  const AutoBoxBusyException();

  @override
  String toString() => 'AutoBoxBusyException: detection is already running';
}

class AutoBoxStartupException implements Exception {
  AutoBoxStartupException(this.cause);

  final Object cause;

  @override
  String toString() => 'AutoBoxStartupException: $cause';
}

class AutoBoxCancelledException implements Exception {
  const AutoBoxCancelledException();

  @override
  String toString() => 'AutoBoxCancelledException: request cancelled';
}

abstract interface class AutoBoxRuntime implements Detector, Listenable {
  AutoBoxState get state;
  Object? get lastError;
  List<String> get recentStderr;
  Future<DetectionResult> classifyBoxes(
    AnnotatedImage image,
    List<BoundingBox> boxes,
  );
  Future<void> cancelActiveRequest();
  Future<void> warmUp();
  Future<void> shutdown();
}

class AutoBoxService extends ChangeNotifier implements AutoBoxRuntime {
  factory AutoBoxService({
    required BreadWorkerClientFactory createClient,
    ImagePayloadOpener? openImage,
  }) {
    return AutoBoxService._(createClient, openImage ?? _defaultOpenImage);
  }

  AutoBoxService._(this._createClient, this._openImage);

  final BreadWorkerClientFactory _createClient;
  final ImagePayloadOpener _openImage;

  BreadWorkerClient? _client;
  Future<void>? _warmUpFuture;
  Future<void>? _restartFuture;
  Future<void>? _shutdownFuture;
  AutoBoxState _state = AutoBoxState.idle;
  Object? _lastError;
  List<String> _lastStderr = const [];
  bool _isDetecting = false;
  bool _isShuttingDown = false;
  int _generation = 0;
  int _nextRequestId = 0;
  Completer<void>? _activeCancellation;

  @override
  String get name => 'bread-yolo-boxes';

  @override
  AutoBoxState get state => _state;

  @override
  Object? get lastError => _lastError;

  @override
  List<String> get recentStderr => _client?.recentStderr ?? _lastStderr;

  @override
  Future<void> warmUp() {
    if (_isShuttingDown) {
      return Future<void>.error(_shutdownCancellation());
    }
    final restart = _restartFuture;
    if (restart != null) {
      return restart;
    }
    if (_state == AutoBoxState.running ||
        (_client != null && _state == AutoBoxState.ready)) {
      return Future<void>.value();
    }
    final pending = _warmUpFuture;
    if (pending != null) {
      return pending;
    }

    late final Future<void> future;
    final generation = _generation;
    future = _startClient(generation).whenComplete(() {
      if (identical(_warmUpFuture, future)) {
        _warmUpFuture = null;
      }
    });
    _warmUpFuture = future;
    return future;
  }

  Future<void> _startClient(int generation) async {
    _setState(AutoBoxState.starting);
    _lastError = null;
    BreadWorkerClient? client;
    try {
      _ensureCurrentGeneration(generation);
      client = _createClient();
      _client = client;
      await client.start();
      _ensureClientOwner(generation, client);
      _setState(AutoBoxState.ready);
    } catch (error, stackTrace) {
      if (client != null) {
        await _killClient(client);
      }
      if (!_isCurrentGeneration(generation)) {
        throw _shutdownCancellation();
      }
      final startupError = error is AutoBoxStartupException
          ? error
          : AutoBoxStartupException(error);
      _lastError = startupError;
      _setState(AutoBoxState.failed);
      Error.throwWithStackTrace(startupError, stackTrace);
    }
  }

  @override
  Future<DetectionResult> detect(
    AnnotatedImage image, {
    String? imagePath,
    DetectionOptions options = const DetectionOptions(),
  }) async {
    final path = imagePath ?? image.sourcePath;
    if (_isDetecting) {
      throw const AutoBoxBusyException();
    }
    _isDetecting = true;
    final cancellation = Completer<void>();
    _activeCancellation = cancellation;
    try {
      return await _detectOnceWithRecovery(image, path, options);
    } finally {
      if (identical(_activeCancellation, cancellation)) {
        _activeCancellation = null;
      }
      _isDetecting = false;
    }
  }

  @override
  Future<DetectionResult> classifyBoxes(
    AnnotatedImage image,
    List<BoundingBox> boxes,
  ) async {
    if (_isDetecting) throw const AutoBoxBusyException();
    _isDetecting = true;
    final cancellation = Completer<void>();
    _activeCancellation = cancellation;
    try {
      return await _classifyOnceWithRecovery(image, boxes);
    } finally {
      if (identical(_activeCancellation, cancellation)) {
        _activeCancellation = null;
      }
      _isDetecting = false;
    }
  }

  @override
  Future<void> cancelActiveRequest() async {
    final cancellation = _activeCancellation;
    if (cancellation == null) return;
    if (!cancellation.isCompleted) cancellation.complete();
    _generation++;
    final client = _client;
    if (client != null) await _killClient(client);
    _warmUpFuture = null;
    _restartFuture = null;
    _lastError = null;
    _setState(AutoBoxState.idle);
  }

  Future<DetectionResult> _detectOnceWithRecovery(
    AnnotatedImage image,
    String path,
    DetectionOptions options,
  ) async {
    await warmUp();
    final generation = _generation;
    final client = _client;
    if (client == null) {
      throw _shutdownCancellation();
    }
    _ensureClientOwner(generation, client);
    _lastError = null;
    _setState(AutoBoxState.running);

    try {
      final response = await _sendDetection(client, path, options, generation);
      _ensureClientOwner(generation, client);
      final result = _parseResult(response, image);
      _setState(AutoBoxState.ready);
      return result;
    } catch (error) {
      if (error is AutoBoxCancelledException) {
        rethrow;
      }
      if (!_isCurrentGeneration(generation)) {
        throw _shutdownCancellation();
      }
      if (error is _ImagePayloadStreamException) {
        _lastError = error;
        await _killClient(client);
        if (!_isCurrentGeneration(generation)) {
          throw _shutdownCancellation();
        }
        _setState(AutoBoxState.failed);
        rethrow;
      }
      if (!_isRetryableWorkerFailure(error)) {
        _lastError = error;
        _setState(AutoBoxState.ready);
        rethrow;
      }

      try {
        late final Future<void> restart;
        restart = _restartClient(generation, client).whenComplete(() {
          if (identical(_restartFuture, restart)) {
            _restartFuture = null;
          }
        });
        _restartFuture = restart;
        await restart;
        _ensureCurrentGeneration(generation);
        final replacement = _client;
        if (replacement == null) {
          throw _shutdownCancellation();
        }
        _ensureClientOwner(generation, replacement);
        _setState(AutoBoxState.running);
        final response = await _sendDetection(
          replacement,
          path,
          options,
          generation,
        );
        _ensureClientOwner(generation, replacement);
        final result = _parseResult(response, image);
        _lastError = null;
        _setState(AutoBoxState.ready);
        return result;
      } catch (retryError) {
        if (!_isCurrentGeneration(generation)) {
          throw _shutdownCancellation();
        }
        _lastError = retryError;
        final failedClient = _client;
        if (failedClient != null) {
          await _killClient(failedClient);
        }
        if (!_isCurrentGeneration(generation)) {
          throw _shutdownCancellation();
        }
        _setState(AutoBoxState.failed);
        rethrow;
      }
    }
  }

  Future<DetectionResult> _classifyOnceWithRecovery(
    AnnotatedImage image,
    List<BoundingBox> boxes,
  ) async {
    await warmUp();
    final generation = _generation;
    final client = _client;
    if (client == null) throw _shutdownCancellation();
    _ensureClientOwner(generation, client);
    _lastError = null;
    _setState(AutoBoxState.running);

    try {
      final response = await _sendClassification(
        client,
        image.sourcePath,
        boxes,
        generation,
      );
      _ensureClientOwner(generation, client);
      final result = _parseResult(response, image);
      _setState(AutoBoxState.ready);
      return result;
    } catch (error) {
      if (error is AutoBoxCancelledException) rethrow;
      if (!_isCurrentGeneration(generation)) throw _shutdownCancellation();
      if (!_isRetryableWorkerFailure(error)) {
        _lastError = error;
        _setState(AutoBoxState.ready);
        rethrow;
      }

      try {
        late final Future<void> restart;
        restart = _restartClient(generation, client).whenComplete(() {
          if (identical(_restartFuture, restart)) _restartFuture = null;
        });
        _restartFuture = restart;
        await restart;
        _ensureCurrentGeneration(generation);
        final replacement = _client;
        if (replacement == null) throw _shutdownCancellation();
        _ensureClientOwner(generation, replacement);
        _setState(AutoBoxState.running);
        final response = await _sendClassification(
          replacement,
          image.sourcePath,
          boxes,
          generation,
        );
        _ensureClientOwner(generation, replacement);
        final result = _parseResult(response, image);
        _lastError = null;
        _setState(AutoBoxState.ready);
        return result;
      } catch (retryError) {
        if (!_isCurrentGeneration(generation)) throw _shutdownCancellation();
        _lastError = retryError;
        final failedClient = _client;
        if (failedClient != null) await _killClient(failedClient);
        if (!_isCurrentGeneration(generation)) throw _shutdownCancellation();
        _setState(AutoBoxState.failed);
        rethrow;
      }
    }
  }

  Future<void> _restartClient(
    int generation,
    BreadWorkerClient failedClient,
  ) async {
    _ensureClientOwner(generation, failedClient);
    _setState(AutoBoxState.restarting);
    await _killClient(failedClient);
    _ensureCurrentGeneration(generation);

    BreadWorkerClient? replacement;
    try {
      replacement = _createClient();
      _client = replacement;
      await replacement.start();
      _ensureClientOwner(generation, replacement);
    } catch (error, stackTrace) {
      if (replacement != null) {
        await _killClient(replacement);
      }
      if (!_isCurrentGeneration(generation)) {
        throw _shutdownCancellation();
      }
      if (error is ProcessException) {
        Error.throwWithStackTrace(
          WorkerTransportException('replacement worker failed to start'),
          stackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<Map<String, Object?>> _sendDetection(
    BreadWorkerClient client,
    String path,
    DetectionOptions options,
    int generation,
  ) async {
    final payload = await _openImage(path);
    _ensureClientOwner(generation, client);
    if (payload.length < 0 || payload.length > maxWorkerImageBytes) {
      throw _ImagePayloadException(
        'image payload length ${payload.length} is outside the supported range '
        'of 0 to $maxWorkerImageBytes bytes',
      );
    }
    try {
      return await _awaitCancelable(
        client.detect(
          requestId: 'auto-box-${++_nextRequestId}',
          fileName: p.basename(path),
          payloadLength: payload.length,
          payload: payload.bytes,
          maxProposals: boundedMaxProposals(options.maxProposals),
        ),
      );
    } on FileSystemException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        _ImagePayloadStreamException(error),
        stackTrace,
      );
    }
  }

  Future<Map<String, Object?>> _sendClassification(
    BreadWorkerClient client,
    String path,
    List<BoundingBox> boxes,
    int generation,
  ) async {
    final payload = await _openImage(path);
    _ensureClientOwner(generation, client);
    return _awaitCancelable(
      client.classify(
        requestId: 'auto-box-${++_nextRequestId}',
        fileName: p.basename(path),
        payloadLength: payload.length,
        payload: payload.bytes,
        boxes: [
          for (final box in boxes.take(100))
            <String, Object?>{
              'id': box.id,
              'x': box.x,
              'y': box.y,
              'width': box.width,
              'height': box.height,
            },
        ],
      ),
    );
  }

  Future<T> _awaitCancelable<T>(Future<T> operation) {
    final cancellation = _activeCancellation;
    if (cancellation == null) return operation;
    return Future.any<T>([
      operation,
      cancellation.future.then<T>(
        (_) => throw const AutoBoxCancelledException(),
      ),
    ]);
  }

  DetectionResult _parseResult(
    Map<String, Object?> response,
    AnnotatedImage image,
  ) {
    try {
      final rawImage = response['image'];
      if (rawImage is! Map<Object?, Object?>) {
        throw WorkerProtocolException(
          'result image must be an object with width and height',
        );
      }
      final responseWidth = rawImage['width'];
      final responseHeight = rawImage['height'];
      if (responseWidth is! int ||
          responseHeight is! int ||
          responseWidth <= 0 ||
          responseHeight <= 0) {
        throw WorkerProtocolException(
          'result image width and height must be positive integers',
        );
      }
      if (responseWidth != image.width || responseHeight != image.height) {
        throw WorkerProtocolException(
          'result image dimensions ${responseWidth}x$responseHeight do not '
          'match ${image.width}x${image.height}',
        );
      }

      final rawBoxes = response['boxes'];
      if (rawBoxes is! List<Object?>) {
        throw WorkerProtocolException('result boxes must be a list');
      }
      final boxes = <BoundingBox>[];
      final pipelineVersion = response['pipelineVersion'] as String?;
      final policyVersion = response['policyVersion'] as String?;
      final modelHashes = response['modelHashes'] as Map<Object?, Object?>?;
      for (final rawBox in rawBoxes) {
        if (rawBox is! Map<Object?, Object?>) {
          throw WorkerProtocolException('each result box must be an object');
        }
        final rawX = _finiteBoxNumber(rawBox, 'x');
        final rawY = _finiteBoxNumber(rawBox, 'y');
        final rawWidth = _finiteBoxNumber(rawBox, 'width');
        final rawHeight = _finiteBoxNumber(rawBox, 'height');
        if (rawWidth <= 0 || rawHeight <= 0) {
          throw WorkerProtocolException(
            'result box width and height must be positive',
          );
        }
        final right = rawX + rawWidth;
        final bottom = rawY + rawHeight;
        if (rawX < 0 ||
            rawY < 0 ||
            !right.isFinite ||
            !bottom.isFinite ||
            right > image.width ||
            bottom > image.height) {
          throw WorkerProtocolException(
            'result box must be within the image bounds',
          );
        }

        double? confidence;
        if (rawBox.containsKey('confidence')) {
          confidence = _finiteBoxNumber(rawBox, 'confidence');
        }

        boxes.add(
          _parseBox(
            rawBox,
            fallbackId: 'det-${image.id}-${boxes.length + 1}',
            x: rawX,
            y: rawY,
            width: rawWidth,
            height: rawHeight,
            confidence: confidence,
            pipelineVersion: pipelineVersion,
            policyVersion: policyVersion,
            detectorSha256: modelHashes?['detector'] as String?,
            classifierSha256: modelHashes?['classifier'] as String?,
            verifierSha256: modelHashes?['verifier'] as String?,
          ),
        );
      }
      final detectorName = response['detectorName'];
      if (detectorName != null && detectorName is! String) {
        throw WorkerProtocolException(
          'result detectorName must be a string when present',
        );
      }
      return DetectionResult(
        detectorName: detectorName as String? ?? name,
        boxes: boxes,
        imageSha256: rawImage['sha256'] as String?,
        pipelineVersion: pipelineVersion,
        policyVersion: policyVersion,
        detectorSha256: modelHashes?['detector'] as String?,
        classifierSha256: modelHashes?['classifier'] as String?,
        verifierSha256: modelHashes?['verifier'] as String?,
        stageErrors: _parseStageErrors(response['stageErrors']),
      );
    } on WorkerProtocolException {
      rethrow;
    } catch (error) {
      throw WorkerProtocolException('invalid worker result: $error');
    }
  }

  BoundingBox _parseBox(
    Map<Object?, Object?> raw, {
    required String fallbackId,
    required double x,
    required double y,
    required double width,
    required double height,
    required double? confidence,
    required String? pipelineVersion,
    required String? policyVersion,
    required String? detectorSha256,
    required String? classifierSha256,
    required String? verifierSha256,
  }) {
    final rawLabel = raw['label'];
    if (rawLabel == null) {
      return BoundingBox(
        id: raw['id'] as String? ?? fallbackId,
        x: x,
        y: y,
        width: width,
        height: height,
        status: BoxStatus.proposal,
        confidence: confidence,
      );
    }
    if (rawLabel is! Map<Object?, Object?>) {
      throw WorkerProtocolException('result box label must be an object');
    }
    final state = rawLabel['state'];
    final labelId = rawLabel['labelId'] as int?;
    final suggested = rawLabel['suggestedLabelId'] as int?;
    final candidateRows = rawLabel['candidates'];
    final reasonRows = rawLabel['reviewReasons'];
    if (candidateRows is! List<Object?> || reasonRows is! List<Object?>) {
      throw WorkerProtocolException(
        'result label candidates and reasons must be lists',
      );
    }
    final candidates = <LabelCandidate>[
      for (final item in candidateRows) _parseCandidate(item),
    ];
    final reasons = reasonRows
        .map((item) {
          if (item is! String) {
            throw WorkerProtocolException('review reason must be a string');
          }
          return item;
        })
        .toList(growable: false);
    if (state == 'accepted' && labelId == null) {
      throw WorkerProtocolException('accepted label requires labelId');
    }
    if (state == 'review' &&
        (labelId != null || suggested == null || reasons.isEmpty)) {
      throw WorkerProtocolException(
        'review label requires suggestion and reasons',
      );
    }
    if (state != 'accepted' && state != 'review' && state != 'unavailable') {
      throw WorkerProtocolException('unsupported label state: $state');
    }
    final metadata = BoxAutomationMetadata(
      suggestedLabelId: state == 'review' ? suggested : null,
      candidates: candidates,
      reviewReasons: reasons,
      pipelineVersion: pipelineVersion ?? '',
      policyVersion: policyVersion ?? '',
      detectorSha256: detectorSha256 ?? '',
      classifierSha256: classifierSha256,
      verifierSha256: verifierSha256,
      embeddingUsed: rawLabel['embeddingUsed'] as bool? ?? false,
    );
    return BoundingBox(
      id: raw['id'] as String? ?? fallbackId,
      x: x,
      y: y,
      width: width,
      height: height,
      status: state == 'accepted' ? BoxStatus.labeled : BoxStatus.proposal,
      labelId: state == 'accepted' ? labelId : null,
      labelSource: state == 'accepted' ? LabelSource.auto : null,
      automation: metadata,
      confidence: confidence,
    );
  }

  LabelCandidate _parseCandidate(Object? raw) {
    if (raw is! Map<Object?, Object?>) {
      throw WorkerProtocolException('label candidate must be an object');
    }
    final id = raw['labelId'];
    final score = raw['score'];
    if (id is! int ||
        id < 1 ||
        id > 20 ||
        score is! num ||
        !score.toDouble().isFinite ||
        score < 0 ||
        score > 1) {
      throw WorkerProtocolException('invalid label candidate');
    }
    return LabelCandidate(labelId: id, score: score.toDouble());
  }

  List<WorkerStageError> _parseStageErrors(Object? raw) {
    if (raw == null) {
      return const [];
    }
    if (raw is! List<Object?>) {
      throw WorkerProtocolException('stageErrors must be a list');
    }
    return [for (final item in raw) _parseStageError(item)];
  }

  WorkerStageError _parseStageError(Object? raw) {
    if (raw is! Map<Object?, Object?> ||
        raw['stage'] is! String ||
        raw['message'] is! String) {
      throw WorkerProtocolException('invalid stage error');
    }
    final code = raw['code'];
    if (code != null && code is! String) {
      throw WorkerProtocolException('invalid stage error');
    }
    return WorkerStageError(
      stage: raw['stage'] as String,
      code: code as String? ?? 'stage_failed',
      message: raw['message'] as String,
    );
  }

  double _finiteBoxNumber(Map<Object?, Object?> box, String field) {
    final value = box[field];
    if (value is! num) {
      throw WorkerProtocolException(
        'result box $field must be a finite number',
      );
    }
    final number = value.toDouble();
    if (!number.isFinite) {
      throw WorkerProtocolException(
        'result box $field must be a finite number',
      );
    }
    return number;
  }

  bool _isRetryableWorkerFailure(Object error) {
    if (error is _ImagePayloadException || error is FileSystemException) {
      return false;
    }
    if (error is WorkerRequestException) {
      return error.retryable;
    }
    return error is WorkerTransportException ||
        error is WorkerProtocolException ||
        error is TimeoutException;
  }

  @override
  Future<void> shutdown() {
    final pending = _shutdownFuture;
    if (pending != null) {
      return pending;
    }
    _generation++;
    _isShuttingDown = true;
    late final Future<void> future;
    future = _shutdown().whenComplete(() {
      if (identical(_shutdownFuture, future)) {
        _shutdownFuture = null;
      }
    });
    _shutdownFuture = future;
    return future;
  }

  Future<void> _shutdown() async {
    final client = _client;
    _client = null;
    _warmUpFuture = null;
    _restartFuture = null;
    try {
      if (client != null) {
        _lastStderr = client.recentStderr;
        try {
          await client.shutdown();
          _lastError = null;
        } catch (error) {
          _lastError = error;
          try {
            await client.kill();
          } catch (_) {
            // Preserve the shutdown error.
          }
          rethrow;
        }
      }
    } finally {
      _isShuttingDown = false;
      _setState(AutoBoxState.idle);
    }
  }

  Future<void> _killClient(BreadWorkerClient client) async {
    if (identical(_client, client)) {
      _lastStderr = client.recentStderr;
      _client = null;
    }
    try {
      await client.kill();
    } catch (_) {
      // Preserve the worker error that caused recovery or failure.
    }
  }

  bool _isCurrentGeneration(int generation) =>
      generation == _generation && !_isShuttingDown;

  void _ensureCurrentGeneration(int generation) {
    if (!_isCurrentGeneration(generation)) {
      throw _shutdownCancellation();
    }
  }

  void _ensureClientOwner(int generation, BreadWorkerClient client) {
    _ensureCurrentGeneration(generation);
    if (!identical(_client, client)) {
      throw _shutdownCancellation();
    }
  }

  StateError _shutdownCancellation() =>
      StateError('Auto box lifecycle was invalidated by shutdown');

  void _setState(AutoBoxState value) {
    if (_state == value) {
      return;
    }
    _state = value;
    notifyListeners();
  }
}

class _ImagePayloadException extends WorkerProtocolException {
  _ImagePayloadException(super.message);
}

class _ImagePayloadStreamException extends FileSystemException {
  _ImagePayloadStreamException(FileSystemException cause)
    : super(cause.message, cause.path, cause.osError);
}

Future<ImagePayload> _defaultOpenImage(String path) async {
  final file = File(path);
  final length = await file.length();
  return ImagePayload(length: length, bytes: file.openRead());
}

AutoBoxService defaultAutoBoxService({
  Map<String, String>? environment,
  bool Function(String path)? fileExists,
  String? executablePath,
}) {
  final activeEnvironment = environment ?? Platform.environment;
  final activeFileExists = fileExists ?? (path) => File(path).existsSync();
  final executableDirectory = p.dirname(
    executablePath ?? Platform.resolvedExecutable,
  );
  final pythonExecutable = _resolveRequiredAsset(
    environmentName: 'BBOX_BREAD_PYTHON',
    relativeSegments: const ['runtime', 'python', 'python.exe'],
    environment: activeEnvironment,
    fileExists: activeFileExists,
    executableDirectory: executableDirectory,
  );
  final workerPath = _resolveRequiredAsset(
    environmentName: 'BBOX_BREAD_WORKER',
    relativeSegments: const ['tools', 'detectors', 'bread_box_worker.py'],
    environment: activeEnvironment,
    fileExists: activeFileExists,
    executableDirectory: executableDirectory,
  );
  final pipelineManifestPath = _resolveRequiredAsset(
    environmentName: 'BBOX_BREAD_PIPELINE_MANIFEST',
    relativeSegments: const ['models', 'bread_pipeline_manifest.json'],
    environment: activeEnvironment,
    fileExists: activeFileExists,
    executableDirectory: executableDirectory,
  );

  return AutoBoxService(
    createClient: () {
      final requiredAssets = [
        pythonExecutable,
        workerPath,
        pipelineManifestPath,
      ];
      final missing = requiredAssets
          .where((path) => !activeFileExists(path))
          .toList(growable: false);
      if (missing.isNotEmpty) {
        throw StateError(
          'Required auto-box assets are missing: ${missing.join(', ')}',
        );
      }
      return BreadWorkerClient(
        pythonExecutable: pythonExecutable,
        scriptPath: workerPath,
        pipelineManifestPath: pipelineManifestPath,
      );
    },
  );
}

String _resolveRequiredAsset({
  required String environmentName,
  required List<String> relativeSegments,
  required Map<String, String> environment,
  required bool Function(String path) fileExists,
  required String executableDirectory,
}) {
  final override = environment[environmentName]?.trim();
  if (override != null && override.isNotEmpty) {
    return override;
  }

  final appLocal = p.joinAll([executableDirectory, ...relativeSegments]);
  if (fileExists(appLocal)) {
    return appLocal;
  }

  final workspace = File(p.joinAll(relativeSegments)).absolute.path;
  if (fileExists(workspace)) {
    return workspace;
  }
  return workspace;
}
