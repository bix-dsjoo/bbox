part of 'workbench_screen.dart';

class _QuickLabelBar extends StatefulWidget {
  const _QuickLabelBar({required this.controller, required this.project});

  final AppController controller;
  final AnnotationProject project;

  @override
  State<_QuickLabelBar> createState() => _QuickLabelBarState();
}

class _QuickLabelBarState extends State<_QuickLabelBar> {
  static const _popoverMargin = 12.0;
  static const _popoverMaxWidth = 380.0;

  final LayerLink _labelManagementLink = LayerLink();
  final GlobalKey _labelManagementTargetKey = GlobalKey();
  OverlayEntry? _labelManagementEntry;

  @override
  void dispose() {
    _removePopover();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final automationRunning = widget.controller.isAutomationRunning;
    final quickLabels = [
      for (final label in widget.project.labels)
        if (label.shortcut != null) label,
    ];
    if (quickLabels.isEmpty) {
      final message = widget.project.labels.isEmpty
          ? WorkbenchCopy.addLabelsEmpty
          : WorkbenchCopy.noLabelShortcuts;
      return SizedBox(
        key: const ValueKey('quick-label-empty-state'),
        height: 48,
        child: Row(
          children: [
            Text(message),
            const SizedBox(width: 8),
            _buildManageLabelsButton(),
          ],
        ),
      );
    }

    final firstRow = quickLabels.take(10).toList(growable: false);
    final secondRow = quickLabels.skip(10).toList(growable: false);

    return SizedBox(
      height: secondRow.isEmpty ? 48 : 88,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Align(
                alignment: Alignment.center,
                child: Column(
                  key: const ValueKey('quick-label-content'),
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final label in firstRow)
                          _QuickLabelChip(
                            label: label,
                            shortcut: label.shortcut!,
                            selected:
                                widget.controller.selectedBox?.labelId ==
                                label.id,
                            enabled:
                                widget.controller.selectedBoxId != null &&
                                !automationRunning,
                            onTap: () => widget.controller
                                .assignSelectedBoxLabel(label.id),
                          ),
                        if (secondRow.isEmpty) _buildManageLabelsButton(),
                      ],
                    ),
                    if (secondRow.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final label in secondRow)
                            _QuickLabelChip(
                              label: label,
                              shortcut: label.shortcut!,
                              selected:
                                  widget.controller.selectedBox?.labelId ==
                                  label.id,
                              enabled:
                                  widget.controller.selectedBoxId != null &&
                                  !automationRunning,
                              onTap: () => widget.controller
                                  .assignSelectedBoxLabel(label.id),
                            ),
                          _buildManageLabelsButton(),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildManageLabelsButton() {
    return CompositedTransformTarget(
      key: _labelManagementTargetKey,
      link: _labelManagementLink,
      child: IconButton(
        key: const ValueKey('open-label-management'),
        tooltip: WorkbenchCopy.manageLabels,
        onPressed: widget.controller.isAutomationRunning
            ? null
            : _showPopoverForLabels,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 34, height: 34),
        iconSize: 18,
        icon: const Icon(Icons.add),
      ),
    );
  }

  void _showPopoverForLabels() {
    if (_labelManagementEntry != null) {
      _removePopover();
      return;
    }
    final overlay = Overlay.of(context);
    _labelManagementEntry = OverlayEntry(
      builder: (context) => LayoutBuilder(
        builder: (context, constraints) {
          final overlayBox = context.findRenderObject()! as RenderBox;
          final targetBox =
              _labelManagementTargetKey.currentContext!.findRenderObject()!
                  as RenderBox;
          final targetLeft = targetBox
              .localToGlobal(Offset.zero, ancestor: overlayBox)
              .dx;
          final popoverWidth = math.min(
            _popoverMaxWidth,
            constraints.maxWidth - (_popoverMargin * 2),
          );
          final popoverLeft = targetLeft.clamp(
            _popoverMargin,
            constraints.maxWidth - _popoverMargin - popoverWidth,
          );
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _removePopover,
                ),
              ),
              CompositedTransformFollower(
                link: _labelManagementLink,
                showWhenUnlinked: false,
                targetAnchor: Alignment.topLeft,
                followerAnchor: Alignment.bottomLeft,
                offset: Offset(popoverLeft - targetLeft, -8),
                child: SizedBox(
                  width: popoverWidth,
                  child: LabelManagementPopover(
                    labels: widget.project.labels,
                    onCreateLabel: (name, color, shortcut) {
                      widget.controller.addLabel(
                        name,
                        color,
                        shortcut: shortcut,
                      );
                      _removePopover();
                    },
                    onUpdateLabel: (id, name, color, shortcut) {
                      widget.controller.updateLabel(
                        labelId: id,
                        name: name,
                        color: color,
                        shortcut: shortcut,
                      );
                      _removePopover();
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
    overlay.insert(_labelManagementEntry!);
  }

  void _removePopover() {
    _labelManagementEntry?.remove();
    _labelManagementEntry = null;
  }
}

class _QuickLabelChip extends StatelessWidget {
  const _QuickLabelChip({
    required this.label,
    required this.shortcut,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final LabelClass label;
  final String shortcut;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Color(label.color);
    final foreground = enabled
        ? Theme.of(context).colorScheme.onSurface
        : Theme.of(context).disabledColor;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: '$shortcut ${label.name}',
        child: InkWell(
          key: ValueKey('quick-label-$shortcut'),
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(AppRadii.button),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 104),
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 7),
              decoration: BoxDecoration(
                color: selected
                    ? WorkbenchPalette.accentSoft
                    : Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(AppRadii.button),
                border: Border.all(
                  color: selected
                      ? WorkbenchPalette.accentBorder
                      : Theme.of(context).dividerColor,
                  width: selected ? 2 : 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: enabled ? color.withAlpha(28) : Colors.transparent,
                      borderRadius: BorderRadius.circular(AppRadii.badge),
                      border: Border.all(
                        color: enabled ? color.withAlpha(90) : foreground,
                      ),
                    ),
                    child: Text(
                      shortcut,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: enabled ? color : foreground,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: enabled ? color : foreground.withAlpha(90),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label.name,
                    maxLines: 1,
                    softWrap: false,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: foreground,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
