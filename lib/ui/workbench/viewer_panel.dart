part of 'workbench_screen.dart';

class _ViewerPanel extends StatefulWidget {
  const _ViewerPanel({
    required this.controller,
    required this.project,
    required this.onChooseImageFolder,
    required this.onChooseImageFiles,
  });

  final AppController controller;
  final AnnotationProject project;
  final Future<void> Function() onChooseImageFolder;
  final Future<void> Function() onChooseImageFiles;

  @override
  State<_ViewerPanel> createState() => _ViewerPanelState();
}

class _ViewerPanelState extends State<_ViewerPanel> {
  final FocusNode _focusNode = FocusNode();
  CanvasTool _tool = CanvasTool.select;
  bool _spacePressed = false;
  bool _showActualSize = false;
  double _zoom = 1.0;
  Offset _panOffset = Offset.zero;

  CanvasTool get _effectiveTool => _spacePressed ? CanvasTool.pan : _tool;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final project = widget.project;
    final image = controller.selectedImage;

    return Focus(
      key: const ValueKey('workbench-canvas-focus'),
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleCanvasKey,
      child: _PanelSurface(
        child: DecoratedBox(
          key: const ValueKey('annotation-canvas-panel'),
          decoration: const BoxDecoration(color: _workbenchPanel),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: image == null
                ? _buildEmptyState(project)
                : _buildSelectedImage(context, image),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(AnnotationProject project) {
    if (project.images.isEmpty) {
      return Center(
        child: _ImageImportMenuButton(
          buttonKey: const ValueKey('empty-workbench-import-images'),
          enabled:
              !widget.controller.isAutomationRunning &&
              widget.controller.projectActivity != ProjectActivity.importing,
          label: WorkbenchCopy.importImages,
          onAddFiles: widget.onChooseImageFiles,
          onAddFolder: widget.onChooseImageFolder,
        ),
      );
    }
    return const Center(child: Text(WorkbenchCopy.noImageSelected));
  }

  Widget _buildSelectedImage(BuildContext context, AnnotatedImage image) {
    final controller = widget.controller;
    final colorScheme = Theme.of(context).colorScheme;

    if (controller.selectedSourceAvailability == SourceAvailability.missing) {
      return _MissingSelectedSource(sourcePath: image.sourcePath);
    }

    if (controller.imageViewLoadState.isLoading &&
        controller.imageViewLoadState.imageId == image.id) {
      return const Center(
        key: ValueKey('viewer-loading-state'),
        child: Text(WorkbenchCopy.loadingImage),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (image.errorMessage != null) ...[
          Text(
            image.errorMessage!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.error,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        const SizedBox(height: 12),
        _CenterToolbarRail(
          controller: controller,
          tool: _tool,
          effectiveTool: _effectiveTool,
          editingLocked: controller.isAutomationRunning,
          onSelectTool: () => _setTool(CanvasTool.select),
          onDrawTool: () => _setTool(CanvasTool.drawBox),
          onPanTool: () => _setTool(CanvasTool.pan),
          onZoomOut: () => _setZoom(_zoom * 0.8),
          onZoomFit: () => _setZoom(1.0, showActualSize: false),
          onZoomIn: () => _setZoom(_zoom * 1.25),
          onZoomActual: () => _setZoom(1.0, showActualSize: true),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _ImageCanvas(
            controller: controller,
            project: widget.project,
            image: image,
            zoom: _zoom,
            showActualSize: _showActualSize,
            panOffset: _panOffset,
            tool: _effectiveTool,
            editingLocked: controller.isAutomationRunning,
            onPanOffsetChanged: _setPanOffset,
            onViewportChanged: _setViewport,
            onDrawingComplete: () {},
          ),
        ),
      ],
    );
  }

  KeyEventResult _handleCanvasKey(FocusNode node, KeyEvent event) {
    if (_textInputHasFocus()) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent && !_spacePressed) {
        setState(() => _spacePressed = true);
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent && _spacePressed) {
        setState(() => _spacePressed = false);
        return KeyEventResult.handled;
      }
    }

    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    if (widget.controller.isAutomationRunning) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyB &&
        !_keyboardModifierPressed()) {
      _setTool(CanvasTool.drawBox);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.controller.selectBox(null);
      _setTool(CanvasTool.select);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _setTool(CanvasTool tool) {
    if (!mounted) {
      return;
    }
    setState(() => _tool = tool);
  }

  void _setZoom(double value, {bool? showActualSize}) {
    if (!mounted) {
      return;
    }
    setState(() {
      _zoom = value.clamp(0.1, 8.0);
      if (showActualSize != null) {
        _showActualSize = showActualSize;
        _panOffset = Offset.zero;
      }
    });
  }

  void _setPanOffset(Offset value) {
    if (!mounted) {
      return;
    }
    setState(() => _panOffset = value);
  }

  void _setViewport({
    required double zoom,
    required bool showActualSize,
    required Offset panOffset,
  }) {
    if (!mounted) {
      return;
    }
    setState(() {
      _zoom = zoom.clamp(0.1, 8.0);
      _showActualSize = showActualSize;
      _panOffset = panOffset;
    });
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

class _MissingSelectedSource extends StatelessWidget {
  const _MissingSelectedSource({required this.sourcePath});

  final String sourcePath;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      key: const ValueKey('missing-selected-source'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Semantics(
          container: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.image_not_supported_outlined,
                size: 36,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              SelectableText(
                sourcePath,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                WorkbenchCopy.labelingDataPreserved,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
