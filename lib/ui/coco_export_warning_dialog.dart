import 'package:flutter/material.dart';

import '../export/coco_exporter.dart';
import 'workbench_copy.dart';

class CocoExportWarningDialog extends StatefulWidget {
  const CocoExportWarningDialog({
    super.key,
    required this.summary,
    required this.pickDestination,
    required this.writeExport,
    required this.onClose,
    required this.onSuccess,
  });

  final CocoExportSummary summary;
  final Future<String?> Function() pickDestination;
  final Future<void> Function(String path) writeExport;
  final VoidCallback onClose;
  final ValueChanged<String> onSuccess;

  @override
  State<CocoExportWarningDialog> createState() =>
      _CocoExportWarningDialogState();
}

class _CocoExportWarningDialogState extends State<CocoExportWarningDialog> {
  bool _inFlight = false;
  String? _attemptError;

  @override
  Widget build(BuildContext context) {
    final hasErrors = widget.summary.hasBlockingErrors;
    return PopScope(
      canPop: !_inFlight,
      child: AlertDialog(
        title: Text(hasErrors ? 'COCO 내보내기 차단' : 'COCO 내보내기 경고'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('검토 필요 이미지: ${widget.summary.unconfirmedImageCount}'),
            Text(
              '라벨 필요한 자동 박스: '
              '${widget.summary.unlabeledProposalBoxCount}',
            ),
            Text('문제 있는 이미지: ${widget.summary.errorImageCount}'),
            for (final error in widget.summary.blockingErrors)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error, style: const TextStyle(color: Colors.red)),
              ),
            if (_attemptError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _attemptError!,
                  key: const ValueKey('export-attempt-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _inFlight ? null : widget.onClose,
            child: const Text(WorkbenchCopy.close),
          ),
          ElevatedButton(
            key: const ValueKey('continue-coco-export'),
            onPressed: hasErrors || _inFlight ? null : _attemptExport,
            child: const Text(WorkbenchCopy.continueAction),
          ),
        ],
      ),
    );
  }

  Future<void> _attemptExport() async {
    if (_inFlight) {
      return;
    }
    setState(() {
      _inFlight = true;
      _attemptError = null;
    });
    String? successfulPath;
    try {
      String? path;
      try {
        path = await widget.pickDestination();
      } catch (_) {
        _attemptError = '저장 위치를 선택하지 못했습니다. 다시 시도하세요.';
        return;
      }
      if (path == null) {
        return;
      }
      try {
        await widget.writeExport(path);
      } catch (_) {
        _attemptError = 'COCO 파일을 저장하지 못했습니다. 경로와 쓰기 권한을 확인한 뒤 다시 시도하세요.';
        return;
      }
      successfulPath = path;
    } finally {
      if (mounted) {
        setState(() => _inFlight = false);
      }
    }
    if (!mounted) {
      return;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) {
      widget.onSuccess(successfulPath);
    }
  }
}
