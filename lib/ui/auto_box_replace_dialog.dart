import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'workbench_copy.dart';

Future<void> confirmAndRunAutoBoxes(
  BuildContext context,
  AppController controller,
) async {
  final image = controller.selectedImage;
  if (image == null || !controller.canRunAutoBoxes) {
    return;
  }
  if (image.visibleBoxes.isEmpty) {
    await controller.detectSelectedImage();
    return;
  }

  final shouldReplace = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('auto-box-replace-dialog'),
      title: const Text(WorkbenchCopy.autoBoxesReplaceTitle),
      content: Text(
        '${WorkbenchCopy.autoBoxesReplaceMessage}\n\n'
        '현재 박스 ${image.visibleBoxes.length}개',
      ),
      actions: [
        TextButton(
          key: const ValueKey('cancel-auto-box-replace'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text(WorkbenchCopy.cancel),
        ),
        FilledButton(
          key: const ValueKey('confirm-auto-box-replace'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text(WorkbenchCopy.autoBoxesReplaceConfirm),
        ),
      ],
    ),
  );
  if (shouldReplace == true && context.mounted) {
    await controller.detectSelectedImage(replaceExisting: true);
  }
}
