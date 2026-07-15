import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/detector/auto_box_service.dart';
import 'package:bbox_labeler/detector/bread_worker_client.dart';
import 'package:bbox_labeler/detector/worker_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('warmUp', () {
    test('concurrent warmUp calls start one client', () async {
      final startCompleter = Completer<void>();
      final client = FakeBreadWorkerClient(startCompleter: startCompleter);
      var factoryCount = 0;
      final service = AutoBoxService(
        createClient: () {
          factoryCount++;
          return client;
        },
      );

      final first = service.warmUp();
      final second = service.warmUp();
      await Future<void>.delayed(Duration.zero);

      expect(factoryCount, 1);
      expect(client.startCount, 1);

      startCompleter.complete();
      await Future.wait([first, second]);
    });

    test('warmUp transitions idle starting ready', () async {
      final startCompleter = Completer<void>();
      final client = FakeBreadWorkerClient(startCompleter: startCompleter);
      final service = AutoBoxService(createClient: () => client);
      final states = <AutoBoxState>[service.state];
      service.addListener(() => states.add(service.state));

      final future = service.warmUp();
      await Future<void>.delayed(Duration.zero);
      startCompleter.complete();
      await future;

      expect(states, [
        AutoBoxState.idle,
        AutoBoxState.starting,
        AutoBoxState.ready,
      ]);
    });

    test('startup failure transitions to failed without fallback', () async {
      var factoryCount = 0;
      final client = FakeBreadWorkerClient(startError: StateError('boom'));
      final service = AutoBoxService(
        createClient: () {
          factoryCount++;
          return client;
        },
      );

      await expectLater(
        service.warmUp(),
        throwsA(isA<AutoBoxStartupException>()),
      );

      expect(service.state, AutoBoxState.failed);
      expect(service.lastError, isA<AutoBoxStartupException>());
      expect(factoryCount, 1);
    });
  });

  group('lifecycle serialization', () {
    test('warmUp during running does not start a second client', () async {
      final detectCompleter = Completer<Map<String, Object?>>();
      final client = FakeBreadWorkerClient(responses: [detectCompleter.future]);
      var factoryCount = 0;
      final service = AutoBoxService(
        createClient: () {
          factoryCount++;
          return client;
        },
        openImage: (_) async => testPayload(),
      );

      final detection = service.detect(testImage);
      await untilCalled(() => client.detectCount);

      await service.warmUp();

      expect(factoryCount, 1);
      expect(client.startCount, 1);
      expect(service.state, AutoBoxState.running);

      detectCompleter.complete(successfulWorkerResponse);
      await detection;
    });

    test('warmUp during restarting shares the pending restart', () async {
      final killCompleter = Completer<void>();
      final first = FakeBreadWorkerClient(
        responses: [WorkerTransportException('worker exited')],
        killCompleter: killCompleter,
      );
      final second = FakeBreadWorkerClient(
        responses: [successfulWorkerResponse],
      );
      final unexpectedThird = FakeBreadWorkerClient(
        responses: [successfulWorkerResponse],
      );
      final clients = Queue.of([first, second, unexpectedThird]);
      var factoryCount = 0;
      final service = AutoBoxService(
        createClient: () {
          factoryCount++;
          return clients.removeFirst();
        },
        openImage: (_) async => testPayload(),
      );

      final detection = service.detect(testImage);
      await untilState(service, AutoBoxState.restarting);
      final warmUp = service.warmUp();
      await Future<void>.delayed(Duration.zero);
      final factoryCountWhileRestarting = factoryCount;

      killCompleter.complete();
      await Future.wait([detection, warmUp]);

      expect(factoryCountWhileRestarting, 1);
      expect(factoryCount, 2);
      expect(second.startCount, 1);
      expect(unexpectedThird.startCount, 0);
    });

    test(
      'shutdown while startup is pending ends idle and kills late start',
      () async {
        final startCompleter = Completer<void>();
        final client = FakeBreadWorkerClient(startCompleter: startCompleter);
        final service = AutoBoxService(createClient: () => client);

        final warmUp = service.warmUp();
        await untilCalled(() => client.startCount);

        await service.shutdown();
        expect(service.state, AutoBoxState.idle);

        startCompleter.complete();
        await expectLater(warmUp, throwsA(isA<StateError>()));

        expect(service.state, AutoBoxState.idle);
        expect(client.shutdownCount, 1);
        expect(client.killCount, 1);
      },
    );

    test('shutdown during active detection cannot finish in ready', () async {
      final detectCompleter = Completer<Map<String, Object?>>();
      final client = FakeBreadWorkerClient(responses: [detectCompleter.future]);
      var factoryCount = 0;
      final service = AutoBoxService(
        createClient: () {
          factoryCount++;
          return client;
        },
        openImage: (_) async => testPayload(),
      );

      final detection = service.detect(testImage);
      await untilCalled(() => client.detectCount);

      await service.shutdown();
      detectCompleter.complete(successfulWorkerResponse);

      await expectLater(detection, throwsA(isA<StateError>()));
      expect(service.state, AutoBoxState.idle);
      expect(factoryCount, 1);
    });

    test('shutdown during restart prevents replacement client', () async {
      final killCompleter = Completer<void>();
      final first = FakeBreadWorkerClient(
        responses: [WorkerTransportException('worker exited')],
        killCompleter: killCompleter,
      );
      final unexpectedSecond = FakeBreadWorkerClient(
        responses: [successfulWorkerResponse],
      );
      final clients = Queue.of([first, unexpectedSecond]);
      var factoryCount = 0;
      final service = AutoBoxService(
        createClient: () {
          factoryCount++;
          return clients.removeFirst();
        },
        openImage: (_) async => testPayload(),
      );

      final detection = service.detect(testImage);
      await untilState(service, AutoBoxState.restarting);

      await service.shutdown();
      killCompleter.complete();

      await expectLater(detection, throwsA(isA<StateError>()));
      expect(service.state, AutoBoxState.idle);
      expect(factoryCount, 1);
      expect(unexpectedSecond.startCount, 0);
    });

    test(
      'warmUp during final retry cleanup does not start a third client',
      () async {
        final secondKillCompleter = Completer<void>();
        final first = FakeBreadWorkerClient(
          responses: [WorkerTransportException('first exit')],
        );
        final second = FakeBreadWorkerClient(
          responses: [WorkerProtocolException('bad retry response')],
          killCompleter: secondKillCompleter,
        );
        final third = FakeBreadWorkerClient();
        final clients = Queue.of([first, second, third]);
        var factoryCount = 0;
        final service = AutoBoxService(
          createClient: () {
            factoryCount++;
            return clients.removeFirst();
          },
          openImage: (_) async => testPayload(),
        );

        final detection = service.detect(testImage);
        await untilCalled(() => second.killCount);
        expect(service.state, AutoBoxState.running);

        await service.warmUp();
        final factoryCountDuringCleanup = factoryCount;
        final thirdStartsDuringCleanup = third.startCount;

        secondKillCompleter.complete();
        await expectLater(detection, throwsA(isA<WorkerProtocolException>()));

        expect(factoryCountDuringCleanup, 2);
        expect(thirdStartsDuringCleanup, 0);
        expect(service.state, AutoBoxState.failed);

        await service.warmUp();
        expect(factoryCount, 3);
        expect(third.startCount, 1);
        expect(service.state, AutoBoxState.ready);
      },
    );

    test('shutdown failure leaves idle and records the error', () async {
      final shutdownError = StateError('shutdown failed');
      final first = FakeBreadWorkerClient(shutdownError: shutdownError);
      final second = FakeBreadWorkerClient();
      final clients = Queue.of([first, second]);
      var factoryCount = 0;
      final service = AutoBoxService(
        createClient: () {
          factoryCount++;
          return clients.removeFirst();
        },
      );
      await service.warmUp();

      await expectLater(service.shutdown(), throwsA(same(shutdownError)));

      expect(service.state, AutoBoxState.idle);
      expect(service.lastError, same(shutdownError));
      expect(first.killCount, 1);

      await service.warmUp();
      expect(factoryCount, 2);
      expect(second.startCount, 1);
    });

    test(
      'two shutdown calls share one operation and later calls no-op',
      () async {
        final shutdownCompleter = Completer<void>();
        final client = FakeBreadWorkerClient(
          shutdownCompleter: shutdownCompleter,
        );
        final service = AutoBoxService(createClient: () => client);
        await service.warmUp();

        final first = service.shutdown();
        final second = service.shutdown();
        await Future<void>.delayed(Duration.zero);

        expect(identical(first, second), isTrue);
        expect(client.shutdownCount, 1);

        shutdownCompleter.complete();
        await Future.wait([first, second]);
        await service.shutdown();

        expect(client.shutdownCount, 1);
        expect(service.state, AutoBoxState.idle);
      },
    );
  });

  group('detect', () {
    test('two successful detections reuse one client', () async {
      final client = FakeBreadWorkerClient(
        responses: [successfulWorkerResponse, successfulWorkerResponse],
      );
      var factoryCount = 0;
      var openerCount = 0;
      final service = AutoBoxService(
        createClient: () {
          factoryCount++;
          return client;
        },
        openImage: (_) async {
          openerCount++;
          return testPayload();
        },
      );

      await service.detect(testImage);
      await service.detect(testImage);

      expect(factoryCount, 1);
      expect(client.startCount, 1);
      expect(client.detectCount, 2);
      expect(openerCount, 2);
    });

    test('transport failure restarts once and reopens image once', () async {
      final first = FakeBreadWorkerClient(
        responses: [WorkerTransportException('worker exited')],
      );
      final second = FakeBreadWorkerClient(
        responses: [successfulWorkerResponse],
      );
      final clients = Queue.of([first, second]);
      var factoryCount = 0;
      var openerCount = 0;
      final service = AutoBoxService(
        createClient: () {
          factoryCount++;
          return clients.removeFirst();
        },
        openImage: (_) async {
          openerCount++;
          return testPayload();
        },
      );

      await service.detect(testImage);

      expect(factoryCount, 2);
      expect(first.killCount, 1);
      expect(second.startCount, 1);
      expect(openerCount, 2);
      expect(first.requestIds.single, isNot(second.requestIds.single));
    });

    test('protocol failure restarts once and succeeds', () async {
      final first = FakeBreadWorkerClient(
        responses: [WorkerProtocolException('malformed json')],
      );
      final second = FakeBreadWorkerClient(
        responses: [successfulWorkerResponse],
      );
      final clients = Queue.of([first, second]);
      var factoryCount = 0;
      final service = AutoBoxService(
        createClient: () {
          factoryCount++;
          return clients.removeFirst();
        },
        openImage: (_) async => testPayload(),
      );

      await service.detect(testImage);

      expect(factoryCount, 2);
      expect(first.detectCount, 1);
      expect(second.detectCount, 1);
      expect(first.killCount, 1);
    });

    test('second retry failure does not start a third client', () async {
      final first = FakeBreadWorkerClient(
        responses: [WorkerTransportException('first exit')],
      );
      final second = FakeBreadWorkerClient(
        responses: [WorkerProtocolException('bad response')],
      );
      final clients = Queue.of([first, second]);
      var factoryCount = 0;
      final service = AutoBoxService(
        createClient: () {
          factoryCount++;
          return clients.removeFirst();
        },
        openImage: (_) async => testPayload(),
      );

      await expectLater(
        service.detect(testImage),
        throwsA(isA<WorkerProtocolException>()),
      );

      expect(factoryCount, 2);
      expect(first.detectCount, 1);
      expect(second.detectCount, 1);
      expect(service.state, AutoBoxState.failed);
    });

    test('decode_failed does not restart worker', () async {
      final client = FakeBreadWorkerClient(
        responses: [WorkerRequestException('decode_failed', 'bad image')],
      );
      var factoryCount = 0;
      var openerCount = 0;
      final service = AutoBoxService(
        createClient: () {
          factoryCount++;
          return client;
        },
        openImage: (_) async {
          openerCount++;
          return testPayload();
        },
      );

      await expectLater(
        service.detect(testImage),
        throwsA(
          isA<WorkerRequestException>().having(
            (error) => error.code,
            'code',
            'decode_failed',
          ),
        ),
      );

      expect(factoryCount, 1);
      expect(openerCount, 1);
      expect(client.killCount, 0);
      expect(service.state, AutoBoxState.ready);
    });

    test('file open failure does not restart worker', () async {
      final client = FakeBreadWorkerClient();
      var factoryCount = 0;
      final service = AutoBoxService(
        createClient: () {
          factoryCount++;
          return client;
        },
        openImage: (_) async => throw const FileSystemException('missing'),
      );

      await expectLater(
        service.detect(testImage),
        throwsA(isA<FileSystemException>()),
      );

      expect(factoryCount, 1);
      expect(client.detectCount, 0);
      expect(service.state, AutoBoxState.ready);
    });

    test('image larger than 64 MiB fails before client detect', () async {
      final client = FakeBreadWorkerClient();
      final service = AutoBoxService(
        createClient: () => client,
        openImage: (_) async => ImagePayload(
          length: maxWorkerImageBytes + 1,
          bytes: const Stream<List<int>>.empty(),
        ),
      );

      await expectLater(
        service.detect(testImage),
        throwsA(isA<WorkerProtocolException>()),
      );

      expect(client.detectCount, 0);
      expect(service.state, AutoBoxState.ready);
    });

    test('concurrent detect calls do not create a second request', () async {
      final detectCompleter = Completer<Map<String, Object?>>();
      final client = FakeBreadWorkerClient(responses: [detectCompleter.future]);
      final service = AutoBoxService(
        createClient: () => client,
        openImage: (_) async => testPayload(),
      );

      final first = service.detect(testImage);
      await untilCalled(() => client.detectCount);

      await expectLater(
        service.detect(testImage),
        throwsA(isA<AutoBoxBusyException>()),
      );
      expect(client.detectCount, 1);

      detectCompleter.complete(successfulWorkerResponse);
      await first;
    });

    for (final invalid in <String, Map<String, Object?>>{
      'missing image': {'boxes': <Object?>[]},
      'wrong image type': {'image': '100x80', 'boxes': <Object?>[]},
      'non-positive image dimensions': {
        'image': {'width': 0, 'height': 80},
        'boxes': <Object?>[],
      },
      'mismatched image dimensions': {
        'image': {'width': 99, 'height': 80},
        'boxes': <Object?>[],
      },
      'missing boxes': {
        'image': {'width': 100, 'height': 80},
      },
      'wrong boxes type': {
        'image': {'width': 100, 'height': 80},
        'boxes': 'none',
      },
      'non-finite coordinate': {
        'image': {'width': 100, 'height': 80},
        'boxes': [
          {'x': double.nan, 'y': 1, 'width': 10, 'height': 10},
        ],
      },
      'non-positive box size': {
        'image': {'width': 100, 'height': 80},
        'boxes': [
          {'x': 1, 'y': 1, 'width': 0, 'height': 10},
        ],
      },
      'out-of-bounds box': {
        'image': {'width': 100, 'height': 80},
        'boxes': [
          {'x': 90, 'y': 1, 'width': 20, 'height': 10},
        ],
      },
      'non-finite confidence': {
        'image': {'width': 100, 'height': 80},
        'boxes': [
          {
            'x': 1,
            'y': 1,
            'width': 10,
            'height': 10,
            'confidence': double.infinity,
          },
        ],
      },
    }.entries) {
      test(
        '${invalid.key} retries once then fails as protocol error',
        () async {
          final first = FakeBreadWorkerClient(responses: [invalid.value]);
          final second = FakeBreadWorkerClient(responses: [invalid.value]);
          final clients = Queue.of([first, second]);
          var factoryCount = 0;
          final service = AutoBoxService(
            createClient: () {
              factoryCount++;
              return clients.removeFirst();
            },
            openImage: (_) async => testPayload(),
          );

          await expectLater(
            service.detect(testImage),
            throwsA(isA<WorkerProtocolException>()),
          );

          expect(factoryCount, 2);
          expect(first.detectCount, 1);
          expect(second.detectCount, 1);
          expect(service.state, AutoBoxState.failed);
        },
      );
    }

    test('successful detection maps in-bounds proposal boxes', () async {
      final client = FakeBreadWorkerClient(
        responses: [
          {
            'detectorName': 'bread-yolo-boxes',
            'image': {'width': 100, 'height': 80},
            'boxes': [
              {'x': 10, 'y': 5, 'width': 20, 'height': 30, 'confidence': 0.91},
            ],
          },
        ],
      );
      final service = AutoBoxService(
        createClient: () => client,
        openImage: (_) async => testPayload(),
      );

      final result = await service.detect(testImage);

      expect(result.detectorName, 'bread-yolo-boxes');
      expect(result.boxes, hasLength(1));
      final box = result.boxes.single;
      expect(box.id, 'det-1-1');
      expect(box.x, 10);
      expect(box.y, 5);
      expect(box.width, 20);
      expect(box.height, 30);
      expect(box.status, BoxStatus.proposal);
      expect(box.labelId, isNull);
      expect(box.confidence, 0.91);
      expect(service.state, AutoBoxState.ready);
    });

    test('accepted worker label maps to an automatic real label', () async {
      final client = FakeBreadWorkerClient(responses: [acceptedWorkerResponse]);
      final service = AutoBoxService(
        createClient: () => client,
        openImage: (_) async => testPayload(),
      );

      final result = await service.detect(testImage);
      final box = result.boxes.single;

      expect(result.imageSha256, 'image-hash');
      expect(result.pipelineVersion, 'bread-pipeline-v1');
      expect(result.detectorSha256, 'detector-hash');
      expect(box.status, BoxStatus.labeled);
      expect(box.labelId, 3);
      expect(box.labelSource, LabelSource.auto);
      expect(box.automation?.candidates.single.labelId, 3);
    });

    test('review worker label maps to suggestion-only proposal', () async {
      final client = FakeBreadWorkerClient(responses: [reviewWorkerResponse]);
      final service = AutoBoxService(
        createClient: () => client,
        openImage: (_) async => testPayload(),
      );

      final box = (await service.detect(testImage)).boxes.single;

      expect(box.status, BoxStatus.proposal);
      expect(box.labelId, isNull);
      expect(box.automation?.suggestedLabelId, 3);
      expect(box.requiresLabelReview, isTrue);
    });

    test(
      'classifyBoxes preserves supplied box id and parses stage errors',
      () async {
        final response = Map<String, Object?>.from(reviewWorkerResponse)
          ..['stageErrors'] = <Object?>[
            <String, Object?>{
              'stage': 'verifier',
              'message': 'verifier unavailable',
            },
          ];
        final client = FakeBreadWorkerClient(responses: [response]);
        final service = AutoBoxService(
          createClient: () => client,
          openImage: (_) async => testPayload(),
        );
        const supplied = BoundingBox(
          id: 'manual-1',
          x: 10,
          y: 5,
          width: 20,
          height: 30,
          status: BoxStatus.proposal,
        );

        final result = await service.classifyBoxes(testImage, [supplied]);

        expect(client.classifyCount, 1);
        expect(result.boxes.single.id, 'manual-1');
        expect(result.stageErrors.single.stage, 'verifier');
        expect(result.stageErrors.single.code, 'stage_failed');
      },
    );

    test(
      'classification protocol failure restarts once and recovers',
      () async {
        final failedClient = FakeBreadWorkerClient(
          responses: [WorkerProtocolException('bad classify response')],
        );
        final replacementClient = FakeBreadWorkerClient(
          responses: [reviewWorkerResponse],
        );
        final clients = Queue<FakeBreadWorkerClient>.of([
          failedClient,
          replacementClient,
        ]);
        final service = AutoBoxService(
          createClient: clients.removeFirst,
          openImage: (_) async => testPayload(),
        );

        final result = await service.classifyBoxes(testImage, const [
          BoundingBox(
            id: 'manual-1',
            x: 10,
            y: 5,
            width: 20,
            height: 30,
            status: BoxStatus.proposal,
          ),
        ]);

        expect(result.boxes.single.id, 'manual-1');
        expect(failedClient.killCount, 1);
        expect(replacementClient.classifyCount, 1);
        expect(service.state, AutoBoxState.ready);
      },
    );

    test('cancel active request returns service to idle', () async {
      final pendingResponse = Completer<Map<String, Object?>>();
      final client = FakeBreadWorkerClient(responses: [pendingResponse.future]);
      final service = AutoBoxService(
        createClient: () => client,
        openImage: (_) async => testPayload(),
      );

      final pending = service.detect(testImage);
      final cancelled = expectLater(
        pending,
        throwsA(isA<AutoBoxCancelledException>()),
      );
      await untilState(service, AutoBoxState.running);
      await service.cancelActiveRequest();

      await cancelled;
      expect(service.state, AutoBoxState.idle);
      expect(client.killCount, 1);
    });
  });

  group('defaultAutoBoxService', () {
    test('app-local runtime worker and manifest win over workspace paths', () {
      final executable = p.join('C:\\Program Files', 'BBox', 'bbox.exe');
      final appDirectory = p.dirname(executable);
      final appPython = p.join(appDirectory, 'runtime', 'python', 'python.exe');
      final appWorker = p.join(
        appDirectory,
        'tools',
        'detectors',
        'bread_box_worker.py',
      );
      final appManifest = p.join(
        appDirectory,
        'models',
        'bread_pipeline_manifest.json',
      );
      final existing = {appPython, appWorker, appManifest};
      final checked = <String>[];

      final service = defaultAutoBoxService(
        environment: const {},
        executablePath: executable,
        fileExists: (path) {
          checked.add(path);
          return existing.contains(path);
        },
      );

      expect(service.name, 'bread-yolo-boxes');
      expect(checked, [appPython, appWorker, appManifest]);
    });

    test('environment overrides win over app-local paths', () async {
      const python = r'D:\runtime\python.exe';
      const worker = r'D:\worker\bread_box_worker.py';
      const manifest = r'D:\models\bread_pipeline_manifest.json';
      final checked = <String>[];
      final service = defaultAutoBoxService(
        environment: const {
          'BBOX_BREAD_PYTHON': python,
          'BBOX_BREAD_WORKER': worker,
          'BBOX_BREAD_PIPELINE_MANIFEST': manifest,
        },
        executablePath: r'C:\app\bbox.exe',
        fileExists: (path) {
          checked.add(path);
          return path != manifest;
        },
      );

      await expectLater(
        service.warmUp(),
        throwsA(isA<AutoBoxStartupException>()),
      );

      expect(checked, [python, worker, manifest]);
      expect(service.lastError.toString(), contains(manifest));
      expect(service.state, AutoBoxState.failed);
    });

    test(
      'missing required assets cause warm-up failure without fallback',
      () async {
        final checked = <String>[];
        final executable = p.join('C:\\app', 'bbox.exe');
        final workspacePython = File(
          p.join('runtime', 'python', 'python.exe'),
        ).absolute.path;
        final workspaceWorker = File(
          p.join('tools', 'detectors', 'bread_box_worker.py'),
        ).absolute.path;
        final workspaceManifest = File(
          p.join('models', 'bread_pipeline_manifest.json'),
        ).absolute.path;
        final service = defaultAutoBoxService(
          environment: const {},
          executablePath: executable,
          fileExists: (path) {
            checked.add(path);
            return false;
          },
        );

        await expectLater(
          service.warmUp(),
          throwsA(isA<AutoBoxStartupException>()),
        );

        expect(service.name, 'bread-yolo-boxes');
        expect(service.state, AutoBoxState.failed);
        expect(checked.sublist(checked.length - 3), [
          workspacePython,
          workspaceWorker,
          workspaceManifest,
        ]);
        expect(service.lastError.toString(), contains(workspaceWorker));
      },
    );
  });
}

class FakeBreadWorkerClient extends BreadWorkerClient {
  FakeBreadWorkerClient({
    this.startCompleter,
    this.startError,
    this.shutdownCompleter,
    this.shutdownError,
    this.killCompleter,
    Iterable<Object> responses = const [],
  }) : responses = Queue<Object>.of(responses),
       super(
         pythonExecutable: 'python.exe',
         scriptPath: 'bread_box_worker.py',
         pipelineManifestPath: 'bread_pipeline_manifest.json',
       );

  final Completer<void>? startCompleter;
  final Object? startError;
  final Completer<void>? shutdownCompleter;
  final Object? shutdownError;
  final Completer<void>? killCompleter;
  final Queue<Object> responses;
  int startCount = 0;
  int detectCount = 0;
  int classifyCount = 0;
  int killCount = 0;
  int shutdownCount = 0;
  final List<String> requestIds = [];

  @override
  Future<void> start() async {
    startCount++;
    if (startError case final error?) {
      throw error;
    }
    await startCompleter?.future;
  }

  @override
  Future<Map<String, Object?>> detect({
    required String requestId,
    required String fileName,
    required int payloadLength,
    required Stream<List<int>> payload,
    int? maxProposals,
  }) async {
    detectCount++;
    requestIds.add(requestId);
    await payload.expand((chunk) => chunk).toList();
    final response = responses.removeFirst();
    if (response is Future<Map<String, Object?>>) {
      return response;
    }
    if (response is Map<String, Object?>) {
      return response;
    }
    throw response;
  }

  @override
  Future<Map<String, Object?>> classify({
    required String requestId,
    required String fileName,
    required int payloadLength,
    required Stream<List<int>> payload,
    required List<Map<String, Object?>> boxes,
  }) async {
    classifyCount++;
    requestIds.add(requestId);
    await payload.expand((chunk) => chunk).toList();
    final response = responses.removeFirst();
    if (response is Future<Map<String, Object?>>) return response;
    if (response is Map<String, Object?>) return response;
    throw response;
  }

  @override
  Future<void> shutdown() async {
    shutdownCount++;
    if (shutdownError case final error?) {
      throw error;
    }
    await shutdownCompleter?.future;
  }

  @override
  Future<void> kill() async {
    killCount++;
    await killCompleter?.future;
  }
}

const successfulWorkerResponse = <String, Object?>{
  'detectorName': 'bread-yolo-boxes',
  'image': <String, Object?>{'width': 100, 'height': 80},
  'boxes': <Object?>[],
};

const acceptedWorkerResponse = <String, Object?>{
  'pipelineVersion': 'bread-pipeline-v1',
  'policyVersion': 'bread-label-policy-v2',
  'detectorName': 'bread-yolo-boxes',
  'modelHashes': <String, Object?>{
    'detector': 'detector-hash',
    'classifier': 'classifier-hash',
    'verifier': null,
  },
  'image': <String, Object?>{
    'width': 100,
    'height': 80,
    'sha256': 'image-hash',
  },
  'boxes': <Object?>[
    <String, Object?>{
      'id': 'worker-1',
      'x': 10,
      'y': 5,
      'width': 20,
      'height': 30,
      'confidence': 0.91,
      'label': <String, Object?>{
        'state': 'accepted',
        'labelId': 3,
        'suggestedLabelId': null,
        'candidates': <Object?>[
          <String, Object?>{'labelId': 3, 'score': 0.98},
        ],
        'reviewReasons': <Object?>[],
        'embeddingUsed': false,
      },
    },
  ],
  'stageErrors': <Object?>[],
};

const reviewWorkerResponse = <String, Object?>{
  'pipelineVersion': 'bread-pipeline-v1',
  'policyVersion': 'bread-label-policy-v2',
  'detectorName': 'bread-yolo-boxes',
  'modelHashes': <String, Object?>{
    'detector': 'detector-hash',
    'classifier': 'classifier-hash',
    'verifier': null,
  },
  'image': <String, Object?>{
    'width': 100,
    'height': 80,
    'sha256': 'image-hash',
  },
  'boxes': <Object?>[
    <String, Object?>{
      'id': 'manual-1',
      'x': 10,
      'y': 5,
      'width': 20,
      'height': 30,
      'confidence': 0.91,
      'label': <String, Object?>{
        'state': 'review',
        'labelId': null,
        'suggestedLabelId': 3,
        'candidates': <Object?>[
          <String, Object?>{'labelId': 3, 'score': 0.72},
          <String, Object?>{'labelId': 5, 'score': 0.24},
        ],
        'reviewReasons': <Object?>['classifier_ambiguous'],
        'embeddingUsed': false,
      },
    },
  ],
  'stageErrors': <Object?>[],
};

ImagePayload testPayload() =>
    ImagePayload(length: 3, bytes: Stream<List<int>>.value(const [1, 2, 3]));

Future<void> untilCalled(int Function() count) async {
  while (count() == 0) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> untilState(AutoBoxService service, AutoBoxState state) async {
  while (service.state != state) {
    await Future<void>.delayed(Duration.zero);
  }
}

const testImage = AnnotatedImage(
  id: 1,
  sourcePath: 'bread.png',
  displayName: 'bread.png',
  width: 100,
  height: 80,
  status: ImageStatus.queued,
);
