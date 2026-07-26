import 'tab_note.dart';

/// A tablature project: the notes plus metadata needed to render and sync
/// them against an audio track. Audio itself is stored separately (as a
/// blob) and referenced only by [audioFileName] here.
class TabProject {
  TabProject({
    required this.title,
    required this.bpm,
    required this.notes,
    this.beatsPerMeasure = 4,
    this.audioFileName,
  });

  final String title;
  final double bpm;
  final List<TabNote> notes;

  /// Time signature numerator — how many beats make up one measure (e.g.
  /// 4 for 4/4, 3 for 3/4). Not every song is 4/4, so this is a real,
  /// user-editable setting rather than an assumption baked into the
  /// renderer.
  final int beatsPerMeasure;
  final String? audioFileName;

  TabProject copyWith({
    String? title,
    double? bpm,
    List<TabNote>? notes,
    int? beatsPerMeasure,
    String? audioFileName,
  }) {
    return TabProject(
      title: title ?? this.title,
      bpm: bpm ?? this.bpm,
      notes: notes ?? this.notes,
      beatsPerMeasure: beatsPerMeasure ?? this.beatsPerMeasure,
      audioFileName: audioFileName ?? this.audioFileName,
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'bpm': bpm,
        'beatsPerMeasure': beatsPerMeasure,
        'audioFileName': audioFileName,
        'notes': notes.map((n) => n.toJson()).toList(),
      };

  factory TabProject.fromJson(Map<String, dynamic> json) => TabProject(
        title: json['title'] as String,
        bpm: (json['bpm'] as num).toDouble(),
        beatsPerMeasure: (json['beatsPerMeasure'] as num?)?.toInt() ?? 4,
        audioFileName: json['audioFileName'] as String?,
        notes: (json['notes'] as List)
            .map((n) => TabNote.fromJson(n as Map<String, dynamic>))
            .toList(),
      );
}
