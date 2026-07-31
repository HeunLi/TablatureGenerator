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

  /// Height of the waveform preview strip drawn beneath the string lines,
  /// and the gap between the lowest string line and the top of that strip.
  /// Kept here rather than on the painter because the waveform *tile*
  /// renderer (`WaveformTileCache`) needs the exact same numbers to
  /// rasterize tiles that line up with what the painter draws around them —
  /// two copies of these constants drifting apart would misalign the strip
  /// against the playhead.
  static const waveformHeight = 56.0;
  static const waveformGap = 30.0;

  /// Y of the lowest string line — the anchor everything below the strings
  /// (waveform strip, highlight block's bottom edge) is measured from.
  double get bottomY =>
      topPadding + (stringOrderTopToBottom.length - 1) * stringSpacing;

  double get waveformTop => bottomY + waveformGap;
  double get waveformBottom => waveformTop + waveformHeight;

  /// Total scrollable width for a track of [totalSeconds], including the
  /// left gutter and a little trailing slack so the last notes aren't
  /// flush against the right edge.
  double contentWidth(double totalSeconds) =>
      totalSeconds * pixelsPerSecond + 80;

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

  /// Whether [y] falls in the waveform preview strip, which is its own
  /// interaction zone: tapping there seeks, and dragging there sets the A/B
  /// loop region. Keeping that band well clear of the string lines is what
  /// lets those gestures coexist with note editing without any modifier
  /// key — a drag either starts on the waveform or it doesn't.
  bool isWaveformY(double y) => y >= waveformTop && y <= waveformBottom;

  /// Vertical band above the grid reserved for tempo-marker flags. Measure
  /// numbers sit above it; the grid starts below.
  double get markerLabelTop => topPadding - 32;
  double get markerLabelHeight => 15.0;
}
