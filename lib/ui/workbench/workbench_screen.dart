import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../annotation/annotation_rules.dart';
import '../../annotation/models.dart';
import '../../detector/auto_box_service.dart';
import '../../viewer/viewport_transform.dart';
import '../app_controller.dart';
import '../app_theme.dart';
import '../canvas_interaction.dart';
import '../coco_export_destination_picker.dart';
import '../coco_export_warning_dialog.dart';
import '../image_import_picker.dart';
import '../label_management_popover.dart';
import '../workbench_copy.dart';

part 'workbench_shared.dart';
part 'image_queue_panel.dart';
part 'viewer_panel.dart';
part 'center_toolbar.dart';
part 'image_canvas.dart';
part 'inspector_panel.dart';
part 'quick_label_bar.dart';
part 'workbench_feedback.dart';
part 'workbench_helpers.dart';

const _workbenchBackground = WorkbenchPalette.appBackground;
const _workbenchPanel = WorkbenchPalette.panel;
const _workbenchBorder = WorkbenchPalette.border;
const _automaticBoxColor = Color(0xff5f6772);
const _automaticBoxFillAlpha = 46;
const _automaticBoxSelectedFillAlpha = 58;
const _selectedBoxAlphaLabeled = 52;
const _resizeHandleHitSize = 20.0;
const _resizeHandleVisualSize = 11.0;
const _resizeHandleRadius = 2.0;
const _desktopImageQueueWidth = 320.0;
const _desktopInspectorWidth = 400.0;
const _compactImageQueueWidth = 260.0;
const _compactInspectorWidth = 340.0;
const _compactWorkbenchBreakpoint = 960.0;

const _quickLabelShortcutLabels = <String>[
  '1',
  '2',
  '3',
  '4',
  '5',
  '6',
  '7',
  '8',
  '9',
  '0',
  'q',
  'w',
  'e',
  'r',
  't',
  'y',
  'u',
  'i',
  'o',
  'p',
];

const _quickLabelShortcutKeys = <LogicalKeyboardKey>[
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
  LogicalKeyboardKey.digit0,
  LogicalKeyboardKey.keyQ,
  LogicalKeyboardKey.keyW,
  LogicalKeyboardKey.keyE,
  LogicalKeyboardKey.keyR,
  LogicalKeyboardKey.keyT,
  LogicalKeyboardKey.keyY,
  LogicalKeyboardKey.keyU,
  LogicalKeyboardKey.keyI,
  LogicalKeyboardKey.keyO,
  LogicalKeyboardKey.keyP,
];

class WorkbenchScreen extends StatelessWidget {
  const WorkbenchScreen({
    super.key,
    required this.controller,
    this.imageImportPicker = const WindowsImageImportPicker(),
    this.exportDestinationPicker = const WindowsCocoExportDestinationPicker(),
    this.exportWriter,
  });

  final AppController controller;
  final ImageImportPicker imageImportPicker;
  final CocoExportDestinationPicker exportDestinationPicker;
  final Future<void> Function(String path)? exportWriter;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final project = controller.project;
        if (project == null) {
          return const Scaffold(
            backgroundColor: _workbenchBackground,
            body: Center(child: Text('프로젝트를 먼저 열거나 만드세요')),
          );
        }

        final automationRunning = controller.isAutomationRunning;
        final importRunning =
            controller.projectActivity == ProjectActivity.importing;
        final busyForProjectMutation = automationRunning || importRunning;

        return Scaffold(
          backgroundColor: _workbenchBackground,
          appBar: AppBar(
            key: const ValueKey('workbench-top-bar'),
            backgroundColor: _workbenchPanel,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            leadingWidth: 156,
            leading: KeyedSubtree(
              key: const ValueKey('top-context-group'),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Tooltip(
                  message: WorkbenchCopy.projectHomeTooltip,
                  child: TextButton.icon(
                    key: const ValueKey('project-home-action'),
                    onPressed: () => _returnToProjectHome(context),
                    icon: const Icon(Icons.home_outlined),
                    label: const Text(WorkbenchCopy.projectHome),
                  ),
                ),
              ),
            ),
            titleSpacing: 0,
            title: Text(
              project.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              KeyedSubtree(
                key: const ValueKey('workbench-forui-toolbar'),
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: DecoratedBox(
                    key: const ValueKey('top-action-rail'),
                    decoration: BoxDecoration(
                      color: WorkbenchPalette.panelMuted,
                      borderRadius: BorderRadius.circular(AppRadii.panel),
                      border: Border.all(color: WorkbenchPalette.border),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            key: const ValueKey('top-status-group'),
                            height: 36,
                            child: Center(
                              child: _SaveStatusIndicator(
                                status: controller.saveStatus,
                              ),
                            ),
                          ),
                          const _ToolbarSeparator(
                            key: ValueKey('top-toolbar-separator-1'),
                          ),
                          SizedBox(
                            key: const ValueKey('top-document-actions'),
                            height: 36,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (project.images.isNotEmpty)
                                  _ImageImportMenuButton(
                                    buttonKey: const ValueKey(
                                      'choose-image-add',
                                    ),
                                    enabled: !busyForProjectMutation,
                                    label: WorkbenchCopy.imageAdd,
                                    onAddFiles: () => _addImageFiles(context),
                                    onAddFolder: () => _addImageFolder(context),
                                  ),
                                KeyedSubtree(
                                  key: const ValueKey('export-coco-forui'),
                                  child: TextButton.icon(
                                    key: const ValueKey('export-coco'),
                                    onPressed: busyForProjectMutation
                                        ? null
                                        : () => _showExportWarnings(context),
                                    icon: const Icon(Icons.ios_share),
                                    label: const Text(WorkbenchCopy.cocoExport),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const _ToolbarSeparator(
                            key: ValueKey('top-toolbar-separator-2'),
                          ),
                          SizedBox(
                            key: const ValueKey('top-edit-actions'),
                            height: 36,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  key: const ValueKey('save-project'),
                                  tooltip: WorkbenchCopy.saveProjectTooltip,
                                  onPressed: () => _saveProject(context),
                                  icon: const Icon(Icons.save_outlined),
                                ),
                                IconButton(
                                  tooltip: WorkbenchCopy.undo,
                                  onPressed:
                                      !busyForProjectMutation &&
                                          controller.canUndo
                                      ? controller.undo
                                      : null,
                                  icon: const Icon(Icons.undo),
                                ),
                                IconButton(
                                  tooltip: WorkbenchCopy.redo,
                                  onPressed:
                                      !busyForProjectMutation &&
                                          controller.canRedo
                                      ? controller.redo
                                      : null,
                                  icon: const Icon(Icons.redo),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          body: DecoratedBox(
            key: const ValueKey('workbench-shell'),
            decoration: const BoxDecoration(color: _workbenchBackground),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(
                  LogicalKeyboardKey.delete,
                ): busyForProjectMutation
                    ? () {}
                    : controller.deleteSelectedBox,
                const SingleActivator(
                  LogicalKeyboardKey.backspace,
                ): busyForProjectMutation
                    ? () {}
                    : controller.deleteSelectedBox,
                const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
                    busyForProjectMutation ? () {} : controller.undo,
                const SingleActivator(LogicalKeyboardKey.keyY, control: true):
                    busyForProjectMutation ? () {} : controller.redo,
                const SingleActivator(
                  LogicalKeyboardKey.enter,
                  control: true,
                ): busyForProjectMutation
                    ? () {}
                    : _handleCompleteAndNextShortcut,
                const SingleActivator(LogicalKeyboardKey.keyB, control: true):
                    busyForProjectMutation ? () {} : _handleAutoBoxesShortcut,
              },
              child: Focus(
                autofocus: true,
                onKeyEvent: (node, event) =>
                    _handleWorkbenchKey(event, project),
                child: Column(
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final compactLayout =
                              constraints.maxWidth <
                              _compactWorkbenchBreakpoint;
                          final leftWidth = compactLayout
                              ? _compactImageQueueWidth
                              : _desktopImageQueueWidth;
                          final rightWidth = compactLayout
                              ? _compactInspectorWidth
                              : _desktopInspectorWidth;
                          return Row(
                            children: [
                              SizedBox(
                                key: const ValueKey('image-queue-panel'),
                                width: leftWidth,
                                child: _ImageListPanel(
                                  controller: controller,
                                  project: project,
                                ),
                              ),
                              const VerticalDivider(width: 1),
                              Expanded(
                                child: _ViewerPanel(
                                  controller: controller,
                                  project: project,
                                  onChooseImageFolder: () =>
                                      _addImageFolder(context),
                                  onChooseImageFiles: () =>
                                      _addImageFiles(context),
                                ),
                              ),
                              const VerticalDivider(width: 1),
                              SizedBox(
                                key: const ValueKey('inspector-panel'),
                                width: rightWidth,
                                child: _InspectorPanel(
                                  controller: controller,
                                  project: project,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    _WorkbenchActivityBar(controller: controller),
                    Container(
                      key: const ValueKey('global-quick-label-bar'),
                      decoration: const BoxDecoration(
                        color: _workbenchPanel,
                        border: Border(
                          top: BorderSide(color: _workbenchBorder),
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: _QuickLabelBar(
                        controller: controller,
                        project: project,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _addImageFolder(BuildContext context) async {
    try {
      final folderPath = await imageImportPicker.pickImageFolder();
      if (folderPath == null) {
        return;
      }
      await controller.addImagesFromFolder(folderPath);
    } catch (error) {
      if (context.mounted) {
        _showError(context, '이미지 폴더를 가져오지 못했습니다. $error');
      }
    }
  }

  Future<void> _addImageFiles(BuildContext context) async {
    try {
      final paths = await imageImportPicker.pickImageFiles();
      if (paths.isEmpty) {
        return;
      }
      await controller.addImageFiles(paths);
    } catch (error) {
      if (context.mounted) {
        _showError(context, '이미지 파일을 가져오지 못했습니다. $error');
      }
    }
  }

  Future<void> _saveProject(BuildContext context) async {
    try {
      await controller.saveProject();
    } catch (error) {
      if (context.mounted) {
        _showError(context, '프로젝트를 저장하지 못했습니다. $error');
      }
    }
  }

  Future<void> _returnToProjectHome(BuildContext context) async {
    try {
      await controller.returnToProjectHome();
    } catch (error) {
      if (context.mounted) {
        _showError(context, '프로젝트 홈으로 돌아가지 못했습니다. $error');
      }
    }
  }

  Future<void> _showExportWarnings(BuildContext context) async {
    final summary = controller.exportSummary();
    final savedPath = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => CocoExportWarningDialog(
        summary: summary,
        pickDestination: exportDestinationPicker.pickDestination,
        writeExport: exportWriter ?? controller.exportCocoFile,
        onClose: () => Navigator.of(dialogContext).pop(),
        onSuccess: (path) => Navigator.of(dialogContext).pop(path),
      ),
    );
    if (savedPath != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'COCO JSON을 저장했습니다: $savedPath',
            key: const ValueKey('coco-export-success'),
          ),
        ),
      );
    }
  }

  void _showError(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _handleCompleteAndNextShortcut() {
    if (controller.isAutomationRunning) {
      return;
    }
    if (_textInputHasFocus()) {
      return;
    }
    if (controller.canConfirmSelectedImage) {
      controller.completeSelectedImageAndSelectNext();
    }
  }

  void _handleAutoBoxesShortcut() {
    if (!controller.canRunAutoBoxes) {
      return;
    }
    if (_textInputHasFocus()) {
      return;
    }
    unawaited(controller.detectSelectedImage());
  }

  KeyEventResult _handleWorkbenchKey(
    KeyEvent event,
    AnnotationProject project,
  ) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (controller.isAutomationRunning) {
      return KeyEventResult.ignored;
    }
    if (_textInputHasFocus()) {
      return KeyEventResult.ignored;
    }
    if (_keyboardModifierPressed()) {
      return KeyEventResult.ignored;
    }
    final shortcut = _shortcutForKey(event.logicalKey);
    if (shortcut == null || controller.selectedBoxId == null) {
      return KeyEventResult.ignored;
    }
    final label = _labelForShortcut(project, shortcut);
    if (label == null) {
      return KeyEventResult.ignored;
    }
    controller.assignSelectedBoxLabel(label.id);
    return KeyEventResult.handled;
  }

  bool _textInputHasFocus() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) {
      return false;
    }
    return focusContext.widget is EditableText ||
        focusContext.findAncestorWidgetOfExactType<EditableText>() != null ||
        focusContext.findAncestorWidgetOfExactType<TextField>() != null ||
        focusContext.findAncestorWidgetOfExactType<TextFormField>() != null;
  }
}
