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
}
