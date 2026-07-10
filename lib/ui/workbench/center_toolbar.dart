part of 'workbench_screen.dart';

class _CenterToolbarRail extends StatelessWidget {
  const _CenterToolbarRail({
    required this.controller,
    required this.tool,
    required this.effectiveTool,
    required this.editingLocked,
    required this.onSelectTool,
    required this.onDrawTool,
    required this.onPanTool,
    required this.onZoomOut,
    required this.onZoomFit,
    required this.onZoomIn,
    required this.onZoomActual,
  });

  final AppController controller;
  final CanvasTool tool;
  final CanvasTool effectiveTool;
  final bool editingLocked;
  final VoidCallback onSelectTool;
  final VoidCallback onDrawTool;
  final VoidCallback onPanTool;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomFit;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomActual;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final segments = _toolbarSegments();
        final rail = constraints.maxWidth < 720
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: _buildRailSurface(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: segments,
                  ),
                ),
              )
            : _buildRailSurface(
                child: Wrap(
                  spacing: 0,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: segments,
                ),
              );
        return SizedBox(
          key: const ValueKey('center-canvas-toolbar'),
          width: constraints.maxWidth,
          child: rail,
        );
      },
    );
  }

  List<Widget> _toolbarSegments() {
    return [
      _CanvasActionToolbar(
        controller: controller,
        tool: tool,
        effectiveTool: effectiveTool,
        editingLocked: editingLocked,
        onSelectTool: onSelectTool,
        onDrawTool: onDrawTool,
        onPanTool: onPanTool,
        onZoomOut: onZoomOut,
        onZoomFit: onZoomFit,
        onZoomIn: onZoomIn,
        onZoomActual: onZoomActual,
      ),
      const _ToolbarSeparator(key: ValueKey('center-toolbar-separator-1')),
      _CenterAutoBoxesToolbar(controller: controller),
    ];
  }

  Widget _buildRailSurface({required Widget child}) {
    return DecoratedBox(
      key: const ValueKey('center-toolbar-rail'),
      decoration: BoxDecoration(
        color: WorkbenchPalette.panelMuted,
        borderRadius: BorderRadius.circular(AppRadii.panel),
        border: Border.all(color: WorkbenchPalette.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: child,
      ),
    );
  }
}

class _CenterAutoBoxesToolbar extends StatelessWidget {
  const _CenterAutoBoxesToolbar({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final image = controller.selectedImage;
    final automationRunning = controller.isAutomationRunning;
    final boxCount = image?.visibleBoxes.length ?? 0;
    final autoBoxesLabel = switch (controller.autoBoxState) {
      AutoBoxState.idle ||
      AutoBoxState.starting => WorkbenchCopy.autoBoxesPreparingModel,
      AutoBoxState.ready => WorkbenchCopy.autoBoxes,
      AutoBoxState.running => WorkbenchCopy.autoBoxesRunning,
      AutoBoxState.restarting => WorkbenchCopy.autoBoxesRestartingModel,
      AutoBoxState.failed => WorkbenchCopy.autoBoxesRetry,
    };
    return KeyedSubtree(
      key: const ValueKey('center-auto-boxes-toolbar'),
      child: _ToolbarGroup(
        key: const ValueKey('center-automation-toolbar'),
        label: WorkbenchCopy.automationTools,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              key: const ValueKey('auto-boxes-current-image'),
              onPressed: controller.canRunAutoBoxes
                  ? () => controller.detectSelectedImage()
                  : null,
              icon: const Icon(Icons.auto_awesome_outlined),
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(autoBoxesLabel),
                  const SizedBox(width: 6),
                  const _ShortcutBadge(WorkbenchCopy.autoBoxesShortcut),
                ],
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              key: const ValueKey('clear-current-image-boxes'),
              onPressed: boxCount == 0 || automationRunning
                  ? null
                  : () => _confirmClearBoxes(context),
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text(WorkbenchCopy.clearBoxes),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClearBoxes(BuildContext context) async {
    final image = controller.selectedImage;
    final count = image?.visibleBoxes.length ?? 0;
    if (image == null || count == 0) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(WorkbenchCopy.clearBoxesTitle),
        content: Text(WorkbenchCopy.clearBoxesCountMessage(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(WorkbenchCopy.cancel),
          ),
          ElevatedButton(
            key: const ValueKey('confirm-clear-current-image-boxes'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(WorkbenchCopy.clearBoxesConfirm),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      controller.clearSelectedImageBoxes();
    }
  }
}

class _ToolbarGroup extends StatelessWidget {
  const _ToolbarGroup({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      container: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: Align(alignment: Alignment.centerLeft, child: child),
        ),
      ),
    );
  }
}

class _CanvasActionToolbar extends StatelessWidget {
  const _CanvasActionToolbar({
    required this.controller,
    required this.tool,
    required this.effectiveTool,
    required this.editingLocked,
    required this.onSelectTool,
    required this.onDrawTool,
    required this.onPanTool,
    required this.onZoomOut,
    required this.onZoomFit,
    required this.onZoomIn,
    required this.onZoomActual,
  });

  final AppController controller;
  final CanvasTool tool;
  final CanvasTool effectiveTool;
  final bool editingLocked;
  final VoidCallback onSelectTool;
  final VoidCallback onDrawTool;
  final VoidCallback onPanTool;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomFit;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomActual;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ToolbarGroup(
          key: const ValueKey('center-edit-toolbar'),
          label: WorkbenchCopy.editTools,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CanvasToolButton(
                buttonKey: const ValueKey('canvas-tool-select'),
                selected:
                    tool == CanvasTool.select &&
                    effectiveTool != CanvasTool.pan,
                tooltip: WorkbenchCopy.selectMoveTooltip,
                label: WorkbenchCopy.selectMoveTool,
                icon: Icons.near_me_outlined,
                onPressed: onSelectTool,
              ),
              const SizedBox(width: 6),
              _CanvasToolButton(
                buttonKey: const ValueKey('canvas-tool-draw-box'),
                selected:
                    tool == CanvasTool.drawBox &&
                    effectiveTool != CanvasTool.pan,
                tooltip: WorkbenchCopy.drawBoxTooltip,
                label: WorkbenchCopy.drawBoxTool,
                icon: Icons.crop_square,
                onPressed: editingLocked ? null : onDrawTool,
              ),
              const SizedBox(width: 6),
              _CanvasToolButton(
                buttonKey: const ValueKey('canvas-tool-pan'),
                selected: effectiveTool == CanvasTool.pan,
                tooltip: WorkbenchCopy.panTooltip,
                label: WorkbenchCopy.panTool,
                icon: Icons.pan_tool_alt_outlined,
                onPressed: onPanTool,
              ),
              const SizedBox(width: 6),
              OutlinedButton.icon(
                key: const ValueKey('delete-selected-box-toolbar'),
                onPressed: controller.selectedBoxId == null || editingLocked
                    ? null
                    : controller.deleteSelectedBox,
                icon: const Icon(Icons.delete_outline),
                label: const Text(WorkbenchCopy.deleteSelectedBox),
              ),
            ],
          ),
        ),
        const _ToolbarSeparator(key: ValueKey('center-toolbar-separator-2')),
        _ToolbarGroup(
          key: const ValueKey('center-view-toolbar'),
          label: WorkbenchCopy.viewTools,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: const ValueKey('zoom-out'),
                tooltip: WorkbenchCopy.zoomOut,
                onPressed: onZoomOut,
                icon: const Icon(Icons.zoom_out),
              ),
              IconButton(
                key: const ValueKey('zoom-fit'),
                tooltip: WorkbenchCopy.zoomFit,
                onPressed: onZoomFit,
                icon: const Icon(Icons.fit_screen),
              ),
              IconButton(
                key: const ValueKey('zoom-in'),
                tooltip: WorkbenchCopy.zoomIn,
                onPressed: onZoomIn,
                icon: const Icon(Icons.zoom_in),
              ),
              IconButton(
                key: const ValueKey('zoom-actual'),
                tooltip: '100%',
                onPressed: onZoomActual,
                icon: const Icon(Icons.browse_gallery_outlined),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
