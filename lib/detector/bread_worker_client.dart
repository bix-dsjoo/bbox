import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'worker_protocol.dart';

abstract interface class BreadWorkerHandle {
  IOSink get stdin;
  Stream<List<int>> get stdoutBytes;
  Stream<String> get stderrLines;
  Future<int> get exitCode;
  bool kill();
}

typedef BreadWorkerStarter =
    Future<BreadWorkerHandle> Function(
      String executable,
      List<String> arguments,
    );

class WorkerRequestException implements Exception {
  WorkerRequestException(this.code, this.message);

  final String code;
  final String message;

  bool get retryable => code == 'inference_failed';

  @override
  String toString() => 'WorkerRequestException($code): $message';
}

class WorkerTransportException implements Exception {
  WorkerTransportException(this.message);

  final String message;

  @override
  String toString() => 'WorkerTransportException: $message';
}

class BreadWorkerClient {
  BreadWorkerClient({
    required this.pythonExecutable,
    required this.scriptPath,
    required this.pipelineManifestPath,
    this.startTimeout = const Duration(seconds: 90),
    this.inferenceTimeout = const Duration(seconds: 120),
    this.shutdownTimeout = const Duration(seconds: 2),
    BreadWorkerStarter? startWorker,
  }) : _startWorker = startWorker ?? _defaultStartWorker;

  final String pythonExecutable;
  final String scriptPath;
  final String pipelineManifestPath;
  final Duration startTimeout;
  final Duration inferenceTimeout;
  final Duration shutdownTimeout;
  final BreadWorkerStarter _startWorker;

  final List<String> _stderr = <String>[];
  BreadWorkerHandle? _worker;
  WorkerByteReader? _reader;
  Future<void>? _startFuture;
  bool _ready = false;

  List<String> get recentStderr => List<String>.unmodifiable(_stderr);

  Future<void> start() {
    if (_ready) {
      return Future<void>.value();
    }
    return _startFuture ??= _start();
  }

  Future<void> _start() async {
    final worker = await _startWorker(pythonExecutable, [
      scriptPath,
      '--pipeline-manifest',
      pipelineManifestPath,
    ]);
    _worker = worker;
    worker.stderrLines.listen(_recordStderr);
    final reader = WorkerByteReader(worker.stdoutBytes);
    _reader = reader;

    final message = await readWorkerMessage(reader).timeout(startTimeout);
    if (message.type != 'ready') {
      throw WorkerProtocolException(
        'expected ready as the first worker message, got ${message.type}',
      );
    }
    _ready = true;
  }

  Future<Map<String, Object?>> detect({
    required String requestId,
    required String fileName,
    required int payloadLength,
    required Stream<List<int>> payload,
    int? maxProposals,
  }) async {
    await start();
    final worker = _worker!;
    final reader = _reader!;
    final header = <String, Object?>{
      'version': workerProtocolVersion,
      'type': 'detect',
      'requestId': requestId,
      'fileName': fileName,
      'maxProposals': ?maxProposals,
    };
    await writeWorkerRequest(worker.stdin, header, payloadLength, payload);

    final response = await _readMessage(reader).timeout(inferenceTimeout);
    if (response.requestId != requestId) {
      throw WorkerProtocolException(
        'response requestId ${response.requestId} does not match $requestId',
      );
    }
    if (response.type == 'result') {
      return response.json;
    }
    if (response.type == 'error') {
      throw WorkerRequestException(
        response.json['code']?.toString() ?? 'unknown',
        response.json['message']?.toString() ?? 'Worker request failed',
      );
    }
    throw WorkerProtocolException(
      'expected result or error for requestId $requestId, got ${response.type}',
    );
  }

  Future<WorkerMessage> _readMessage(WorkerByteReader reader) async {
    try {
      return await readWorkerMessage(reader);
    } on WorkerProtocolException catch (error) {
      if (!error.message.contains('truncated')) {
        rethrow;
      }
      final worker = _worker!;
      final exitCode = await worker.exitCode;
      throw WorkerTransportException(
        'worker exited with exit code $exitCode before sending a response',
      );
    }
  }

  Future<void> shutdown() async {
    final worker = _worker;
    if (worker == null) {
      return;
    }
    try {
      if (_ready) {
        await writeWorkerRequest(
          worker.stdin,
          const {
            'version': workerProtocolVersion,
            'type': 'shutdown',
            'requestId': 'shutdown',
          },
          0,
          const Stream<List<int>>.empty(),
        );
      }
      await worker.stdin.close();
      try {
        await worker.exitCode.timeout(shutdownTimeout);
      } on TimeoutException {
        worker.kill();
      }
    } catch (_) {
      worker.kill();
      rethrow;
    } finally {
      _clearWorker();
    }
  }

  Future<void> kill() async {
    _worker?.kill();
    _clearWorker();
  }

  void _clearWorker() {
    _worker = null;
    _reader = null;
    _startFuture = null;
    _ready = false;
  }

  void _recordStderr(String line) {
    _stderr.add(line);
    if (_stderr.length > 50) {
      _stderr.removeAt(0);
    }
  }
}

Future<BreadWorkerHandle> _defaultStartWorker(
  String executable,
  List<String> arguments,
) async {
  final process = await Process.start(executable, arguments);
  return _ProcessBreadWorkerHandle(process);
}

class _ProcessBreadWorkerHandle implements BreadWorkerHandle {
  _ProcessBreadWorkerHandle(this._process);

  final Process _process;

  @override
  IOSink get stdin => _process.stdin;

  @override
  Stream<List<int>> get stdoutBytes => _process.stdout;

  @override
  Stream<String> get stderrLines =>
      _process.stderr.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  bool kill() => _process.kill();
}
