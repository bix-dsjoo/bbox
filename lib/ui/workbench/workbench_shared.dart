part of 'workbench_screen.dart';

class _ToolbarSeparator extends StatelessWidget {
  const _ToolbarSeparator({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: SizedBox(
        width: 1,
        height: 22,
        child: DecoratedBox(
          decoration: const BoxDecoration(color: WorkbenchPalette.border),
        ),
      ),
    );
  }
}

class _ImageImportMenuButton extends StatelessWidget {
  const _ImageImportMenuButton({
    required this.buttonKey,
    required this.enabled,
    required this.label,
    required this.onAddFiles,
    required this.onAddFolder,
  });

  final Key buttonKey;
  final bool enabled;
  final String label;
  final Future<void> Function() onAddFiles;
  final Future<void> Function() onAddFolder;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      key: buttonKey,
      menuChildren: [
        MenuItemButton(
          onPressed: enabled ? () => unawaited(onAddFolder()) : null,
          child: const Text(WorkbenchCopy.addImageFolder),
        ),
        MenuItemButton(
          onPressed: enabled ? () => unawaited(onAddFiles()) : null,
          child: const Text(WorkbenchCopy.addImageFiles),
        ),
      ],
      builder: (context, menuController, child) => TextButton.icon(
        onPressed: enabled
            ? () {
                if (menuController.isOpen) {
                  menuController.close();
                } else {
                  menuController.open();
                }
              }
            : null,
        icon: const Icon(Icons.photo_library_outlined),
        label: Text(label),
      ),
    );
  }
}

class _SaveStatusIndicator extends StatelessWidget {
  const _SaveStatusIndicator({required this.status});

  final SaveStatus status;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (key, icon, label, color) = switch (status) {
      SaveStatus.saved => (
        const ValueKey('save-status-saved'),
        Icons.check_circle_outline,
        WorkbenchCopy.saved,
        colorScheme.primary,
      ),
      SaveStatus.saving => (
        const ValueKey('save-status-saving'),
        Icons.sync,
        WorkbenchCopy.saving,
        colorScheme.onSurfaceVariant,
      ),
      SaveStatus.failed => (
        const ValueKey('save-status-failed'),
        Icons.error_outline,
        WorkbenchCopy.saveFailed,
        colorScheme.error,
      ),
    };
    return Semantics(
      label: label,
      child: Tooltip(
        message: label,
        child: DecoratedBox(
          key: const ValueKey('save-status-badge'),
          decoration: BoxDecoration(
            color: color.withAlpha(22),
            borderRadius: BorderRadius.circular(AppRadii.badge),
            border: Border.all(color: color.withAlpha(80)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            child: Row(
              key: key,
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
            ),
          ),
        ),
      ),
    );
  }
}

class _CanvasToolButton extends StatelessWidget {
  const _CanvasToolButton({
    required this.buttonKey,
    required this.selected,
    required this.tooltip,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final Key buttonKey;
  final bool selected;
  final String tooltip;
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        key: buttonKey,
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: selected
              ? Colors.white
              : colorScheme.onSurfaceVariant,
          backgroundColor: selected
              ? WorkbenchPalette.accent
              : Colors.transparent,
          side: selected
              ? const BorderSide(color: WorkbenchPalette.accentStrong)
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.button),
          ),
        ),
      ),
    );
  }
}

class _ShortcutBadge extends StatelessWidget {
  const _ShortcutBadge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withAlpha(150),
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.visible,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w800,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _EmptyActionState extends StatelessWidget {
  const _EmptyActionState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 36, color: colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PanelSurface extends StatelessWidget {
  const _PanelSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: _workbenchPanel,
        border: Border(right: BorderSide(color: _workbenchBorder)),
      ),
      child: child,
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.title, required this.summary});

  final String title;
  final String summary;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          summary,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
