import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'app_theme.dart';
import 'project_home_copy.dart';
import 'project_transfer_picker.dart';

class StartScreen extends StatefulWidget {
  const StartScreen({
    super.key,
    required this.controller,
    required this.projectTransferPicker,
  });

  final AppController controller;
  final ProjectTransferPicker projectTransferPicker;

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  final TextEditingController _nameController = TextEditingController(
    text: ProjectHomeCopy.defaultProjectName,
  );
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.loadProjectLibrary();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: WorkbenchPalette.appBackground,
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                key: const ValueKey('project-home'),
                constraints: const BoxConstraints(maxWidth: 760),
                child: Padding(
                  key: const ValueKey('project-home-shell'),
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        ProjectHomeCopy.title,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              fontFamily: BboxAppTheme.fontFamily,
                              fontWeight: FontWeight.w800,
                              color: WorkbenchPalette.foreground,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        ProjectHomeCopy.subtitle,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: WorkbenchPalette.mutedForeground,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              key: const ValueKey('new-project-name'),
                              controller: _nameController,
                              decoration: const InputDecoration(
                                labelText: ProjectHomeCopy.projectName,
                                border: OutlineInputBorder(),
                              ),
                              onSubmitted: (_) => _createProject(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          KeyedSubtree(
                            key: const ValueKey('create-project-forui'),
                            child: FilledButton.icon(
                              key: const ValueKey('create-project'),
                              onPressed: _createProject,
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text(ProjectHomeCopy.createProject),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Tooltip(
                          message: ProjectHomeCopy.importProjectFileHint,
                          child: OutlinedButton.icon(
                            key: const ValueKey('import-project-file'),
                            onPressed: _importProjectFile,
                            icon: const Icon(
                              Icons.file_open_outlined,
                              size: 18,
                            ),
                            label: const Text(
                              ProjectHomeCopy.importProjectFile,
                            ),
                          ),
                        ),
                      ),
                      if (widget.controller.isProjectLibraryLoading)
                        const LinearProgressIndicator()
                      else if (widget.controller.projectLibraryEntries.isEmpty)
                        Expanded(
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.folder_open_outlined,
                                  size: 28,
                                  color: WorkbenchPalette.mutedForeground,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  ProjectHomeCopy.noProjects,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  ProjectHomeCopy.noProjectsMessage,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        color: WorkbenchPalette.mutedForeground,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        Expanded(
                          child: ListView.separated(
                            itemCount:
                                widget.controller.projectLibraryEntries.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final entry = widget
                                  .controller
                                  .projectLibraryEntries[index];
                              return ListTile(
                                key: ValueKey('project-entry-${entry.id}'),
                                leading: const Icon(Icons.folder_outlined),
                                title: Text(entry.name),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      ProjectHomeCopy.projectSummary(
                                        images: entry.imageCount,
                                        confirmed: entry.confirmedImageCount,
                                        errors: entry.errorImageCount,
                                      ),
                                    ),
                                  ],
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(_formatDate(entry.updatedAt)),
                                    PopupMenuButton<String>(
                                      key: ValueKey('project-menu-${entry.id}'),
                                      tooltip: ProjectHomeCopy.projectActions,
                                      onSelected: (value) {
                                        if (value == 'rename') {
                                          _renameProject(entry.id, entry.name);
                                        } else if (value == 'delete') {
                                          _deleteProject(entry.id, entry.name);
                                        }
                                      },
                                      itemBuilder: (context) => [
                                        PopupMenuItem(
                                          key: ValueKey(
                                            'rename-project-${entry.id}',
                                          ),
                                          value: 'rename',
                                          child: const Text(
                                            ProjectHomeCopy.rename,
                                          ),
                                        ),
                                        PopupMenuItem(
                                          key: ValueKey(
                                            'delete-project-${entry.id}',
                                          ),
                                          value: 'delete',
                                          child: const Text(
                                            ProjectHomeCopy.delete,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                onTap: () => _openLibraryProject(entry.id),
                              );
                            },
                          ),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            ProjectHomeCopy.actionFailed(_error!),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _createProject() async {
    final name = _nameController.text.trim().isEmpty
        ? ProjectHomeCopy.defaultProjectName
        : _nameController.text.trim();
    try {
      await widget.controller.createLibraryProject(name);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error);
    }
  }

  Future<void> _importProjectFile() async {
    try {
      final path = await widget.projectTransferPicker.pickImportFile();
      if (path == null) {
        return;
      }
      await widget.controller.importProjectSnapshot(path);
      if (mounted) {
        setState(() => _error = null);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error);
      }
    }
  }

  Future<void> _openLibraryProject(String id) async {
    try {
      await widget.controller.openLibraryProject(id);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error);
    }
  }

  Future<void> _renameProject(String id, String currentName) async {
    var pendingName = currentName;
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text(ProjectHomeCopy.renameTitle),
            content: TextFormField(
              key: const ValueKey('rename-project-name'),
              initialValue: currentName,
              decoration: const InputDecoration(
                labelText: ProjectHomeCopy.projectName,
                border: OutlineInputBorder(),
              ),
              autofocus: true,
              onChanged: (value) => pendingName = value,
              onFieldSubmitted: (value) => Navigator.of(context).pop(value),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text(ProjectHomeCopy.cancel),
              ),
              FilledButton(
                key: const ValueKey('confirm-rename-project'),
                onPressed: () => Navigator.of(context).pop(pendingName),
                child: const Text(ProjectHomeCopy.renameConfirm),
              ),
            ],
          );
        },
      );
      if (!mounted || name == null || name.trim().isEmpty) {
        return;
      }
      await widget.controller.renameLibraryProject(id, name);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error);
    }
  }

  Future<void> _deleteProject(String id, String name) async {
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text(ProjectHomeCopy.deleteTitle),
            content: const Text(ProjectHomeCopy.deleteMessage),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text(ProjectHomeCopy.cancel),
              ),
              FilledButton(
                key: const ValueKey('confirm-delete-project'),
                style: FilledButton.styleFrom(
                  backgroundColor: WorkbenchPalette.danger,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text(ProjectHomeCopy.delete),
              ),
            ],
          );
        },
      );
      if (!mounted || confirmed != true) {
        return;
      }
      await widget.controller.deleteLibraryProject(id);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error);
    }
  }
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
