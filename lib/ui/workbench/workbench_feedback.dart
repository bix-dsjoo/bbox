part of 'workbench_screen.dart';

class _MissingSourceBanner extends StatelessWidget {
  const _MissingSourceBanner({
    required this.count,
    required this.busy,
    required this.onRelinkFiles,
    required this.onRelinkFolder,
  });

  final int count;
  final bool busy;
  final VoidCallback onRelinkFiles;
  final VoidCallback onRelinkFolder;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: const ValueKey('missing-source-banner'),
        width: double.infinity,
        decoration: BoxDecoration(
          color: colorScheme.errorContainer,
          border: Border(
            bottom: BorderSide(color: colorScheme.error.withValues(alpha: 0.4)),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(
              Icons.link_off_outlined,
              size: 20,
              color: colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    WorkbenchCopy.missingSourceCount(count),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    WorkbenchCopy.labelingDataPreserved,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onErrorContainer,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Tooltip(
              message: WorkbenchCopy.relinkFiles,
              child: OutlinedButton.icon(
                key: const ValueKey('relink-source-files'),
                onPressed: busy ? null : onRelinkFiles,
                icon: const Icon(Icons.insert_drive_file_outlined, size: 18),
                label: const Text(WorkbenchCopy.relinkFiles),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: WorkbenchCopy.relinkFolder,
              child: OutlinedButton.icon(
                key: const ValueKey('relink-source-folder'),
                onPressed: busy ? null : onRelinkFolder,
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                label: const Text(WorkbenchCopy.relinkFolder),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkbenchActivityBar extends StatelessWidget {
  const _WorkbenchActivityBar({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final importRunning =
        controller.projectActivity == ProjectActivity.importing;
    final progress = controller.imageImportProgress;
    final progressValue = progress == null || progress.total <= 0
        ? null
        : progress.processed / progress.total;
    final text = _activityText(importRunning, progress);
    final busy = importRunning || controller.isAutomationRunning;
    final showProgress = importRunning;

    return SizedBox(
      key: const ValueKey('workbench-activity-bar'),
      height: 44,
      width: double.infinity,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: _workbenchPanel,
          border: Border(top: BorderSide(color: _workbenchBorder)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              _ActivityLeadingIcon(busy: busy),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              if (controller.isAutomationRunning) ...[
                const SizedBox(width: 12),
                TextButton.icon(
                  key: const ValueKey('cancel-auto-boxes'),
                  onPressed: () => unawaited(controller.cancelAutoBoxes()),
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text(WorkbenchCopy.cancelAutoBoxes),
                ),
              ],
              if (showProgress) ...[
                const SizedBox(width: 12),
                SizedBox(
                  width: 140,
                  child: LinearProgressIndicator(value: progressValue),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _activityText(bool importRunning, ImageImportProgress? progress) {
    if (importRunning) {
      return progress == null || progress.total <= 0
          ? WorkbenchCopy.importScanning
          : _importProgressText(progress);
    }
    return controller.lastUserMessage ?? WorkbenchCopy.activityReady;
  }
}

class _ActivityLeadingIcon extends StatelessWidget {
  const _ActivityLeadingIcon({required this.busy});

  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return Icon(
      Icons.check_circle_outline,
      size: 18,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }
}

void _showRelinkSummary(BuildContext context, SourceRelinkResult result) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        WorkbenchCopy.relinkSummary(
          matched: result.matchedCount,
          unresolved: result.unresolvedImageIds.length,
          ambiguous: result.ambiguousImageIds.length,
        ),
      ),
    ),
  );
}

String _importProgressText(ImageImportProgress progress) {
  final parts = [
    '이미지 불러오는 중 ${progress.processed} / ${progress.total}',
    '추가 ${progress.added}개',
    '건너뜀 ${progress.skipped}개',
  ];
  if (progress.errors > 0) {
    parts.add('오류 ${progress.errors}개');
  }
  return parts.join(' · ');
}
