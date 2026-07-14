import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bbox_labeler/detector/bread_worker_client.dart';
import 'package:bbox_labeler/detector/worker_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('start launches worker with the pipeline manifest', () async {
    final handle = FakeBreadWorkerHandle();
    List<String>? startedArguments;
    final client = BreadWorkerClient(
      pythonExecutable: 'python.exe',
      scriptPath: 'bread_box_worker.py',
      pipelineManifestPath: 'models/bread_pipeline_manifest.json',
      startWorker: (executable, arguments) async {
        startedArguments = arguments;
        return handle;
      },
    );

    final startFuture = client.start();
    await Future<void>.delayed(Duration.zero);
    handle.emitMessage(const {'version': 2, 'type': 'ready'});
    await startFuture;

    expect(startedArguments, [
      'bread_box_worker.py',
      '--pipeline-manifest',
      'models/bread_pipeline_manifest.json',
    ]);
  });

  test('start waits for ready and detect reuses the same process', () async {
    final handle = FakeBreadWorkerHandle();
    var starterCalls = 0;
    final client = testClient(
      handle,
      startWorker: (executable, arguments) async {
        starterCalls++;
        return handle;
      },
    );
    var started = false;

    final startFuture = client.start().then((_) => started = true);
    await Future<void>.delayed(Duration.zero);
    expect(started, isFalse);

    handle.emitMessage(const {'version': 2, 'type': 'ready'});
    await startFuture;

    for (final requestId in ['1', '2']) {
      final requestFuture = handle.nextRequest();
      final resultFuture = client.detect(
        requestId: requestId,
        fileName: '한글 image.png',
        payloadLength: 3,
        payload: Stream<List<int>>.value(const [1, 2, 3]),
      );
      final request = await requestFuture;
      handle.emitMessage({
        'version': 2,
        'type': 'result',
        'requestId': request.header['requestId'],
        'image': {'width': 10, 'height': 20},
        'boxes': <Object?>[],
      });
      final result = await resultFuture;
      expect(result['requestId'], requestId);
    }

    expect(starterCalls, 1);
  });

  test('start rejects result before ready', () async {
    final handle = FakeBreadWorkerHandle();
    final client = testClient(handle);
    final startFuture = client.start();
    await Future<void>.delayed(Duration.zero);

    handle.emitMessage(const {
      'version': 2,
      'type': 'result',
      'requestId': 'early',
    });

    await expectLater(
      startFuture,
      throwsA(
        isA<WorkerProtocolException>().having(
          (error) => error.message,
          'message',
          contains('ready'),
        ),
      ),
    );
  });

  test('detect rejects mismatched request id', () async {
    final handle = FakeBreadWorkerHandle();
    final client = testClient(handle);
    final startFuture = client.start();
    handle.emitMessage(const {'version': 2, 'type': 'ready'});
    await startFuture;

    final requestFuture = handle.nextRequest();
    final detectFuture = client.detect(
      requestId: '7',
      fileName: 'bread.png',
      payloadLength: 1,
      payload: Stream<List<int>>.value(const [9]),
    );
    await requestFuture;
    handle.emitMessage(const {
      'version': 2,
      'type': 'result',
      'requestId': '8',
    });

    await expectLater(
      detectFuture,
      throwsA(
        isA<WorkerProtocolException>().having(
          (error) => error.message,
          'message',
          contains('requestId'),
        ),
      ),
    );
  });

  test('stderr ring buffer retains only the latest fifty lines', () async {
    final handle = FakeBreadWorkerHandle();
    final client = testClient(handle);
    final startFuture = client.start();
    handle.emitMessage(const {'version': 2, 'type': 'ready'});
    await startFuture;

    for (var index = 0; index < 60; index++) {
      handle.emitStderr('line-$index');
    }
    await Future<void>.delayed(Duration.zero);

    expect(client.recentStderr, hasLength(50));
    expect(client.recentStderr.first, 'line-10');
    expect(client.recentStderr.last, 'line-59');
  });

  test('detect surfaces process exit as a transport failure', () async {
    final handle = FakeBreadWorkerHandle();
    final client = testClient(handle);
    final startFuture = client.start();
    handle.emitMessage(const {'version': 2, 'type': 'ready'});
    await startFuture;

    final requestFuture = handle.nextRequest();
    final detectFuture = client.detect(
      requestId: 'exit',
      fileName: 'bread.png',
      payloadLength: 1,
      payload: Stream<List<int>>.value(const [1]),
    );
    await requestFuture;
    handle.completeExit(5);
    await handle.closeStdout();

    await expectLater(
      detectFuture,
      throwsA(
        isA<WorkerTransportException>().having(
          (error) => error.message,
          'message',
          contains('exit code 5'),
        ),
      ),
    );
  });

  test(
    'mid-payload file failure leaves a partial declared frame and propagates',
    () async {
      final handle = FakeBreadWorkerHandle(propagateStdinErrors: true);
      final client = testClient(handle);
      final startFuture = client.start();
      handle.emitMessage(const {'version': 2, 'type': 'ready'});
      await startFuture;
      const fileError = FileSystemException('NAS disconnected mid-read');
      Stream<List<int>> failingPayload() async* {
        yield const [1];
        throw fileError;
      }

      final detectFuture = client.detect(
        requestId: 'partial-file',
        fileName: 'bread.png',
        payloadLength: 3,
        payload: failingPayload(),
      );

      await expectLater(detectFuture, throwsA(same(fileError)));
      await Future<void>.delayed(Duration.zero);

      final stdinBytes = Uint8List.fromList(handle._inputBytes);
      final headerLength = ByteData.sublistView(
        stdinBytes,
        0,
        4,
      ).getUint32(0, Endian.big);
      final payloadLengthOffset = 4 + headerLength;
      final header =
          jsonDecode(utf8.decode(stdinBytes.sublist(4, payloadLengthOffset)))
              as Map<String, Object?>;
      final declaredPayloadLength = ByteData.sublistView(
        stdinBytes,
        payloadLengthOffset,
        payloadLengthOffset + 8,
      ).getUint64(0, Endian.big);
      final writtenPayload = stdinBytes.sublist(payloadLengthOffset + 8);

      expect(header['type'], 'detect');
      expect(header['requestId'], 'partial-file');
      expect(header['fileName'], 'bread.png');
      expect(declaredPayloadLength, 3);
      expect(writtenPayload, const [1]);
      expect(writtenPayload.length, lessThan(declaredPayloadLength));
      expect(handle._requests, isEmpty);
    },
  );

  test('successful detects do not poll process exit code', () async {
    final handle = FakeBreadWorkerHandle();
    final client = testClient(handle);
    final startFuture = client.start();
    handle.emitMessage(const {'version': 2, 'type': 'ready'});
    await startFuture;

    for (final requestId in ['first', 'second']) {
      final requestFuture = handle.nextRequest();
      final detectFuture = client.detect(
        requestId: requestId,
        fileName: 'bread.png',
        payloadLength: 1,
        payload: Stream<List<int>>.value(const [1]),
      );
      await requestFuture;
      handle.emitMessage({
        'version': 2,
        'type': 'result',
        'requestId': requestId,
        'image': {'width': 10, 'height': 20},
        'boxes': <Object?>[],
      });
      await detectFuture;
    }

    expect(handle.exitCodeAccesses, 0);
  });

  test('detect times out using injected duration', () async {
    final handle = FakeBreadWorkerHandle();
    final client = testClient(
      handle,
      inferenceTimeout: const Duration(milliseconds: 1),
    );
    final startFuture = client.start();
    handle.emitMessage(const {'version': 2, 'type': 'ready'});
    await startFuture;

    final requestFuture = handle.nextRequest();
    final detectFuture = client.detect(
      requestId: 'slow',
      fileName: 'bread.png',
      payloadLength: 1,
      payload: Stream<List<int>>.value(const [1]),
    );
    await requestFuture;

    await expectLater(detectFuture, throwsA(isA<TimeoutException>()));
  });

  test('decode_failed is non-retryable', () async {
    final error = await requestError('decode_failed');

    expect(error.retryable, isFalse);
  });

  test('inference_failed is retryable', () async {
    final error = await requestError('inference_failed');

    expect(error.retryable, isTrue);
  });

  test('shutdown kills process after two-second timeout', () async {
    final handle = FakeBreadWorkerHandle();
    final client = testClient(
      handle,
      shutdownTimeout: const Duration(milliseconds: 1),
    );
    final startFuture = client.start();
    handle.emitMessage(const {'version': 2, 'type': 'ready'});
    await startFuture;

    final requestFuture = handle.nextRequest();
    final shutdownFuture = client.shutdown();
    final request = await requestFuture;
    expect(request.header['type'], 'shutdown');
    expect(request.payload, isEmpty);
    await shutdownFuture;

    expect(handle.killCalls, 1);
  });

  test('shutdown write failure kills worker and permits restart', () async {
    final firstHandle = FakeBreadWorkerHandle();
    final secondHandle = FakeBreadWorkerHandle();
    final handles = [firstHandle, secondHandle];
    var starterCalls = 0;
    final client = testClient(
      firstHandle,
      startWorker: (_, _) async => handles[starterCalls++],
    );
    final firstStart = client.start();
    firstHandle.emitMessage(const {'version': 2, 'type': 'ready'});
    await firstStart;
    await firstHandle.stdin.close();

    await expectLater(client.shutdown(), throwsA(anything));

    final secondStart = client.start();
    secondHandle.emitMessage(const {'version': 2, 'type': 'ready'});
    await secondStart;
    expect(starterCalls, 2);
    expect(firstHandle.killCalls, 1);
  });
}

Future<WorkerRequestException> requestError(String code) async {
  final handle = FakeBreadWorkerHandle();
  final client = testClient(handle);
  final startFuture = client.start();
  handle.emitMessage(const {'version': 2, 'type': 'ready'});
  await startFuture;
  final requestFuture = handle.nextRequest();
  final detectFuture = client.detect(
    requestId: 'error',
    fileName: 'bread.png',
    payloadLength: 1,
    payload: Stream<List<int>>.value(const [1]),
  );
  await requestFuture;
  handle.emitMessage({
    'version': 2,
    'type': 'error',
    'requestId': 'error',
    'code': code,
    'message': '$code message',
  });

  try {
    await detectFuture;
  } on WorkerRequestException catch (error) {
    expect(error.code, code);
    expect(error.message, '$code message');
    return error;
  }
  fail('detect should throw WorkerRequestException');
}

BreadWorkerClient testClient(
  FakeBreadWorkerHandle handle, {
  BreadWorkerStarter? startWorker,
  Duration inferenceTimeout = const Duration(seconds: 120),
  Duration shutdownTimeout = const Duration(seconds: 2),
}) {
  return BreadWorkerClient(
    pythonExecutable: 'python.exe',
    scriptPath: 'bread_box_worker.py',
    pipelineManifestPath: 'bread_pipeline_manifest.json',
    inferenceTimeout: inferenceTimeout,
    shutdownTimeout: shutdownTimeout,
    startWorker: startWorker ?? (_, _) async => handle,
  );
}

class RecordedRequest {
  const RecordedRequest(this.header, this.payload);

  final Map<String, Object?> header;
  final List<int> payload;
}

class FakeBreadWorkerHandle implements BreadWorkerHandle {
  FakeBreadWorkerHandle({bool propagateStdinErrors = false})
    : _stdin = StreamController<List<int>>(),
      _stdout = StreamController<List<int>>(),
      _stderr = StreamController<String>(),
      _exitCode = Completer<int>() {
    if (propagateStdinErrors) {
      stdin = IOSink(_RecordingStreamConsumer(_recordInput));
    } else {
      stdin = IOSink(_stdin.sink);
      _stdin.stream.listen(_recordInput);
    }
  }

  final StreamController<List<int>> _stdin;
  final StreamController<List<int>> _stdout;
  final StreamController<String> _stderr;
  final Completer<int> _exitCode;
  final List<int> _inputBytes = <int>[];
  final Queue<RecordedRequest> _requests = Queue<RecordedRequest>();
  final Queue<Completer<RecordedRequest>> _requestWaiters =
      Queue<Completer<RecordedRequest>>();
  int killCalls = 0;
  int exitCodeAccesses = 0;

  @override
  late final IOSink stdin;

  @override
  Stream<List<int>> get stdoutBytes => _stdout.stream;

  @override
  Stream<String> get stderrLines => _stderr.stream;

  @override
  Future<int> get exitCode {
    exitCodeAccesses++;
    return _exitCode.future;
  }

  @override
  bool kill() {
    killCalls++;
    return true;
  }

  void emitMessage(Map<String, Object?> message) {
    final bytes = utf8.encode(jsonEncode(message));
    _stdout.add([...uint32Bytes(bytes.length), ...bytes]);
  }

  void emitStderr(String line) => _stderr.add(line);

  void completeExit(int code) => _exitCode.complete(code);

  Future<void> closeStdout() => _stdout.close();

  Future<RecordedRequest> nextRequest() {
    if (_requests.isNotEmpty) {
      return Future<RecordedRequest>.value(_requests.removeFirst());
    }
    final completer = Completer<RecordedRequest>();
    _requestWaiters.add(completer);
    return completer.future;
  }

  void _recordInput(List<int> chunk) {
    _inputBytes.addAll(chunk);
    _parseRequests();
  }

  void _parseRequests() {
    while (_inputBytes.length >= 4) {
      final allBytes = Uint8List.fromList(_inputBytes);
      final headerLength = ByteData.sublistView(
        allBytes,
        0,
        4,
      ).getUint32(0, Endian.big);
      final payloadLengthOffset = 4 + headerLength;
      if (_inputBytes.length < payloadLengthOffset + 8) {
        return;
      }
      final payloadLength = ByteData.sublistView(
        allBytes,
        payloadLengthOffset,
        payloadLengthOffset + 8,
      ).getUint64(0, Endian.big);
      final frameLength = payloadLengthOffset + 8 + payloadLength;
      if (_inputBytes.length < frameLength) {
        return;
      }
      final header =
          jsonDecode(utf8.decode(_inputBytes.sublist(4, payloadLengthOffset)))
              as Map<String, Object?>;
      final payload = _inputBytes.sublist(payloadLengthOffset + 8, frameLength);
      _inputBytes.removeRange(0, frameLength);
      _deliverRequest(RecordedRequest(header, payload));
    }
  }

  void _deliverRequest(RecordedRequest request) {
    if (_requestWaiters.isNotEmpty) {
      _requestWaiters.removeFirst().complete(request);
    } else {
      _requests.add(request);
    }
  }
}

class _RecordingStreamConsumer implements StreamConsumer<List<int>> {
  const _RecordingStreamConsumer(this.onData);

  final void Function(List<int>) onData;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      onData(chunk);
    }
  }

  @override
  Future<void> close() async {}
}

Uint8List uint32Bytes(int value) {
  final data = ByteData(4)..setUint32(0, value, Endian.big);
  return data.buffer.asUint8List();
}
