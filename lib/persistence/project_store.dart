import 'dart:convert';
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

/// Persists a single working project (tab data + audio) to the browser's
/// IndexedDB via Hive, so a refresh doesn't lose work. This is intentionally
/// single-slot for now — multi-project management can layer on top later.
class ProjectStore {
  static const _boxName = 'bass_tab_studio';
  static const _projectKey = 'project_json';
  static const _audioBytesKey = 'audio_bytes';
  static const _audioExtensionKey = 'audio_extension';

  Box? _box;

  Future<void> init() async {
    _box = await Hive.openBox(_boxName);
  }

  Future<void> save(
    TabProject project, {
    Uint8List? audioBytes,
    String? audioExtension,
  }) async {
    final box = _box;
    if (box == null) return;
    await box.put(_projectKey, jsonEncode(project.toJson()));
    if (audioBytes != null) {
      await box.put(_audioBytesKey, audioBytes);
      await box.put(_audioExtensionKey, audioExtension);
    }
  }

  StoredProject? load() {
    final box = _box;
    if (box == null) return null;
    final projectJson = box.get(_projectKey) as String?;
    if (projectJson == null) return null;

    final project = TabProject.fromJson(
      jsonDecode(projectJson) as Map<String, dynamic>,
    );
    final rawAudio = box.get(_audioBytesKey);
    final audioBytes = rawAudio == null
        ? null
        : Uint8List.fromList(List<int>.from(rawAudio as List));
    final audioExtension = box.get(_audioExtensionKey) as String?;

    return StoredProject(
      project: project,
      audioBytes: audioBytes,
      audioExtension: audioExtension,
    );
  }

  Future<void> clear() async {
    await _box?.clear();
  }
}
