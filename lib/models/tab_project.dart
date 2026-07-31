import 'tab_note.dart';
import 'tempo_map.dart';

/// A tablature project: the notes plus metadata needed to render and sync
/// them against an audio track. Audio itself is stored separately (as a
/// blob) and referenced only by [audioFileName] here.
class TabProject {
  TabProject({
    required this.id,
    required this.title,
    required this.notes,
    required this.tempo,
    this.audioFileName,
  });

  /// Stable identifier used as the persistence key ([ProjectStore]) and to
  /// distinguish projects in the dashboard list — independent of [title],
  /// which the user can freely rename without losing the saved project.
  final String id;

  final String title;
  final List<TabNote> notes;

  /// The song's tempo track. Replaces what used to be a single `bpm` plus
  /// a single `beatsPerMeasure`: real music changes tempo and meter, and —
  /// just as importantly — rarely starts its first downbeat at exactly
  /// 0:00, which the old model had no way to express at all. See
  /// [TempoMap].
  final TempoMap tempo;

  final String? audioFileName;

  TabProject copyWith({
    String? title,
    List<TabNote>? notes,
    TempoMap? tempo,
    String? audioFileName,
  }) {
    return TabProject(
      id: id,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      tempo: tempo ?? this.tempo,
      audioFileName: audioFileName ?? this.audioFileName,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'tempo': tempo.toJson(),
        'audioFileName': audioFileName,
        'notes': notes.map((n) => n.toJson()).toList(),
      };

  factory TabProject.fromJson(Map<String, dynamic> json) => TabProject(
        id: json['id'] as String,
        title: json['title'] as String,
        // Projects saved before the tempo track existed carry a flat
        // `bpm`/`beatsPerMeasure` pair instead; those describe exactly a
        // one-marker map starting at 0:00, so they migrate losslessly on
        // read and are rewritten in the new shape on the next save.
        tempo: json['tempo'] != null
            ? TempoMap.fromJson(json['tempo'] as Map<String, dynamic>)
            : TempoMap.single(
                bpm: (json['bpm'] as num?)?.toDouble() ?? 100,
                beatsPerMeasure:
                    (json['beatsPerMeasure'] as num?)?.toInt() ?? 4,
              ),
        audioFileName: json['audioFileName'] as String?,
        notes: (json['notes'] as List)
            .map((n) => TabNote.fromJson(n as Map<String, dynamic>))
            .toList(),
      );
}
