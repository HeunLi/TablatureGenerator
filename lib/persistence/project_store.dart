import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:hive_ce_flutter/hive_flutter.dart';

import '../models/tab_project.dart';

/// A loaded project plus whatever audio was saved alongside it.
class StoredProject {
  StoredProject({required this.project, this.audioBytes, this.audioExtension});

  final TabProject project;
  final Uint8List? audioBytes;
  final String? audioExtension;
}

/// Lightweight metadata for the dashboard's project list — avoids needing
/// to decode every project's full note list just to show a title.
class ProjectSummary {
  ProjectSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final DateTime updatedAt;
}

/// Persists any number of projects (tab data + audio) to the browser's
/// IndexedDB via Hive, keyed by [TabProject.id], so a refresh doesn't lose
/// work and multiple songs can be worked on independently.
///
/// One flat Hive box holds three kinds of entry per project, distinguished
/// by key prefix: `project:<id>` (JSON envelope of metadata + the project
/// itself), `audio_bytes:<id>`, and `audio_extension:<id>`. A separate
/// per-project box was considered but a single box keeps `listProjects()`
/// (which needs to enumerate everything) to one `box.keys` scan instead of
/// juggling box-open lifecycles per project.
class ProjectStore {
  static const _boxName = 'bass_tab_studio_projects';
  static const _projectPrefix = 'project:';
  static const _audioBytesPrefix = 'audio_bytes:';
  static const _audioExtensionPrefix = 'audio_extension:';

  // Legacy single-slot storage (pre-dashboard). Only read once, to migrate
  // whatever the user already had saved into the new multi-project box the
  // first time it's opened — otherwise upgrading would silently orphan it.
  static const _legacyBoxName = 'bass_tab_studio';
  static const _legacyProjectKey = 'project_json';
  static const _legacyAudioBytesKey = 'audio_bytes';
  static const _legacyAudioExtensionKey = 'audio_extension';

  final _random = Random();

  Box? _box;

  Future<void> init() async {
    _box = await Hive.openBox(_boxName);
    await _migrateLegacyProjectIfNeeded();
  }

  Future<void> _migrateLegacyProjectIfNeeded() async {
    final box = _box;
    if (box == null || box.keys.any((k) => k is String && k.startsWith(_projectPrefix))) {
      return;
    }
    if (!await Hive.boxExists(_legacyBoxName)) return;

    final legacyBox = await Hive.openBox(_legacyBoxName);
    final legacyJson = legacyBox.get(_legacyProjectKey) as String?;
    if (legacyJson == null) {
      await legacyBox.close();
      return;
    }

    final legacyProjectFields = jsonDecode(legacyJson) as Map<String, dynamic>;
    // Pre-dashboard projects predate TabProject.id, so synthesize one.
    legacyProjectFields['id'] ??= createId();
    final project = TabProject.fromJson(legacyProjectFields);

    final rawAudio = legacyBox.get(_legacyAudioBytesKey);
    final audioBytes = rawAudio == null
        ? null
        : Uint8List.fromList(List<int>.from(rawAudio as List));
    final audioExtension = legacyBox.get(_legacyAudioExtensionKey) as String?;

    await save(
      project,
      audioBytes: audioBytes,
      audioExtension: audioExtension,
    );
    await legacyBox.close();
  }

  /// Generates a new, effectively-unique project id (timestamp + random
  /// suffix — no need for a real UUID dependency for a local-only, single
  /// browser's worth of projects). The random bound is kept well under
  /// 2^32 deliberately: `1 << 32` folds to `0` under dart2js/DDC's JS-int32
  /// shift semantics, which made `Random.nextInt` throw on every call.
  String createId() =>
      '${DateTime.now().microsecondsSinceEpoch}_${_random.nextInt(1000000)}';

  Future<void> save(
    TabProject project, {
    Uint8List? audioBytes,
    String? audioExtension,
  }) async {
    final box = _box;
    if (box == null) return;
    final envelope = {
      'updatedAt': DateTime.now().toIso8601String(),
      'project': project.toJson(),
    };
    await box.put('$_projectPrefix${project.id}', jsonEncode(envelope));
    if (audioBytes != null) {
      await box.put('$_audioBytesPrefix${project.id}', audioBytes);
      await box.put('$_audioExtensionPrefix${project.id}', audioExtension);
    }
  }

  StoredProject? load(String id) {
    final box = _box;
    if (box == null) return null;
    final raw = box.get('$_projectPrefix$id') as String?;
    if (raw == null) return null;

    final envelope = jsonDecode(raw) as Map<String, dynamic>;
    final project =
        TabProject.fromJson(envelope['project'] as Map<String, dynamic>);
    final rawAudio = box.get('$_audioBytesPrefix$id');
    final audioBytes = rawAudio == null
        ? null
        : Uint8List.fromList(List<int>.from(rawAudio as List));
    final audioExtension = box.get('$_audioExtensionPrefix$id') as String?;

    return StoredProject(
      project: project,
      audioBytes: audioBytes,
      audioExtension: audioExtension,
    );
  }

  List<ProjectSummary> listProjects() {
    final box = _box;
    if (box == null) return [];
    final summaries = <ProjectSummary>[];
    for (final key in box.keys) {
      if (key is! String || !key.startsWith(_projectPrefix)) continue;
      final raw = box.get(key) as String?;
      if (raw == null) continue;
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      final projectFields = envelope['project'] as Map<String, dynamic>;
      summaries.add(
        ProjectSummary(
          id: key.substring(_projectPrefix.length),
          title: projectFields['title'] as String,
          updatedAt: DateTime.parse(envelope['updatedAt'] as String),
        ),
      );
    }
    summaries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return summaries;
  }

  Future<void> delete(String id) async {
    final box = _box;
    if (box == null) return;
    await box.delete('$_projectPrefix$id');
    await box.delete('$_audioBytesPrefix$id');
    await box.delete('$_audioExtensionPrefix$id');
  }

  Future<void> renameProject(String id, String newTitle) async {
    final stored = load(id);
    if (stored == null) return;
    await save(
      stored.project.copyWith(title: newTitle),
      audioBytes: stored.audioBytes,
      audioExtension: stored.audioExtension,
    );
  }
}
