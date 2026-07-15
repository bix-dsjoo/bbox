import 'package:bbox_labeler/annotation/default_labels.dart';
import 'package:bbox_labeler/annotation/models.dart';
import 'package:bbox_labeler/project/project_library.dart';
import 'package:path/path.dart' as p;

class MemoryProjectLibrary extends ProjectLibrary {
  MemoryProjectLibrary({
    required super.rootPath,
    this.fixedId = 'memory-project',
    DateTime? now,
  }) : _now = now ?? DateTime.utc(2026, 7, 7, 5, 30);

  final String fixedId;
  final DateTime _now;
  final Map<String, AnnotationProject> _projects = {};
  final Map<String, ProjectLibraryEntry> _entries = {};

  @override
  Future<List<ProjectLibraryEntry>> listProjects() async {
    return _sortedEntries();
  }

  @override
  Future<AnnotationProject> createProject(String name) async {
    final id = _allocateProjectId();
    final projectFilePath = p.join(projectsRootPath, id, 'project.bbox.json');
    final project =
        AnnotationProject.empty(
          name: name.trim().isEmpty ? 'BBox Project' : name.trim(),
        ).copyWith(
          projectFilePath: projectFilePath,
          status: ProjectStatus.ready,
          labels: createDefaultLabels(),
        );
    _projects[id] = project;
    _entries[id] = _entryFromProject(id, project);
    return project;
  }

  @override
  Future<AnnotationProject> importProject(AnnotationProject source) async {
    final id = _allocateProjectId();
    final projectFilePath = p.join(projectsRootPath, id, 'project.bbox.json');
    final imported = source.copyWith(
      projectFilePath: projectFilePath,
      status: ProjectStatus.ready,
    );
    _projects[id] = imported;
    _entries[id] = _entryFromProject(id, imported);
    return imported;
  }

  @override
  Future<AnnotationProject> openProject(String id) async {
    final project = _projects[id];
    if (project == null) {
      throw StateError('Project not found: $id');
    }
    return project;
  }

  @override
  Future<AnnotationProject> renameProject(String id, String name) async {
    final renamed = (await openProject(id)).copyWith(name: name);
    _projects[id] = renamed;
    _entries[id] = _entryFromProject(id, renamed);
    return renamed;
  }

  @override
  Future<void> deleteProject(String id) async {
    _projects.remove(id);
    _entries.remove(id);
  }

  @override
  Future<void> refreshEntry(
    AnnotationProject project, {
    DateTime? createdAt,
    DateTime? updatedAt,
  }) async {
    final path = project.projectFilePath;
    if (path == null) {
      return;
    }
    final id = p.basename(p.dirname(path));
    _projects[id] = project;
    _entries[id] = _entryFromProject(id, project);
  }

  ProjectLibraryEntry _entryFromProject(String id, AnnotationProject project) {
    return ProjectLibraryEntry(
      id: id,
      name: project.name,
      projectFilePath: project.projectFilePath!,
      createdAt: _now,
      updatedAt: project.lastSavedAt ?? _now,
      imageCount: project.images.length,
      confirmedImageCount: project.images
          .where((image) => image.status == ImageStatus.confirmed)
          .length,
      errorImageCount: project.images
          .where((image) => image.status == ImageStatus.error)
          .length,
    );
  }

  List<ProjectLibraryEntry> _sortedEntries() {
    return [..._entries.values]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  String _allocateProjectId() {
    var candidate = fixedId;
    var suffix = 2;
    while (_projects.containsKey(candidate)) {
      candidate = '$fixedId-$suffix';
      suffix += 1;
    }
    return candidate;
  }
}
