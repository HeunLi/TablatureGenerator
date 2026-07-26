import 'dart:ui';

import '../models/tab_note.dart';

/// Shared time/string <-> pixel math so the painter and the gesture
/// handling in the editor screen agree on where everything is.
class TabTimelineLayout {
  const TabTimelineLayout({
    required this.pixelsPerSecond,
    required this.stringSpacing,
    required this.topPadding,
    required this.leftPadding,
  });

  final double pixelsPerSecond;
  final double stringSpacing;
  final double topPadding;
  final double leftPadding;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TabTimelineLayout &&
          other.pixelsPerSecond == pixelsPerSecond &&
          other.stringSpacing == stringSpacing &&
          other.topPadding == topPadding &&
          other.leftPadding == leftPadding;

  @override
  int get hashCode =>
      Object.hash(pixelsPerSecond, stringSpacing, topPadding, leftPadding);

  static const List<BassString> stringOrderTopToBottom = [
    BassString.g,
    BassString.d,
    BassString.a,
    BassString.e,
  ];

  double xForTime(Duration time) =>
      leftPadding +
      time.inMicroseconds / Duration.microsecondsPerSecond * pixelsPerSecond;

  Duration timeForX(double x) {
    final seconds = (x - leftPadding) / pixelsPerSecond;
    final clamped = seconds < 0 ? 0.0 : seconds;
    return Duration(
      microseconds: (clamped * Duration.microsecondsPerSecond).round(),
    );
  }

  double yForString(BassString string) =>
      topPadding + stringOrderTopToBottom.indexOf(string) * stringSpacing;

  BassString stringForY(double y) {
    final index = ((y - topPadding) / stringSpacing)
        .round()
        .clamp(0, stringOrderTopToBottom.length - 1);
    return stringOrderTopToBottom[index];
  }

  /// Returns the index (into [notes]) of the topmost note whose circle
  /// contains [position], or null if none does.
  int? hitTestNoteIndex(
    List<TabNote> notes,
    Offset position, {
    double hitRadius = 14,
  }) {
    for (var i = notes.length - 1; i >= 0; i--) {
      final note = notes[i];
      final dx = xForTime(note.timeOffset) - position.dx;
      final dy = yForString(note.string) - position.dy;
      if (dx * dx + dy * dy <= hitRadius * hitRadius) {
        return i;
      }
    }
    return null;
  }

  /// Snaps [time] to the nearest grid subdivision given [bpm].
  Duration snapToGrid(Duration time, double bpm, {int subdivisionsPerBeat = 4}) {
    final beatMs = 60000 / bpm;
    final gridMs = beatMs / subdivisionsPerBeat;
    final snappedMs = (time.inMilliseconds / gridMs).round() * gridMs;
    return Duration(milliseconds: snappedMs.round().clamp(0, 1 << 30));
  }

  /// Start/end (in seconds from the timeline origin) of a block of
  /// [beatsPerBlock] consecutive beats containing [currentTime] — used both
  /// for the highlight block (independent of the measure/time signature —
  /// a 3/4 song might only want 3 beats highlighted, not a fixed 4) and for
  /// measure-width math (pass the project's actual beats-per-measure).
  /// Shared by the editor's live preview and the export renderer so both
  /// always agree on where a block boundary falls.
  static (double start, double end) beatBlockBoundsSeconds(
    Duration currentTime,
    double bpm,
    int beatsPerBlock,
  ) {
    final blockDuration = beatsPerBlock * 60 / bpm;
    if (blockDuration <= 0) return (0, 0);
    final currentSeconds =
        currentTime.inMicroseconds / Duration.microsecondsPerSecond;
    final index = (currentSeconds / blockDuration).floor();
    final start = index * blockDuration;
    return (start, start + blockDuration);
  }
}
