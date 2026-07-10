import 'package:flutter/material.dart';

import '../annotation/annotation_rules.dart';
import '../annotation/default_labels.dart';
import '../annotation/models.dart';
import 'app_theme.dart';

class LabelManagementPopover extends StatefulWidget {
  const LabelManagementPopover({
    super.key,
    required this.labels,
    required this.onCreateLabel,
    required this.onUpdateLabel,
  });

  final List<LabelClass> labels;
  final void Function(String name, int color, String? shortcut) onCreateLabel;
  final void Function(int id, String name, int color, String? shortcut)
  onUpdateLabel;

  @override
  State<LabelManagementPopover> createState() => _LabelManagementPopoverState();
}

class _LabelManagementPopoverState extends State<LabelManagementPopover> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _shortcut = TextEditingController();
  int _color = defaultLabelColors.first;
  int? _editingLabelId;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _name.addListener(_clearError);
    _shortcut.addListener(_clearError);
  }

  @override
  void dispose() {
    _name.removeListener(_clearError);
    _shortcut.removeListener(_clearError);
    _name.dispose();
    _shortcut.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = _editingLabelId != null;
    return Material(
      key: const ValueKey('label-management-popover'),
      color: WorkbenchPalette.panel,
      elevation: 10,
      shadowColor: Colors.black.withAlpha(30),
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380, maxHeight: 420),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('label-name-input'),
                      controller: _name,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: '라벨 이름',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 82,
                    child: TextField(
                      key: const ValueKey('label-shortcut-input'),
                      controller: _shortcut,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: '키',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _ColorMenu(
                    value: _color,
                    onChanged: (value) => setState(() => _color = value),
                  ),
                  const SizedBox(width: 8),
                  KeyedSubtree(
                    key: ValueKey(
                      isEditing
                          ? 'update-managed-label-forui'
                          : 'create-managed-label-forui',
                    ),
                    child: FilledButton(
                      key: ValueKey(
                        isEditing
                            ? 'update-managed-label'
                            : 'create-managed-label',
                      ),
                      onPressed: isEditing ? _update : _create,
                      child: Text(isEditing ? '수정' : '추가'),
                    ),
                  ),
                ],
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _errorText!,
                    key: const ValueKey('label-management-error'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final label in widget.labels)
                      _ManagedLabelRow(
                        label: label,
                        onTap: () => _startEditing(label),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _startEditing(LabelClass label) {
    setState(() {
      _editingLabelId = label.id;
      _name.text = label.name;
      _shortcut.text = label.shortcut ?? '';
      _color = label.color;
      _errorText = null;
    });
  }

  void _create() {
    _submit(() {
      widget.onCreateLabel(_trimmedName, _color, _normalizedShortcut);
    });
  }

  void _update() {
    final labelId = _editingLabelId;
    if (labelId == null) {
      return;
    }
    _submit(() {
      widget.onUpdateLabel(labelId, _trimmedName, _color, _normalizedShortcut);
    });
  }

  void _reset() {
    setState(() {
      _editingLabelId = null;
      _name.clear();
      _shortcut.clear();
      _color = defaultLabelColors.first;
      _errorText = null;
    });
  }

  String get _trimmedName => _name.text.trim();

  String? get _normalizedShortcut {
    final value = _shortcut.text.trim().toLowerCase();
    return value.isEmpty ? null : value;
  }

  void _clearError() {
    if (_errorText == null || !mounted) {
      return;
    }
    setState(() => _errorText = null);
  }

  void _submit(VoidCallback action) {
    final validationError = _validate();
    if (validationError != null) {
      setState(() => _errorText = validationError);
      return;
    }
    try {
      action();
      _reset();
    } catch (error) {
      setState(() => _errorText = _formatError(error));
    }
  }

  String? _validate() {
    if (_trimmedName.isEmpty) {
      return '라벨 이름을 입력하세요.';
    }
    final normalizedName = _trimmedName.toLowerCase();
    final duplicate = widget.labels.any(
      (label) =>
          label.id != _editingLabelId &&
          label.name.trim().toLowerCase() == normalizedName,
    );
    if (duplicate) {
      return 'Duplicate label name: $_trimmedName';
    }
    final shortcut = _normalizedShortcut;
    if (shortcut != null && !quickLabelShortcutSet.contains(shortcut)) {
      return '지원하지 않는 라벨 단축키입니다.';
    }
    return null;
  }

  String _formatError(Object error) {
    final message = error.toString();
    const badStatePrefix = 'Bad state: ';
    if (message.startsWith(badStatePrefix)) {
      return message.substring(badStatePrefix.length);
    }
    return message;
  }
}

class _ColorMenu extends StatelessWidget {
  const _ColorMenu({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: 'Color',
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final color in defaultLabelColors)
          PopupMenuItem(
            value: color,
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: Color(color),
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Color(value),
          shape: BoxShape.circle,
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
      ),
    );
  }
}

class _ManagedLabelRow extends StatelessWidget {
  const _ManagedLabelRow({required this.label, required this.onTap});

  final LabelClass label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: ValueKey('managed-label-row-${label.id}'),
      dense: true,
      leading: Container(
        key: ValueKey('managed-label-color-${label.id}'),
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: Color(label.color),
          shape: BoxShape.circle,
        ),
      ),
      title: Text(label.name, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label.shortcut ?? ''),
          IconButton(
            key: ValueKey('edit-managed-label-${label.id}'),
            tooltip: 'Edit label',
            onPressed: onTap,
            icon: const Icon(Icons.edit_outlined, size: 18),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}
