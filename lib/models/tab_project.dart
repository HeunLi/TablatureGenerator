import 'tab_note.dart';

/// A tablature project: the notes plus metadata needed to render and sync
/// them against an audio track. Audio itself is stored separately (as a
/// blob) and referenced only by [audioFileName] here.
class TabProject {
  TabProject({
    required this.title,
    required this.bpm,
    required this.notes,
    this.audioFileName,
  });

  final String title;
  final double bpm;
  final List<TabNote> notes;
  final String? audioFileName;

  TabProject copyWith({
    String? title,
    double? bpm,
    List<TabNote>? notes,
    String? audioFileName,
  }) {
    return TabProject(
      title: title ?? this.title,
      bpm: bpm ?? this.bpm,
      notes: notes ?? this.notes,
      audioFileName: audioFileName ?? this.audioFileName,
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'bpm': bpm,
        'audioFileName': audioFileName,
        'notes': notes.map((n) => n.toJson()).toList(),
      };

  factory TabProject.fromJson(Map<String, dynamic> json) => TabProject(
        title: json['title'] as String,
        bpm: (json['bpm'] as num).toDouble(),
        audioFileName: json['audioFileName'] as String?,
        notes: (json['notes'] as List)
            .map((n) => TabNote.fromJson(n as Map<String, dynamic>))
            .toList(),
      );
}
