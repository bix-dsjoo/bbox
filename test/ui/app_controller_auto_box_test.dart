import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/detector/auto_box_service.dart';
import 'package:bbox_labeler/detector/bread_worker_client.dart';
import 'package:bbox_labeler/detector/detector.dart';
import 'package:bbox_labeler/detector/worker_protocol.dart';
import 'package:bbox_labeler/ui/app_controller.dart';
import 'package:bbox_labeler/ui/workbench_copy.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_auto_box_runtime.dart';

void main() {
  test('controller exposes auto box service state', () {
    final runtime = FakeAutoBoxRuntime();
    final controller = AppController(autoBoxRuntime: runtime);
    addTearDown(controller.dispose);
    var notificationCount = 0;
    controller.addListener(() => notificationCount++);

    runtime.setState(AutoBoxState.restarting);

    expect(controller.autoBoxState, AutoBoxState.restarting);
    expect(notificationCount, 1);
  });

  test('controller warmUp delegates once to service', () async {
    final runtime = FakeAutoBoxRuntime(state: AutoBoxState.idle);
    final controller = AppController(autoBoxRuntime: runtime);
    addTearDown(controller.dispose);

    await controller.warmUpAutoBoxes();

    expect(runtime.warmUpCount, 1);
  });

  test('failed service remains manually retryable', () async {
    final runtime = FakeAutoBoxRuntime(
      state: AutoBoxState.failed,
      detectionResult: const DetectionResult(
        detectorName: 'recovered-runtime',
        boxes: [
          BoundingBox(
            id: 'recovered-box',
            x: 10,
            y: 12,
            width: 20,
            height: 24,
            status: BoxStatus.proposal,
          ),
        ],
      ),
    );
    final controller = AppController(autoBoxRuntime: runtime)
      ..loadProject(_project());
    addTearDown(controller.dispose);

    expect(controller.canRunAutoBoxes, isTrue);

    await controller.detectSelectedImage();

    expect(runtime.warmUpCount, 1);
    expect(runtime.detectCount, 1);
    expect(controller.selectedImage!.visibleBoxes.single.id, 'recovered-box');
  });

  test(
    'auto box running state blocks duplicate detection and clears on success',
    () async {
      final completer = Completer<DetectionResult>();
      final runtime = FakeAutoBoxRuntime(detectionCompleter: completer);
      final controller = AppController(autoBoxRuntime: runtime)
        ..loadProject(_project());
      addTearDown(controller.dispose);

      final first = controller.detectSelectedImage();
      await Future<void>.delayed(Duration.zero);

      expect(controller.isAutoBoxRunning, isTrue);
      expect(controller.isAutomationRunning, isTrue);

      final second = controller.detectSelectedImage();
      await Future<void>.delayed(Duration.zero);
      expect(runtime.detectCount, 1);

      completer.complete(
        const DetectionResult(detectorName: 'fake', boxes: []),
      );
      await first;
      await second;

      expect(controller.isAutoBoxRunning, isFalse);
      expect(controller.isAutomationRunning, isFalse);
    },
  );

  test('auto box running state clears when detection fails', () async {
    final runtime = FakeAutoBoxRuntime(
      detectionError: StateError('detector failed'),
    );
    final controller = AppController(autoBoxRuntime: runtime)
      ..loadProject(_project());
    addTearDown(controller.dispose);

    await controller.detectSelectedImage();

    expect(runtime.detectCount, 1);
    expect(controller.isAutoBoxRunning, isFalse);
    expect(controller.isAutomationRunning, isFalse);
  });

  for (final mapping in <String, (Object, String)>{
    'file or NAS I/O failure': (
      const FileSystemException('permission denied'),
      WorkbenchCopy.autoBoxesFileUnavailable,
    ),
    'decode_failed response': (
      WorkerRequestException('decode_failed', 'bad bytes'),
      WorkbenchCopy.autoBoxesDecodeFailed,
    ),
    'model preparation failure': (
      AutoBoxStartupException(StateError('missing model')),
      WorkbenchCopy.autoBoxesModelUnavailable,
    ),
    'final worker protocol failure': (
      WorkerProtocolException('internal stderr must stay hidden'),
      WorkbenchCopy.autoBoxesWorkerFailed,
    ),
  }.entries) {
    test('${mapping.key} maps to actionable copy and preserves work', () async {
      final runtime = FakeAutoBoxRuntime(detectionError: mapping.value.$1);
      final controller = AppController(autoBoxRuntime: runtime)
        ..loadProject(_confirmedProject());
      addTearDown(controller.dispose);
      controller.selectBox('box-1');
      controller.moveSelectedBox(1, 0);
      final projectBefore = controller.project;
      final selectedBoxIdBefore = controller.selectedBoxId;
      final canUndoBefore = controller.canUndo;
      final statusBefore = controller.selectedImage!.status;
      final boxesBefore = controller.selectedImage!.boxes;

      await controller.detectSelectedImage();

      expect(controller.project, same(projectBefore));
      expect(controller.selectedBoxId, selectedBoxIdBefore);
      expect(controller.canUndo, canUndoBefore);
      expect(controller.selectedImage!.status, statusBefore);
      expect(controller.selectedImage!.boxes, same(boxesBefore));
      expect(controller.lastUserMessage, mapping.value.$2);
      expect(
        controller.lastUserMessage,
        isNot(contains('internal stderr must stay hidden')),
      );
    });
  }

  test('auto box keeps detector labels as unlabeled proposals', () async {
    final runtime = FakeAutoBoxRuntime(
      detectionResult: const DetectionResult(
        detectorName: 'pre-labeled-detector',
        boxes: [
          BoundingBox(
            id: 'det-1-1',
            x: 10,
            y: 10,
            width: 20,
            height: 20,
            status: BoxStatus.labeled,
            labelId: 1,
            confidence: 0.91,
          ),
          BoundingBox(
            id: 'det-1-2',
            x: 40,
            y: 10,
            width: 20,
            height: 20,
            status: BoxStatus.proposal,
            confidence: 0.62,
          ),
        ],
      ),
    );
    final controller = AppController(autoBoxRuntime: runtime)
      ..loadProject(_project());
    addTearDown(controller.dispose);

    await controller.detectSelectedImage();

    final boxes = controller.selectedImage!.visibleBoxes.toList();
    expect(boxes, hasLength(2));
    expect(boxes[0].status, BoxStatus.proposal);
    expect(boxes[0].labelId, isNull);
    expect(boxes[1].status, BoxStatus.proposal);
    expect(boxes[1].labelId, isNull);
  });

  test('result is discarded when project changes during detection', () async {
    final completer = Completer<DetectionResult>();
    final runtime = FakeAutoBoxRuntime(detectionCompleter: completer);
    final controller = AppController(autoBoxRuntime: runtime)
      ..loadProject(_project());
    addTearDown(controller.dispose);
    final replacement = _project(name: 'replacement').copyWith(
      images: const [
        AnnotatedImage(
          id: 9,
          sourcePath: 'replacement.jpg',
          displayName: 'replacement.jpg',
          width: 50,
          height: 50,
          status: ImageStatus.needsReview,
          boxes: [
            BoundingBox(
              id: 'replacement-box',
              x: 1,
              y: 1,
              width: 5,
              height: 5,
              status: BoxStatus.proposal,
            ),
          ],
        ),
      ],
    );

    final detection = controller.detectSelectedImage();
    await Future<void>.delayed(Duration.zero);
    controller.loadProject(replacement);
    completer.complete(_oneBoxResult('stale-box'));
    await detection;

    expect(controller.project!.name, 'replacement');
    expect(
      controller.project!.images.single.visibleBoxes.single.id,
      'replacement-box',
    );
    expect(controller.canUndo, isFalse);
    expect(
      controller.lastUserMessage,
      isNot(WorkbenchCopy.autoBoxesCreated(1)),
    );
    expect(controller.lastUserMessage, isNull);
  });

  test(
    'result is discarded when selected image changes during detection',
    () async {
      final completer = Completer<DetectionResult>();
      final runtime = FakeAutoBoxRuntime(detectionCompleter: completer);
      final controller = AppController(autoBoxRuntime: runtime)
        ..loadProject(_twoImageProject());
      addTearDown(controller.dispose);

      final detection = controller.detectSelectedImage();
      await Future<void>.delayed(Duration.zero);
      controller.selectImage(2);
      completer.complete(_oneBoxResult('stale-box'));
      await detection;

      expect(controller.selectedImageId, 2);
      expect(
        controller.project!.images[0].visibleBoxes.single.id,
        'image-1-box',
      );
      expect(
        controller.project!.images[1].visibleBoxes.single.id,
        'image-2-box',
      );
      expect(controller.canUndo, isFalse);
      expect(controller.lastUserMessage, isNull);
    },
  );

  test('stale error clears its owned running activity', () async {
    final completer = Completer<DetectionResult>();
    final runtime = FakeAutoBoxRuntime(detectionCompleter: completer);
    final controller = AppController(autoBoxRuntime: runtime)
      ..loadProject(_twoImageProject());
    addTearDown(controller.dispose);

    final detection = controller.detectSelectedImage();
    await Future<void>.delayed(Duration.zero);
    controller.selectImage(2);
    completer.completeError(WorkerProtocolException('stale failure'));
    await detection;

    expect(controller.selectedImageId, 2);
    expect(controller.lastUserMessage, isNull);
    expect(controller.lastError, isNull);
  });

  test(
    'service failure preserves boxes selection status and undo depth',
    () async {
      final runtime = FakeAutoBoxRuntime(
        detectionError: StateError('service failed'),
      );
      final controller = AppController(autoBoxRuntime: runtime)
        ..loadProject(_confirmedProject());
      addTearDown(controller.dispose);
      controller.selectBox('box-1');
      controller.moveSelectedBox(1, 0);
      final projectBefore = controller.project;
      final selectedBoxIdBefore = controller.selectedBoxId;
      final canUndoBefore = controller.canUndo;
      final statusBefore = controller.selectedImage!.status;
      final boxesBefore = controller.selectedImage!.boxes;

      await controller.detectSelectedImage();

      expect(controller.project, same(projectBefore));
      expect(controller.selectedBoxId, selectedBoxIdBefore);
      expect(controller.canUndo, canUndoBefore);
      expect(controller.selectedImage!.status, statusBefore);
      expect(controller.selectedImage!.boxes, same(boxesBefore));
      expect(controller.lastUserMessage, WorkbenchCopy.autoBoxesWorkerFailed);
    },
  );

  test(
    'mid-payload file failure discards worker until explicit fresh retry',
    () async {
      final first = _ControllerBreadWorkerClient(
        responses: [successfulWorkerResponse],
      );
      final second = _ControllerBreadWorkerClient(
        responses: [successfulWorkerResponse],
      );
      final clients = Queue.of([first, second]);
      var factoryCount = 0;
      var openCount = 0;
      final service = AutoBoxService(
        createClient: () {
          factoryCount++;
          return clients.removeFirst();
        },
        openImage: (_) async {
          openCount++;
          if (openCount == 1) {
            return ImagePayload(
              length: 3,
              bytes: Stream<List<int>>.multi((stream) {
                stream.add(const [1]);
                stream.addError(
                  const FileSystemException('NAS disconnected mid-read'),
                );
              }),
            );
          }
          return ImagePayload(
            length: 3,
            bytes: Stream<List<int>>.value(const [1, 2, 3]),
          );
        },
      );
      final controller = AppController(autoBoxRuntime: service)
        ..loadProject(_confirmedProject());
      addTearDown(controller.dispose);
      controller.selectBox('box-1');
      controller.moveSelectedBox(1, 0);
      final projectBefore = controller.project;
      final selectedBoxIdBefore = controller.selectedBoxId;
      final canUndoBefore = controller.canUndo;
      final statusBefore = controller.selectedImage!.status;
      final boxesBefore = controller.selectedImage!.boxes;

      await controller.detectSelectedImage();

      expect(controller.project, same(projectBefore));
      expect(controller.selectedBoxId, selectedBoxIdBefore);
      expect(controller.canUndo, canUndoBefore);
      expect(controller.selectedImage!.status, statusBefore);
      expect(controller.selectedImage!.boxes, same(boxesBefore));
      expect(
        controller.lastUserMessage,
        WorkbenchCopy.autoBoxesFileUnavailable,
      );
      expect(service.lastError, isA<FileSystemException>());
      expect(service.state, AutoBoxState.failed);
      expect(factoryCount, 1);
      expect(first.killCount, 1);
      expect(second.startCount, 0);

      await controller.detectSelectedImage();

      expect(factoryCount, 2);
      expect(second.startCount, 1);
      expect(second.detectCount, 1);
      expect(service.state, AutoBoxState.ready);
    },
  );

  test(
    'replacement ProcessException uses final worker copy without third worker',
    () async {
      final first = _ControllerBreadWorkerClient(
        responses: [WorkerTransportException('first worker exited')],
      );
      final replacement = _ControllerBreadWorkerClient(
        startError: const ProcessException(
          'python.exe',
          <String>[],
          'replacement start failed',
        ),
      );
      final unexpectedThird = _ControllerBreadWorkerClient();
      final clients = Queue.of([first, replacement, unexpectedThird]);
      var factoryCount = 0;
      final service = AutoBoxService(
        createClient: () {
          factoryCount++;
          return clients.removeFirst();
        },
        openImage: (_) async => ImagePayload(
          length: 3,
          bytes: Stream<List<int>>.value(const [1, 2, 3]),
        ),
      );
      final controller = AppController(autoBoxRuntime: service)
        ..loadProject(_confirmedProject());
      addTearDown(controller.dispose);
      controller.selectBox('box-1');
      controller.moveSelectedBox(1, 0);
      final projectBefore = controller.project;
      final selectedBoxIdBefore = controller.selectedBoxId;
      final canUndoBefore = controller.canUndo;
      final statusBefore = controller.selectedImage!.status;
      final boxesBefore = controller.selectedImage!.boxes;

      await controller.detectSelectedImage();

      expect(controller.project, same(projectBefore));
      expect(controller.selectedBoxId, selectedBoxIdBefore);
      expect(controller.canUndo, canUndoBefore);
      expect(controller.selectedImage!.status, statusBefore);
      expect(controller.selectedImage!.boxes, same(boxesBefore));
      expect(controller.lastUserMessage, WorkbenchCopy.autoBoxesWorkerFailed);
      expect(service.lastError, isA<WorkerTransportException>());
      expect(service.state, AutoBoxState.failed);
      expect(factoryCount, 2);
      expect(first.killCount, 1);
      expect(replacement.killCount, 1);
      expect(unexpectedThird.startCount, 0);
    },
  );

  test('zero boxes replaces previous boxes and remains undoable', () async {
    final runtime = FakeAutoBoxRuntime();
    final controller = AppController(autoBoxRuntime: runtime)
      ..loadProject(_project());
    addTearDown(controller.dispose);
    controller.selectBox('box-1');

    await controller.detectSelectedImage();

    expect(controller.selectedImage!.visibleBoxes, isEmpty);
    expect(controller.selectedBoxId, isNull);
    expect(controller.canUndo, isTrue);

    controller.undo();

    expect(controller.selectedImage!.visibleBoxes.single.id, 'box-1');
  });

  test(
    'same-name replacement project discards pending detection result',
    () async {
      final completer = Completer<DetectionResult>();
      final runtime = FakeAutoBoxRuntime(detectionCompleter: completer);
      final controller = AppController(autoBoxRuntime: runtime)
        ..loadProject(_project());
      addTearDown(controller.dispose);

      final detection = controller.detectSelectedImage();
      await Future<void>.delayed(Duration.zero);
      final replacement = _project();
      controller.debugSetProjectForTest(replacement);
      final replacementBeforeCompletion = controller.project;
      final saveStatusBeforeCompletion = controller.saveStatus;

      completer.complete(_oneBoxResult('stale-same-name-box'));
      await detection;

      expect(controller.project, same(replacementBeforeCompletion));
      expect(controller.selectedImage!.visibleBoxes.single.id, 'box-1');
      expect(controller.canUndo, isFalse);
      expect(controller.saveStatus, saveStatusBeforeCompletion);
      expect(
        controller.lastUserMessage,
        isNot(WorkbenchCopy.autoBoxesCreated(1)),
      );
    },
  );

  test('stale request cannot clear a newer running request', () async {
    final firstCompleter = Completer<DetectionResult>();
    final secondCompleter = Completer<DetectionResult>();
    final runtime = FakeAutoBoxRuntime(detectionCompleter: firstCompleter);
    final controller = AppController(autoBoxRuntime: runtime)
      ..loadProject(_project(name: 'first'));
    addTearDown(controller.dispose);

    final first = controller.detectSelectedImage();
    await Future<void>.delayed(Duration.zero);
    controller.loadProject(_project(name: 'second'));
    runtime.detectionCompleter = secondCompleter;
    final second = controller.detectSelectedImage();
    await Future<void>.delayed(Duration.zero);

    firstCompleter.complete(_oneBoxResult('stale-first-box'));
    await first;
    final runningAfterFirstCompleted = controller.isAutomationRunning;
    final activityAfterFirstCompleted = controller.lastUserMessage;

    final third = controller.detectSelectedImage();
    await Future<void>.delayed(Duration.zero);
    final detectCountAfterThirdAttempt = runtime.detectCount;

    secondCompleter.complete(
      const DetectionResult(detectorName: 'second', boxes: []),
    );
    await Future.wait([second, third]);

    expect(runningAfterFirstCompleted, isTrue);
    expect(activityAfterFirstCompleted, WorkbenchCopy.autoBoxesRunning);
    expect(detectCountAfterThirdAttempt, 2);
    expect(controller.isAutomationRunning, isFalse);
  });

  test('controller dispose detaches listener and shuts runtime down once', () {
    final runtime = FakeAutoBoxRuntime();
    final controller = AppController(autoBoxRuntime: runtime);
    var notificationCount = 0;
    controller.addListener(() => notificationCount++);

    controller.dispose();

    expect(runtime.shutdownCount, 1);
    expect(() => runtime.setState(AutoBoxState.restarting), returnsNormally);
    expect(notificationCount, 0);
  });
}

DetectionResult _oneBoxResult(String id) {
  return DetectionResult(
    detectorName: 'fake-auto-box-runtime',
    boxes: [
      BoundingBox(
        id: id,
        x: 2,
        y: 3,
        width: 10,
        height: 12,
        status: BoxStatus.proposal,
      ),
    ],
  );
}

AnnotationProject _project({String name = 'demo'}) {
  return AnnotationProject.empty(name: name).copyWith(
    images: const [
      AnnotatedImage(
        id: 1,
        sourcePath: 'a.jpg',
        displayName: 'a.jpg',
        width: 100,
        height: 80,
        status: ImageStatus.needsReview,
        boxes: [
          BoundingBox(
            id: 'box-1',
            x: 0,
            y: 0,
            width: 20,
            height: 20,
            status: BoxStatus.proposal,
          ),
        ],
      ),
    ],
  );
}

AnnotationProject _twoImageProject() {
  return AnnotationProject.empty(name: 'two-images').copyWith(
    images: const [
      AnnotatedImage(
        id: 1,
        sourcePath: 'one.jpg',
        displayName: 'one.jpg',
        width: 100,
        height: 80,
        status: ImageStatus.needsReview,
        boxes: [
          BoundingBox(
            id: 'image-1-box',
            x: 0,
            y: 0,
            width: 10,
            height: 10,
            status: BoxStatus.proposal,
          ),
        ],
      ),
      AnnotatedImage(
        id: 2,
        sourcePath: 'two.jpg',
        displayName: 'two.jpg',
        width: 100,
        height: 80,
        status: ImageStatus.needsReview,
        boxes: [
          BoundingBox(
            id: 'image-2-box',
            x: 20,
            y: 20,
            width: 10,
            height: 10,
            status: BoxStatus.proposal,
          ),
        ],
      ),
    ],
  );
}

AnnotationProject _confirmedProject() {
  return AnnotationProject.empty(name: 'confirmed').copyWith(
    labels: const [LabelClass(id: 1, name: 'Bread', color: 0xFFAA5500)],
    images: const [
      AnnotatedImage(
        id: 1,
        sourcePath: 'a.jpg',
        displayName: 'a.jpg',
        width: 100,
        height: 80,
        status: ImageStatus.confirmed,
        boxes: [
          BoundingBox(
            id: 'box-1',
            x: 5,
            y: 6,
            width: 20,
            height: 22,
            status: BoxStatus.labeled,
            labelId: 1,
          ),
        ],
      ),
    ],
  );
}

class _ControllerBreadWorkerClient extends BreadWorkerClient {
  _ControllerBreadWorkerClient({
    this.startError,
    Iterable<Object> responses = const [],
  }) : responses = Queue<Object>.of(responses),
       super(
         pythonExecutable: 'python.exe',
         scriptPath: 'bread_box_worker.py',
         modelPath: 'bread.pt',
       );

  final Object? startError;
  final Queue<Object> responses;
  int startCount = 0;
  int detectCount = 0;
  int killCount = 0;

  @override
  Future<void> start() async {
    startCount++;
    if (startError case final error?) {
      throw error;
    }
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
    await payload.expand((chunk) => chunk).toList();
    final response = responses.removeFirst();
    if (response is Map<String, Object?>) {
      return response;
    }
    throw response;
  }

  @override
  Future<void> kill() async {
    killCount++;
  }
}

const successfulWorkerResponse = <String, Object?>{
  'detectorName': 'bread-yolo-boxes',
  'image': <String, Object?>{'width': 100, 'height': 80},
  'boxes': <Object?>[],
};
