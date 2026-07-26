/// Bass strings, ordered low to high pitch (E is the thickest/lowest string).
enum BassString { e, a, d, g }

/// A single fretted note placed on the tab timeline.
class TabNote {
  TabNote({
    required this.string,
    required this.fret,
    required this.timeOffset,
    required this.duration,
  });

  final BassString string;
  final int fret;

  /// Position of the note along the audio timeline.
  final Duration timeOffset;

  /// How long the note rings / stays highlighted.
  final Duration duration;

  TabNote copyWith({
    BassString? string,
    int? fret,
    Duration? timeOffset,
    Duration? duration,
  }) {
    return TabNote(
      string: string ?? this.string,
      fret: fret ?? this.fret,
      timeOffset: timeOffset ?? this.timeOffset,
      duration: duration ?? this.duration,
    );
  }

  Map<String, dynamic> toJson() => {
        'string': string.name,
        'fret': fret,
        'timeOffsetMs': timeOffset.inMilliseconds,
        'durationMs': duration.inMilliseconds,
      };

  factory TabNote.fromJson(Map<String, dynamic> json) => TabNote(
        string: BassString.values.byName(json['string'] as String),
        fret: json['fret'] as int,
        timeOffset: Duration(milliseconds: json['timeOffsetMs'] as int),
        duration: Duration(milliseconds: json['durationMs'] as int),
      );
}
