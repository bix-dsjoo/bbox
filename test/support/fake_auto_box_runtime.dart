import 'dart:async';

import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/detector/auto_box_service.dart';
import 'package:bbox_labeler/detector/detector.dart';
import 'package:flutter/foundation.dart';

class FakeAutoBoxRuntime extends ChangeNotifier implements AutoBoxRuntime {
  FakeAutoBoxRuntime({
    AutoBoxState state = AutoBoxState.ready,
    this.detectionResult = const DetectionResult(
      detectorName: 'fake-auto-box-runtime',
      boxes: [],
    ),
    this.detectionError,
    this.detectionCompleter,
    this.warmUpCompleter,
    this.shutdownCompleter,
  }) : _currentState = state;

  @override
  String get name => 'fake-auto-box-runtime';

  AutoBoxState _currentState;

  @override
  AutoBoxState get state => _currentState;

  @override
  Object? lastError;

  @override
  List<String> recentStderr = const [];

  DetectionResult detectionResult;
  Object? detectionError;
  Completer<DetectionResult>? detectionCompleter;
  Completer<void>? warmUpCompleter;
  Completer<void>? shutdownCompleter;

  int warmUpCount = 0;
  int detectCount = 0;
  int classifyCount = 0;
  int cancelCount = 0;
  int shutdownCount = 0;

  void setState(AutoBoxState value, {Object? error}) {
    _currentState = value;
    lastError = error;
    notifyListeners();
  }

  @override
  Future<void> warmUp() async {
    warmUpCount++;
    await warmUpCompleter?.future;
    setState(AutoBoxState.ready);
  }

  @override
  Future<DetectionResult> detect(
    AnnotatedImage image, {
    String? imagePath,
    DetectionOptions options = const DetectionOptions(),
  }) async {
    detectCount++;
    if (_currentState == AutoBoxState.idle ||
        _currentState == AutoBoxState.failed) {
      await warmUp();
    }
    final error = detectionError;
    if (error != null) {
      lastError = error;
      setState(AutoBoxState.failed, error: error);
      throw error;
    }
    final completer = detectionCompleter;
    if (completer != null) {
      return completer.future;
    }
    return detectionResult;
  }

  @override
  Future<DetectionResult> classifyBoxes(
    AnnotatedImage image,
    List<BoundingBox> boxes,
  ) async {
    classifyCount++;
    return detectionResult;
  }

  @override
  Future<void> cancelActiveRequest() async {
    cancelCount++;
    setState(AutoBoxState.idle);
  }

  @override
  Future<void> shutdown() async {
    shutdownCount++;
    await shutdownCompleter?.future;
    setState(AutoBoxState.idle);
  }
}
