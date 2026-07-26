import 'package:flutter/material.dart';

import '../persistence/project_store.dart';
import '../utils/safe_pop.dart';
import 'studio_screen.dart';

/// Landing screen: lists every locally-saved project and lets the user
/// open, rename, delete, or create one. [StudioScreen] (the tab editor)
/// only ever works on a single project at a time — this is where picking
/// *which* one happens.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _store = ProjectStore();
  List<ProjectSummary>? _projects;

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  Future<void> _loadProjects() async {
    await _store.init();
    if (!mounted) return;
    setState(() => _projects = _store.listProjects());
  }

  Future<void> _openStudio({
    required String projectId,
    bool isNewProject = false,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StudioScreen(
          projectId: projectId,
          isNewProject: isNewProject,
        ),
      ),
    );
    // The project just opened may have been saved for the first time (or
    // saved again), so the list/timestamps could now be stale.
    _loadProjects();
  }

  Future<void> _createProject() async {
    final id = _store.createId();
    await _openStudio(projectId: id, isNewProject: true);
  }

  Future<void> _renameProject(ProjectSummary summary) async {
    final controller = TextEditingController(text: summary.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename project'),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (value) => safePopOnSubmit(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = newTitle?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    await _store.renameProject(summary.id, trimmed);
    _loadProjects();
  }

  Future<void> _deleteProject(ProjectSummary summary) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete project?'),
        content: Text(
          '"${summary.title}" and its saved audio will be deleted. '
          'This can\'t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _store.delete(summary.id);
    _loadProjects();
  }

  String _formatUpdatedAt(DateTime dt) {
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final projects = _projects;
    return Scaffold(
      appBar: AppBar(title: const Text('Bass Tab Studio')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createProject,
        icon: const Icon(Icons.add),
        label: const Text('New project'),
      ),
      body: projects == null
          ? const Center(child: CircularProgressIndicator())
          : projects.isEmpty
              ? const Center(
                  child: Text(
                    'No projects yet — tap "New project" to create one.',
                    style: TextStyle(color: Colors.white54),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: projects.length,
                  itemBuilder: (context, index) {
                    final summary = projects[index];
                    return ListTile(
                      leading: const Icon(Icons.music_note),
                      title: Text(summary.title),
                      subtitle: Text(
                        'Last edited ${_formatUpdatedAt(summary.updatedAt)}',
                      ),
                      onTap: () => _openStudio(projectId: summary.id),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: 'Rename',
                            onPressed: () => _renameProject(summary),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: 'Delete',
                            onPressed: () => _deleteProject(summary),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
