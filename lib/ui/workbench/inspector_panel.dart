part of 'workbench_screen.dart';

enum _InspectorPanelTab { work, table }

class _InspectorPanel extends StatefulWidget {
  const _InspectorPanel({required this.controller, required this.project});

  final AppController controller;
  final AnnotationProject project;

  @override
  State<_InspectorPanel> createState() => _InspectorPanelState();
}

class _InspectorPanelState extends State<_InspectorPanel> {
  _InspectorPanelTab _selectedTab = _InspectorPanelTab.work;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final project = widget.project;
    final image = controller.selectedImage;
    final selectedBox = controller.selectedBox;
    final automationRunning = controller.isAutomationRunning;
    final boxDisplayNumbers = image == null
        ? const <String, int>{}
        : _boxDisplayNumbers(image);

    return _PanelSurface(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: image == null
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text(WorkbenchCopy.selectImageShort),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              image.displayName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _imageWorkSummary(image),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      TextButton.icon(
                        key: const ValueKey('remove-image-from-project'),
                        onPressed: automationRunning
                            ? null
                            : () => _removeImageFromProject(context, image.id),
                        icon: const Icon(Icons.remove_circle_outline),
                        label: const Text(WorkbenchCopy.removeImageFromProject),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _InspectorTabBar(
                    selectedTab: _selectedTab,
                    onTabSelected: (_InspectorPanelTab tab) {
                      setState(() {
                        _selectedTab = tab;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _selectedTab == _InspectorPanelTab.work
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (selectedBox != null) ...[
                                const _SectionTitle(WorkbenchCopy.details),
                                const SizedBox(height: 8),
                                _SelectedBoxDetails(
                                  project: project,
                                  box: selectedBox,
                                  displayNumber: _boxDisplayNumber(
                                    boxDisplayNumbers,
                                    selectedBox,
                                  ),
                                ),
                                const SizedBox(height: 12),
                              ],
                              Expanded(
                                child: SingleChildScrollView(
                                  key: const ValueKey('sidebar-box-scroll'),
                                  child: _SidebarBoxList(
                                    controller: controller,
                                    project: project,
                                    image: image,
                                  ),
                                ),
                              ),
                            ],
                          )
                        : _BoxTableView(
                            controller: controller,
                            project: project,
                            image: image,
                          ),
                  ),
                  const SizedBox(height: 10),
                  _InspectorCompletionFooter(
                    controller: controller,
                    image: image,
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _removeImageFromProject(
    BuildContext context,
    int imageId,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(WorkbenchCopy.removeImageTitle),
        content: const Text(WorkbenchCopy.removeImageMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(WorkbenchCopy.cancel),
          ),
          ElevatedButton(
            key: const ValueKey('confirm-remove-image-from-project'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(WorkbenchCopy.removeImageFromProject),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      widget.controller.removeImageFromProject(imageId);
    }
  }
}

class _InspectorTabBar extends StatelessWidget {
  const _InspectorTabBar({
    required this.selectedTab,
    required this.onTabSelected,
  });

  final _InspectorPanelTab selectedTab;
  final ValueChanged<_InspectorPanelTab> onTabSelected;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: WorkbenchPalette.panelMuted,
        borderRadius: BorderRadius.circular(AppRadii.row),
        border: Border.all(color: WorkbenchPalette.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            Expanded(
              child: _InspectorTabButton(
                label: WorkbenchCopy.inspectorWorkTab,
                selected: selectedTab == _InspectorPanelTab.work,
                onPressed: () => onTabSelected(_InspectorPanelTab.work),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: _InspectorTabButton(
                label: WorkbenchCopy.inspectorTableTab,
                selected: selectedTab == _InspectorPanelTab.table,
                onPressed: () => onTabSelected(_InspectorPanelTab.table),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InspectorTabButton extends StatelessWidget {
  const _InspectorTabButton({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        backgroundColor: selected
            ? colorScheme.primary.withAlpha(18)
            : Colors.transparent,
        foregroundColor: selected
            ? colorScheme.primary
            : colorScheme.onSurfaceVariant,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
        ),
      ),
      child: Text(label),
    );
  }
}

class _BoxTableView extends StatelessWidget {
  const _BoxTableView({
    required this.controller,
    required this.project,
    required this.image,
  });

  final AppController controller;
  final AnnotationProject project;
  final AnnotatedImage image;

  @override
  Widget build(BuildContext context) {
    final boxDisplayNumbers = _boxDisplayNumbers(image);
    final visibleBoxes = image.visibleBoxes.toList(growable: false)
      ..sort((a, b) {
        final numberComparison = _boxDisplayNumber(
          boxDisplayNumbers,
          a,
        ).compareTo(_boxDisplayNumber(boxDisplayNumbers, b));
        if (numberComparison != 0) {
          return numberComparison;
        }
        return a.id.compareTo(b.id);
      });
    if (visibleBoxes.isEmpty) {
      return const Center(child: Text(WorkbenchCopy.boxesNone));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const horizontalMargin = 4.0;
        const columnSpacing = 6.0;
        const numberColumnWidth = 24.0;
        const coordinateColumnWidth = 36.0;
        const columnGapCount = 5;
        final fixedWidth =
            (horizontalMargin * 2) +
            numberColumnWidth +
            (coordinateColumnWidth * 4) +
            (columnSpacing * columnGapCount);
        final classColumnWidth = math.max(
          56.0,
          constraints.maxWidth - fixedWidth,
        );
        final tableWidth = math.min(
          constraints.maxWidth,
          fixedWidth + classColumnWidth,
        );

        return SizedBox(
          key: const ValueKey('box-table-view'),
          width: tableWidth,
          child: SingleChildScrollView(
            child: DataTable(
              showCheckboxColumn: false,
              columnSpacing: columnSpacing,
              horizontalMargin: horizontalMargin,
              headingRowHeight: 28,
              dataRowMinHeight: 30,
              dataRowMaxHeight: 34,
              headingTextStyle: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(fontSize: 12, fontWeight: FontWeight.w800),
              dataTextStyle: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontSize: 12),
              columns: [
                const DataColumn(
                  label: SizedBox(
                    width: numberColumnWidth,
                    child: Text('No', textAlign: TextAlign.right),
                  ),
                  numeric: true,
                ),
                DataColumn(
                  label: SizedBox(
                    width: classColumnWidth,
                    child: const Text(
                      'Class',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const DataColumn(
                  label: SizedBox(
                    width: coordinateColumnWidth,
                    child: Text('X', textAlign: TextAlign.right),
                  ),
                  numeric: true,
                ),
                const DataColumn(
                  label: SizedBox(
                    width: coordinateColumnWidth,
                    child: Text('Y', textAlign: TextAlign.right),
                  ),
                  numeric: true,
                ),
                const DataColumn(
                  label: SizedBox(
                    width: coordinateColumnWidth,
                    child: Text('W', textAlign: TextAlign.right),
                  ),
                  numeric: true,
                ),
                const DataColumn(
                  label: SizedBox(
                    width: coordinateColumnWidth,
                    child: Text('H', textAlign: TextAlign.right),
                  ),
                  numeric: true,
                ),
              ],
              rows: [
                for (final box in visibleBoxes)
                  _BoxTableRow(
                    controller: controller,
                    project: project,
                    image: image,
                    box: box,
                    displayNumber: _boxDisplayNumber(boxDisplayNumbers, box),
                    numberColumnWidth: numberColumnWidth,
                    classColumnWidth: classColumnWidth,
                    coordinateColumnWidth: coordinateColumnWidth,
                  ).build(context),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BoxTableRow {
  const _BoxTableRow({
    required this.controller,
    required this.project,
    required this.image,
    required this.box,
    required this.displayNumber,
    required this.numberColumnWidth,
    required this.classColumnWidth,
    required this.coordinateColumnWidth,
  });

  final AppController controller;
  final AnnotationProject project;
  final AnnotatedImage image;
  final BoundingBox box;
  final int displayNumber;
  final double numberColumnWidth;
  final double classColumnWidth;
  final double coordinateColumnWidth;

  DataRow build(BuildContext context) {
    final label = _labelFor(project, box.displayLabelId);
    final invalid = _boxIsInvalid(image, box);
    final selected = controller.selectedBoxId == box.id;
    final colorScheme = Theme.of(context).colorScheme;

    return DataRow(
      key: ValueKey('box-table-row-${box.id}'),
      selected: selected,
      color: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return colorScheme.primary.withAlpha(18);
        }
        if (invalid) {
          return colorScheme.error.withAlpha(10);
        }
        return null;
      }),
      onSelectChanged: controller.isAutomationRunning
          ? null
          : (_) => controller.selectBox(box.id),
      cells: [
        DataCell(
          _BoxTableNumberCell('$displayNumber', width: numberColumnWidth),
        ),
        DataCell(
          SizedBox(
            width: classColumnWidth,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (invalid || box.requiresLabelReview) ...[
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: box.requiresLabelReview
                        ? WorkbenchPalette.danger
                        : colorScheme.error,
                  ),
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: Text(
                    label?.name ?? WorkbenchCopy.boxTableUnlabeled,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        DataCell(
          _BoxTableNumberCell(
            box.x.toStringAsFixed(0),
            width: coordinateColumnWidth,
          ),
        ),
        DataCell(
          _BoxTableNumberCell(
            box.y.toStringAsFixed(0),
            width: coordinateColumnWidth,
          ),
        ),
        DataCell(
          _BoxTableNumberCell(
            box.width.toStringAsFixed(0),
            width: coordinateColumnWidth,
          ),
        ),
        DataCell(
          _BoxTableNumberCell(
            box.height.toStringAsFixed(0),
            width: coordinateColumnWidth,
          ),
        ),
      ],
    );
  }
}

class _BoxTableNumberCell extends StatelessWidget {
  const _BoxTableNumberCell(this.value, {required this.width});

  final String value;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.clip,
        textAlign: TextAlign.right,
      ),
    );
  }
}

class _InspectorCompletionFooter extends StatelessWidget {
  const _InspectorCompletionFooter({
    required this.controller,
    required this.image,
  });

  final AppController controller;
  final AnnotatedImage image;

  @override
  Widget build(BuildContext context) {
    final blockerReason = controller.selectedImageCompletionBlockerReason;
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _workbenchBorder)),
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!controller.canConfirmSelectedImage &&
                blockerReason != null) ...[
              Text(
                blockerReason,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
            ],
            ElevatedButton.icon(
              key: const ValueKey('confirm-image'),
              onPressed:
                  !controller.isAutomationRunning &&
                      controller.canConfirmSelectedImage
                  ? controller.completeSelectedImageAndSelectNext
                  : null,
              icon: const Icon(Icons.check_circle_outline),
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      image.boxCount == 0
                          ? WorkbenchCopy.completeNoObjectAndNext
                          : WorkbenchCopy.completeAndNext,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const _ShortcutBadge(WorkbenchCopy.completeAndNextShortcut),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarBoxGroups {
  const _SidebarBoxGroups({
    required this.unlabeled,
    required this.labeled,
    required this.invalid,
  });

  final List<BoundingBox> unlabeled;
  final List<BoundingBox> labeled;
  final List<BoundingBox> invalid;
}

enum _SidebarBoxRowState { unlabeled, labeled, invalid }

class _SidebarBoxList extends StatelessWidget {
  const _SidebarBoxList({
    required this.controller,
    required this.project,
    required this.image,
  });

  final AppController controller;
  final AnnotationProject project;
  final AnnotatedImage image;

  @override
  Widget build(BuildContext context) {
    final groups = _sidebarBoxGroups(image);
    final boxDisplayNumbers = _boxDisplayNumbers(image);
    if (image.visibleBoxes.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (groups.unlabeled.isNotEmpty) ...[
          const _SectionTitle(
            WorkbenchCopy.unlabeledBox,
            key: ValueKey('box-group-unlabeled'),
          ),
          const SizedBox(height: 8),
          for (final box in groups.unlabeled)
            _BoxRow(
              key: ValueKey('box-row-${box.id}'),
              controller: controller,
              project: project,
              box: box,
              displayNumber: _boxDisplayNumber(boxDisplayNumbers, box),
              rowState: _SidebarBoxRowState.unlabeled,
            ),
        ],
        if (groups.labeled.isNotEmpty) ...[
          if (groups.unlabeled.isNotEmpty) const SizedBox(height: 14),
          const _SectionTitle(
            WorkbenchCopy.confirmed,
            key: ValueKey('box-group-labeled'),
          ),
          const SizedBox(height: 8),
          for (final box in groups.labeled)
            _BoxRow(
              key: ValueKey('box-row-${box.id}'),
              controller: controller,
              project: project,
              box: box,
              displayNumber: _boxDisplayNumber(boxDisplayNumbers, box),
              rowState: _SidebarBoxRowState.labeled,
            ),
        ],
        if (groups.invalid.isNotEmpty) ...[
          if (groups.unlabeled.isNotEmpty || groups.labeled.isNotEmpty)
            const SizedBox(height: 14),
          const _SectionTitle(
            WorkbenchCopy.error,
            key: ValueKey('box-group-invalid'),
          ),
          const SizedBox(height: 8),
          for (final box in groups.invalid)
            _BoxRow(
              key: ValueKey('box-row-${box.id}'),
              controller: controller,
              project: project,
              box: box,
              displayNumber: _boxDisplayNumber(boxDisplayNumbers, box),
              rowState: _SidebarBoxRowState.invalid,
            ),
        ],
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w800,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }
}

class _BoxRow extends StatelessWidget {
  const _BoxRow({
    super.key,
    required this.controller,
    required this.project,
    required this.box,
    required this.displayNumber,
    required this.rowState,
  });

  final AppController controller;
  final AnnotationProject project;
  final BoundingBox box;
  final int displayNumber;
  final _SidebarBoxRowState rowState;

  @override
  Widget build(BuildContext context) {
    final label = _labelFor(project, box.displayLabelId);
    final selected = controller.selectedBoxId == box.id;
    final color = box.requiresLabelReview
        ? WorkbenchPalette.danger
        : switch (rowState) {
            _SidebarBoxRowState.unlabeled => Theme.of(
              context,
            ).colorScheme.outline,
            _SidebarBoxRowState.labeled => Color(label?.color ?? 0xffd32f2f),
            _SidebarBoxRowState.invalid => Theme.of(context).colorScheme.error,
          };
    final title = box.requiresLabelReview
        ? '${label?.name ?? WorkbenchCopy.unlabeledBox} · '
              '${WorkbenchCopy.reviewRequired}'
        : switch (rowState) {
            _SidebarBoxRowState.unlabeled => WorkbenchCopy.unlabeledBox,
            _SidebarBoxRowState.labeled =>
              label?.name ?? WorkbenchCopy.unlabeledBox,
            _SidebarBoxRowState.invalid => WorkbenchCopy.error,
          };
    final displayTitle = WorkbenchCopy.boxDisplayTitle(displayNumber, title);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? Theme.of(context).colorScheme.primary.withAlpha(18)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadii.row),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadii.row),
          onTap: controller.isAutomationRunning
              ? null
              : () => controller.selectBox(box.id),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Container(
                  key: ValueKey('box-color-${box.id}'),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectedBoxDetails extends StatelessWidget {
  const _SelectedBoxDetails({
    required this.project,
    required this.box,
    required this.displayNumber,
  });

  final AnnotationProject project;
  final BoundingBox box;
  final int displayNumber;

  @override
  Widget build(BuildContext context) {
    final displayLabel = _labelFor(project, box.displayLabelId);
    final label = displayLabel?.name ?? WorkbenchCopy.unlabeledBox;
    return DecoratedBox(
      key: const ValueKey('selected-box-details'),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withAlpha(90),
        borderRadius: BorderRadius.circular(AppRadii.row),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: box.requiresLabelReview ? 126 : double.infinity,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        WorkbenchCopy.selectedBoxDisplayTitle(
                          displayNumber,
                          label,
                        ),
                        key: const ValueKey('selected-box-display-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _BoxAutomationStatus(box: box),
                  ],
                ),
                if (box.requiresLabelReview) ...[
                  const SizedBox(height: 8),
                  _ReviewEvidence(project: project, metadata: box.automation!),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  children: [
                    Text('x ${box.x.toStringAsFixed(0)}'),
                    Text('y ${box.y.toStringAsFixed(0)}'),
                    Text('w ${box.width.toStringAsFixed(0)}'),
                    Text('h ${box.height.toStringAsFixed(0)}'),
                    Text('area ${box.area.toStringAsFixed(0)}'),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BoxAutomationStatus extends StatelessWidget {
  const _BoxAutomationStatus({required this.box});

  final BoundingBox box;

  @override
  Widget build(BuildContext context) {
    final (icon, label, color) = box.requiresLabelReview
        ? (
            Icons.warning_amber_rounded,
            WorkbenchCopy.reviewRequired,
            WorkbenchPalette.danger,
          )
        : box.isAutoLabeled
        ? (
            Icons.auto_awesome_outlined,
            WorkbenchCopy.automaticLabel,
            WorkbenchPalette.mutedForeground,
          )
        : box.status == BoxStatus.labeled && box.labelId != null
        ? (
            Icons.label_outline,
            WorkbenchCopy.assignedLabel,
            WorkbenchPalette.mutedForeground,
          )
        : (
            Icons.help_outline,
            WorkbenchCopy.unclassified,
            WorkbenchPalette.mutedForeground,
          );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 5),
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _ReviewEvidence extends StatelessWidget {
  const _ReviewEvidence({required this.project, required this.metadata});

  final AnnotationProject project;
  final BoxAutomationMetadata metadata;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: WorkbenchPalette.dangerSoft.withAlpha(110),
        borderRadius: BorderRadius.circular(AppRadii.badge),
        border: Border.all(color: WorkbenchPalette.danger.withAlpha(70)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final reason in metadata.reviewReasons)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  WorkbenchCopy.reviewReasonLabel(reason),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (metadata.candidates.isNotEmpty) ...[
              const SizedBox(height: 3),
              for (final candidate in metadata.candidates.take(3))
                _CandidateScoreRow(project: project, candidate: candidate),
            ],
          ],
        ),
      ),
    );
  }
}

class _CandidateScoreRow extends StatelessWidget {
  const _CandidateScoreRow({required this.project, required this.candidate});

  final AnnotationProject project;
  final LabelCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final label = _labelFor(project, candidate.labelId);
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: label == null
                  ? WorkbenchPalette.mutedForeground
                  : Color(label.color),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label?.name ?? '#${candidate.labelId}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Text(
            '${(candidate.score * 100).round()}%',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}
