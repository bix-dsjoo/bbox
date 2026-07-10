import 'package:flutter/material.dart';

import '../annotation/models.dart';
import 'workbench_copy.dart';

class WorkbenchLabelSelector extends StatefulWidget {
  const WorkbenchLabelSelector({
    super.key,
    required this.labels,
    required this.onAssignLabel,
    required this.onCreateLabel,
    this.errorText,
    this.autofocus = false,
  });

  final List<LabelClass> labels;
  final void Function(int labelId) onAssignLabel;
  final void Function(String name) onCreateLabel;
  final String? errorText;
  final bool autofocus;

  @override
  State<WorkbenchLabelSelector> createState() => _WorkbenchLabelSelectorState();
}

class _WorkbenchLabelSelectorState extends State<WorkbenchLabelSelector> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _controller.text.trim();
    final queryKey = query.toLowerCase();
    final filtered = widget.labels
        .where((label) => label.name.toLowerCase().contains(queryKey))
        .toList(growable: false);

    return Material(
      key: const ValueKey('label-selector-panel'),
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Theme.of(context).dividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('label-selector-input'),
              controller: _controller,
              autofocus: widget.autofocus,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                isDense: true,
                labelText: WorkbenchCopy.labelSelectorHint,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
            if (widget.errorText != null) ...[
              const SizedBox(height: 8),
              Text(
                widget.errorText!,
                key: const ValueKey('label-selector-error'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 8),
            if (filtered.isEmpty)
              Text(
                WorkbenchCopy.noMatchingLabels,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            for (var index = 0; index < filtered.length; index++)
              _LabelOption(
                key: ValueKey('label-option-${filtered[index].id}'),
                label: filtered[index],
                shortcut: index < 9 ? '${index + 1}' : null,
                onTap: () => widget.onAssignLabel(filtered[index].id),
              ),
          ],
        ),
      ),
    );
  }

  void _submit() {
    final query = _controller.text.trim();
    final queryKey = query.toLowerCase();
    final filtered = widget.labels
        .where((label) => label.name.toLowerCase().contains(queryKey))
        .toList(growable: false);
    if (filtered.isNotEmpty) {
      widget.onAssignLabel(filtered.first.id);
    }
  }
}

class _LabelOption extends StatelessWidget {
  const _LabelOption({
    super.key,
    required this.label,
    required this.shortcut,
    required this.onTap,
  });

  final LabelClass label;
  final String? shortcut;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        child: Row(
          children: [
            if (shortcut != null) ...[
              SizedBox(
                width: 20,
                child: Text(
                  shortcut!,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ],
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: Color(label.color),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
