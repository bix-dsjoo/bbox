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

  test('existing boxes are not replaced without explicit permission', () async {
    final runtime = FakeAutoBoxRuntime(
      detectionResult: _oneBoxResult('replacement-box'),
    );
    final controller = AppController(autoBoxRuntime: runtime)
      ..loadProject(_project());
    addTearDown(controller.dispose);

    await controller.detectSelectedImage();

    expect(runtime.detectCount, 0);
    expect(controller.selectedImage!.visibleBoxes.single.id, 'box-1');
    expect(
      controller.lastUserMessage,
      WorkbenchCopy.autoBoxesReplacementConfirmationRequired,
    );
  });

  test('explicit replacement is one undo operation', () async {
    final runtime = FakeAutoBoxRuntime(
      detectionResult: _oneBoxResult('replacement-box'),
    );
    final controller = AppController(autoBoxRuntime: runtime)
      ..loadProject(_project());
    addTearDown(controller.dispose);

    await controller.detectSelectedImage(replaceExisting: true);

    expect(controller.selectedImage!.visibleBoxes.single.id, 'replacement-box');
    controller.undo();
    expect(controller.selectedImage!.visibleBoxes.single.id, 'box-1');
    expect(controller.canUndo, isFalse);
  });

  test('accepting selected review suggestion records a user label', () {
    final reviewBox = const BoundingBox(
      id: 'review-box',
      x: 10,
      y: 10,
      width: 20,
      height: 20,
      status: BoxStatus.proposal,
      automation: BoxAutomationMetadata(
        suggestedLabelId: 1,
        reviewReasons: ['low_margin'],
        pipelineVersion: 'test-v1',
        policyVersion: 'test-policy-v1',
        detectorSha256: 'detector-hash',
      ),
    );
    final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime())
      ..loadProject(
        _project().copyWith(
          images: [
            _project().images.first.copyWith(boxes: [reviewBox]),
          ],
        ),
      )
      ..selectBox('review-box');
    addTearDown(controller.dispose);

    controller.acceptSelectedSuggestedLabel();

    final accepted = controller.selectedBox!;
    expect(accepted.status, BoxStatus.labeled);
    expect(accepted.labelId, 1);
    expect(accepted.labelSource, LabelSource.user);
    expect(accepted.requiresLabelReview, isFalse);
    expect(controller.canUndo, isTrue);
  });

  test('editing an auto-labeled box makes it gray immediately', () {
    final controller = AppController(autoBoxRuntime: FakeAutoBoxRuntime())
      ..loadProject(_autoLabeledProject())
      ..selectBox('auto-box');
    addTearDown(controller.dispose);

    controller.setSelectedBoxGeometry(x: 20, y: 20, width: 30, height: 30);

    expect(controller.selectedBox!.status, BoxStatus.proposal);
    expect(controller.selectedBox!.labelId, isNull);
    expect(controller.selectedBox!.labelSource, isNull);
    expect(controller.selectedBox!.automation, isNull);
  });

  test('rapid geometry edits produce one classify request', () async {
    final runtime = FakeAutoBoxRuntime();
    final controller = AppController(autoBoxRuntime: runtime)
      ..loadProject(_autoLabeledProject())
      ..selectBox('auto-box');
    addTearDown(controller.dispose);

    controller.moveSelectedBox(1, 0);
    controller.moveSelectedBox(1, 0);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(runtime.classifyCount, 1);
  });

  test('edited box applies a validated automatic classification', () async {
    final runtime = FakeAutoBoxRuntime(
      detectionResult: _acceptedClassificationResult(x: 11),
    );
    final controller = AppController(autoBoxRuntime: runtime)
      ..loadProject(_autoLabeledProject())
      ..selectBox('auto-box');
    addTearDown(controller.dispose);

    controller.moveSelectedBox(1, 0);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(controller.selectedBox!.status, BoxStatus.labeled);
    expect(controller.selectedBox!.labelId, 1);
    expect(controller.selectedBox!.labelSource, LabelSource.auto);
    expect(controller.selectedBox!.x, 11);
  });

  test(
    'returning to cached geometry avoids another classify request',
    () async {
      final runtime = FakeAutoBoxRuntime(
        detectionResult: _acceptedClassificationResult(x: 11),
      );
      final controller = AppController(autoBoxRuntime: runtime)
        ..loadProject(_autoLabeledProject())
        ..selectBox('auto-box');
      addTearDown(controller.dispose);

      controller.moveSelectedBox(1, 0);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      controller.setSelectedBoxGeometry(x: 10, y: 10, width: 20, height: 20);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      controller.setSelectedBoxGeometry(x: 11, y: 10, width: 20, height: 20);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(runtime.classifyCount, 2);
      expect(controller.selectedBox!.isAutoLabeled, isTrue);
    },
  );

  test('new manual box is classified after drawing completes', () async {
    final runtime = FakeAutoBoxRuntime();
    final controller = AppController(autoBoxRuntime: runtime)
      ..loadProject(_project());
    addTearDown(controller.dispose);

    controller.addBox(x: 10, y: 12, width: 20, height: 24);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(runtime.classifyCount, 1);
  });

  test('latest edit is classified after an earlier request finishes', () async {
    final first = Completer<DetectionResult>();
    late final FakeAutoBoxRuntime runtime;
    runtime = FakeAutoBoxRuntime(
      classifyHandler: (_, boxes) {
        if (runtime.classifyCount == 1) return first.future;
        final box = boxes.single;
        return Future.value(_acceptedClassificationResult(x: box.x));
      },
    );
    final controller = AppController(autoBoxRuntime: runtime)
      ..loadProject(_autoLabeledProject())
      ..selectBox('auto-box');
    addTearDown(controller.dispose);

    controller.moveSelectedBox(1, 0);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.moveSelectedBox(1, 0);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    first.complete(_acceptedClassificationResult(x: 11));
    await Future<void>.delayed(const Duration(milliseconds: 350));

    expect(runtime.classifyCount, 2);
    expect(controller.selectedBox!.x, 12);
    expect(controller.selectedBox!.isAutoLabeled, isTrue);
  });

  test('manual label wins over an in-flight automatic result', () async {
    final classification = Completer<DetectionResult>();
    final runtime = FakeAutoBoxRuntime(
      classifyHandler: (_, _) => classification.future,
    );
    final controller = AppController(autoBoxRuntime: runtime)
      ..loadProject(_autoLabeledProject())
      ..selectBox('auto-box');
    addTearDown(controller.dispose);

    controller.moveSelectedBox(1, 0);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.assignSelectedBoxLabel(1);
    classification.complete(_acceptedClassificationResult(x: 11));
    await Future<void>.delayed(Duration.zero);

    expect(controller.selectedBox!.labelId, 1);
    expect(controller.selectedBox!.labelSource, LabelSource.user);
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

    await controller.detectSelectedImage(replaceExisting: true);

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

      final first = controller.detectSelectedImage(replaceExisting: true);
      await Future<void>.delayed(Duration.zero);

      expect(controller.isAutoBoxRunning, isTrue);
      expect(controller.isAutomationRunning, isTrue);

      final second = controller.detectSelectedImage(replaceExisting: true);
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

    await controller.detectSelectedImage(replaceExisting: true);

    expect(runtime.detectCount, 1);
    expect(controller.isAutoBoxRunning, isFalse);
    expect(controller.isAutomationRunning, isFalse);
  });

  test(
    'cancelling detection restores project selection and busy state',
    () async {
      final completer = Completer<DetectionResult>();
      final runtime = FakeAutoBoxRuntime(detectionCompleter: completer);
      final controller = AppController(autoBoxRuntime: runtime)
        ..loadProject(_project())
        ..selectBox('box-1');
      addTearDown(controller.dispose);
      final projectBefore = controller.project;

      final detection = controller.detectSelectedImage(replaceExisting: true);
      await Future<void>.delayed(Duration.zero);
      await controller.cancelAutoBoxes();
      await detection;

      expect(runtime.cancelCount, 1);
      expect(controller.project, same(projectBefore));
      expect(controller.selectedBoxId, 'box-1');
      expect(controller.isAutomationRunning, isFalse);
      expect(controller.lastError, isNull);
      expect(controller.lastUserMessage, WorkbenchCopy.autoBoxesCancelled);
    },
  );

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

      await controller.detectSelectedImage(replaceExisting: true);

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

  test('auto box preserves valid detector labels', () async {
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
      ..loadProject(_confirmedProject());
    addTearDown(controller.dispose);

    await controller.detectSelectedImage(replaceExisting: true);

    final boxes = controller.selectedImage!.visibleBoxes.toList();
    expect(boxes, hasLength(2));
    expect(boxes[0].status, BoxStatus.labeled);
    expect(boxes[0].labelId, 1);
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

    final detection = controller.detectSelectedImage(replaceExisting: true);
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

      final detection = controller.detectSelectedImage(replaceExisting: true);
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

    final detection = controller.detectSelectedImage(replaceExisting: true);
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

      await controller.detectSelectedImage(replaceExisting: true);

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

      await controller.detectSelectedImage(replaceExisting: true);

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

      await controller.detectSelectedImage(replaceExisting: true);

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

      await controller.detectSelectedImage(replaceExisting: true);

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

    await controller.detectSelectedImage(replaceExisting: true);

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

      final detection = controller.detectSelectedImage(replaceExisting: true);
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

    final first = controller.detectSelectedImage(replaceExisting: true);
    await Future<void>.delayed(Duration.zero);
    controller.loadProject(_project(name: 'second'));
    runtime.detectionCompleter = secondCompleter;
    final second = controller.detectSelectedImage(replaceExisting: true);
    await Future<void>.delayed(Duration.zero);

    firstCompleter.complete(_oneBoxResult('stale-first-box'));
    await first;
    final runningAfterFirstCompleted = controller.isAutomationRunning;
    final activityAfterFirstCompleted = controller.lastUserMessage;

    final third = controller.detectSelectedImage(replaceExisting: true);
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

DetectionResult _acceptedClassificationResult({required double x}) {
  return DetectionResult(
    detectorName: 'fake-auto-box-runtime',
    imageSha256: 'image-hash',
    pipelineVersion: 'test-v1',
    boxes: [
      BoundingBox(
        id: 'auto-box',
        x: x,
        y: 10,
        width: 20,
        height: 20,
        status: BoxStatus.labeled,
        labelId: 1,
        labelSource: LabelSource.auto,
        automation: const BoxAutomationMetadata(
          candidates: [LabelCandidate(labelId: 1, score: 0.96)],
          pipelineVersion: 'test-v1',
          policyVersion: 'test-policy-v1',
          detectorSha256: 'detector-hash',
        ),
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

AnnotationProject _autoLabeledProject() {
  return AnnotationProject.empty(name: 'auto-labeled').copyWith(
    labels: const [LabelClass(id: 1, name: 'Bread', color: 0xFFAA5500)],
    images: const [
      AnnotatedImage(
        id: 1,
        sourcePath: 'a.jpg',
        displayName: 'a.jpg',
        width: 100,
        height: 80,
        status: ImageStatus.needsReview,
        contentSha256: 'image-hash',
        boxes: [
          BoundingBox(
            id: 'auto-box',
            x: 10,
            y: 10,
            width: 20,
            height: 20,
            status: BoxStatus.labeled,
            labelId: 1,
            labelSource: LabelSource.auto,
            automation: BoxAutomationMetadata(
              candidates: [LabelCandidate(labelId: 1, score: 0.95)],
              pipelineVersion: 'test-v1',
              policyVersion: 'test-policy-v1',
              detectorSha256: 'detector-hash',
            ),
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
         pipelineManifestPath: 'bread_pipeline_manifest.json',
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
