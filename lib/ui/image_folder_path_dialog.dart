import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ImageFolderPathDialog extends StatefulWidget {
  const ImageFolderPathDialog({
    super.key,
    this.initialPath,
    required this.browseFolder,
    this.readClipboard,
  });

  final String? initialPath;
  final Future<String?> Function() browseFolder;
  final Future<String?> Function()? readClipboard;

  @override
  State<ImageFolderPathDialog> createState() => _ImageFolderPathDialogState();
}

class _ImageFolderPathDialogState extends State<ImageFolderPathDialog> {
  late final TextEditingController _pathController;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _pathController = TextEditingController(text: widget.initialPath ?? '');
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('이미지 폴더 불러오기'),
      content: SizedBox(
        width: 520,
        child: TextField(
          key: const ValueKey('image-folder-path-input'),
          controller: _pathController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '이미지 폴더 경로',
            border: const OutlineInputBorder(),
            errorText: _errorText,
          ),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        TextButton.icon(
          key: const ValueKey('paste-image-folder-path'),
          onPressed: _paste,
          icon: const Icon(Icons.content_paste_outlined),
          label: const Text('붙여넣기'),
        ),
        TextButton.icon(
          key: const ValueKey('browse-image-folder'),
          onPressed: _browse,
          icon: const Icon(Icons.folder_open_outlined),
          label: const Text('찾아보기'),
        ),
        ElevatedButton.icon(
          key: const ValueKey('import-image-folder-path'),
          onPressed: _submit,
          icon: const Icon(Icons.download_done_outlined),
          label: const Text('불러오기'),
        ),
      ],
    );
  }

  Future<void> _browse() async {
    final path = await widget.browseFolder();
    if (!mounted) {
      return;
    }
    _setPath(path);
  }

  Future<void> _paste() async {
    final reader = widget.readClipboard;
    final text = reader == null
        ? (await Clipboard.getData(Clipboard.kTextPlain))?.text
        : await reader();
    if (!mounted) {
      return;
    }
    _setPath(text);
  }

  void _setPath(String? path) {
    if (path == null || path.trim().isEmpty) {
      return;
    }
    setState(() {
      _pathController.text = path.trim();
      _errorText = null;
    });
  }

  void _submit() {
    final path = _pathController.text.trim();
    if (path.isEmpty) {
      setState(() => _errorText = '이미지 폴더 경로를 입력하세요.');
      return;
    }
    Navigator.of(context).pop(path);
  }
}
