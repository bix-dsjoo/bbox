import 'dart:io';

import 'package:flutter/foundation.dart';

class WindowsDialogService {
  const WindowsDialogService._();

  static const folderPickerTitle = '폴더 선택';
  static const imageFilePickerTitle = '이미지 파일 선택';
  static const imageFileDialogFilter =
      '이미지 파일 (*.jpg;*.jpeg;*.png)|*.jpg;*.jpeg;*.png|모든 파일 (*.*)|*.*';
  static const saveDialogFilter = 'COCO JSON (*.json)|*.json|모든 파일 (*.*)|*.*';

  static Future<String?> pickFolder({String title = folderPickerTitle}) {
    return _runPowerShellDialog(_buildPickFolderScript(title));
  }

  static Future<List<String>?> pickImageFiles({
    String title = imageFilePickerTitle,
  }) async {
    final output = await _runPowerShellDialog(
      _buildPickImageFilesScript(title),
    );
    return parseImageFileDialogOutput(output);
  }

  @visibleForTesting
  static String debugBuildPickImageFilesScript({
    String title = imageFilePickerTitle,
  }) {
    return _buildPickImageFilesScript(title);
  }

  @visibleForTesting
  static List<String>? debugParseImageFileOutput(String? output) {
    return parseImageFileDialogOutput(output);
  }

  static List<String>? parseImageFileDialogOutput(String? output) {
    if (output == null || output.trim().isEmpty) {
      return null;
    }
    return output
        .replaceAll('`r`n', '\n')
        .replaceAll('`n', '\n')
        .split(RegExp(r'\r?\n'))
        .where((path) => path.trim().isNotEmpty)
        .toList(growable: false);
  }

  static Future<String?> saveCocoFile() {
    return _runPowerShellDialog(_buildSaveCocoFileScript());
  }

  static String _buildPickFolderScript(String title) =>
      '''
Add-Type -AssemblyName System.Windows.Forms
\$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
\$dialog.Description = '${_escapePowerShellSingleQuotedString(title)}'
if (\$dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::Out.Write(\$dialog.SelectedPath)
}
''';

  static String _buildPickImageFilesScript(String title) =>
      '''
Add-Type -AssemblyName System.Windows.Forms
\$dialog = New-Object System.Windows.Forms.OpenFileDialog
\$dialog.Multiselect = \$true
\$dialog.Filter = '$imageFileDialogFilter'
\$dialog.Title = '${_escapePowerShellSingleQuotedString(title)}'
if (\$dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::Out.Write((\$dialog.FileNames -join [Environment]::NewLine))
}
''';

  static String _buildSaveCocoFileScript() =>
      '''
Add-Type -AssemblyName System.Windows.Forms
\$dialog = New-Object System.Windows.Forms.SaveFileDialog
\$dialog.Filter = '$saveDialogFilter'
\$dialog.Title = 'COCO JSON 내보내기'
\$dialog.DefaultExt = 'json'
if (\$dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::Out.Write(\$dialog.FileName)
}
''';

  static String _escapePowerShellSingleQuotedString(String value) {
    return value.replaceAll("'", "''");
  }

  static Future<String?> _runPowerShellDialog(String script) async {
    if (!Platform.isWindows) {
      return null;
    }
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-STA',
      '-Command',
      script,
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'powershell.exe',
        const ['-NoProfile', '-STA', '-Command'],
        result.stderr.toString(),
        result.exitCode,
      );
    }
    final output = result.stdout.toString().trim();
    return output.isEmpty ? null : output;
  }
}
