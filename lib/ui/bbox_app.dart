import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'app_controller.dart';
import 'app_theme.dart';
import 'project_home_copy.dart';
import 'start_screen.dart';
import 'workbench_screen.dart';

class BboxApp extends StatefulWidget {
  const BboxApp({super.key, this.controller});

  final AppController? controller;

  @override
  State<BboxApp> createState() => _BboxAppState();
}

class _BboxAppState extends State<BboxApp> with WidgetsBindingObserver {
  late final AppController _controller;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? AppController();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_warmUpAutoBoxes());
  }

  Future<void> _warmUpAutoBoxes() async {
    try {
      await _controller.warmUpAutoBoxes();
    } catch (_) {
      // The runtime records the failure and exposes its retryable failed state.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(_controller.shutdownAutoBoxes());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: ProjectHomeCopy.appTitle,
      theme: BboxAppTheme.materialTheme,
      builder: (context, child) => FTheme(
        data: BboxAppTheme.foruiTheme,
        child: FToaster(child: FTooltipGroup(child: child!)),
      ),
      home: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          if (!_controller.hasProject) {
            return StartScreen(controller: _controller);
          }
          return WorkbenchScreen(controller: _controller);
        },
      ),
    );
  }
}
