part of 'workbench_screen.dart';

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
