import 'dart:ui';

import 'package:flutter/material.dart';

import '../persistence/project_store.dart';
import '../utils/safe_pop.dart';
import '../widgets/glass_panel.dart';
import 'studio_screen.dart';

/// Curated accent colors used to tint each project card's icon badge —
/// purely decorative (helps tell cards apart at a glance in the grid), not
/// meaningful data, so a fixed small palette indexed by a hash of the
/// project id is enough; no need for anything more elaborate. Leads with
/// the shared [accentColor] so the first (and most common, for few
/// projects) card matches the rest of the app's primary accent.
const _accentPalette = [
  accentColor, // violet
  Color(0xFF22B8CF), // teal
  Color(0xFFFF6B6B), // coral
  Color(0xFFFFA94D), // amber
  Color(0xFF51CF66), // green
  Color(0xFFFF8FE0), // pink
  Color(0xFF4DABF7), // blue
];

Color _accentFor(String id) =>
    _accentPalette[id.hashCode.abs() % _accentPalette.length];

const _dialogShape =
    RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16)));

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
        shape: _dialogShape,
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
        shape: _dialogShape,
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
      backgroundColor: const Color(0xFF12131A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Bass Tab Studio',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: backgroundGradient),
        child: projects == null
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  child: projects.isEmpty
                      ? _EmptyState(onCreate: _createProject)
                      : GridView.builder(
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 280,
                            mainAxisSpacing: 18,
                            crossAxisSpacing: 18,
                            childAspectRatio: 1.25,
                          ),
                          itemCount: projects.length + 1,
                          itemBuilder: (context, index) {
                            if (index == 0) {
                              return _NewProjectCard(onTap: _createProject);
                            }
                            final summary = projects[index - 1];
                            return _ProjectCard(
                              title: summary.title,
                              subtitle:
                                  'Edited ${_formatUpdatedAt(summary.updatedAt)}',
                              accent: _accentFor(summary.id),
                              onTap: () =>
                                  _openStudio(projectId: summary.id),
                              onRename: () => _renameProject(summary),
                              onDelete: () => _deleteProject(summary),
                            );
                          },
                        ),
                ),
              ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.library_music_outlined,
            size: 56,
            color: Colors.white.withValues(alpha: 0.25),
          ),
          const SizedBox(height: 16),
          Text(
            'No projects yet',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Create your first project to get started.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: 220,
            height: 130,
            child: _NewProjectCard(onTap: onCreate),
          ),
        ],
      ),
    );
  }
}

/// Shared glass-panel chrome (blurred, translucent, soft border/shadow) for
/// both [_ProjectCard] and [_NewProjectCard] — kept as one widget so the
/// two card kinds can never visually drift apart.
class _GlassCard extends StatefulWidget {
  const _GlassCard({
    required this.onTap,
    required this.builder,
    this.hoverBorderColor,
  });

  final VoidCallback onTap;
  final Color? hoverBorderColor;

  /// Builds the card's contents, given whether the pointer is currently
  /// hovering it (so content can react too, e.g. brightening an icon).
  final Widget Function(BuildContext context, bool hovering) builder;

  @override
  State<_GlassCard> createState() => _GlassCardState();
}

class _GlassCardState extends State<_GlassCard> {
  bool _hovering = false;

  static const _radius = BorderRadius.all(Radius.circular(20));

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedScale(
        scale: _hovering ? 1.02 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        child: ClipRRect(
          borderRadius: _radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              decoration: BoxDecoration(
                borderRadius: _radius,
                color: Colors.white.withValues(alpha: _hovering ? 0.09 : 0.05),
                border: Border.all(
                  color: _hovering
                      ? (widget.hoverBorderColor ?? Colors.white)
                          .withValues(alpha: 0.6)
                      : Colors.white.withValues(alpha: 0.1),
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: _radius,
                  onTap: widget.onTap,
                  child: widget.builder(context, _hovering),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final String title;
  final String subtitle;
  final Color accent;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      onTap: onTap,
      hoverBorderColor: accent,
      builder: (context, hovering) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 10, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [accent, accent.withValues(alpha: 0.55)],
                    ),
                  ),
                  child: const Icon(
                    Icons.graphic_eq,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const Spacer(),
                PopupMenuButton<VoidCallback>(
                  icon: Icon(
                    Icons.more_vert,
                    color: Colors.white.withValues(alpha: 0.55),
                    size: 20,
                  ),
                  color: const Color(0xFF20222C),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  onSelected: (action) => action(),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: onRename,
                      child: const Text('Rename'),
                    ),
                    PopupMenuItem(
                      value: onDelete,
                      child: const Text(
                        'Delete',
                        style: TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const Spacer(),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewProjectCard extends StatelessWidget {
  const _NewProjectCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      onTap: onTap,
      builder: (context, hovering) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.add,
              color: Colors.white.withValues(alpha: hovering ? 0.9 : 0.6),
              size: 28,
            ),
            const SizedBox(height: 8),
            Text(
              'New project',
              style: TextStyle(
                color: Colors.white.withValues(alpha: hovering ? 0.9 : 0.6),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
