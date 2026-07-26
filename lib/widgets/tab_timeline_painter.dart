import 'package:flutter/material.dart';

import '../models/tab_note.dart';
import 'tab_timeline_layout.dart';

/// Renders bass tab notes on a time-based timeline: x-axis is seconds,
/// each of the 4 strings is a horizontal line, and fret numbers are drawn
/// at each note's time offset. A playhead line shows the current audio
/// position, and notes currently "ringing" are highlighted.
class TabTimelinePainter extends CustomPainter {
  TabTimelinePainter({
    required this.notes,
    required this.layout,
    required this.playhead,
    required this.bpm,
    required this.totalSeconds,
    this.beatsPerMeasure = 4,
    this.highlightBeats = 4,
    this.selectedIndex,
    this.windowStartSeconds = 0,
    double? windowEndSeconds,
  }) : windowEndSeconds = windowEndSeconds ?? totalSeconds;

  final List<TabNote> notes;
  final TabTimelineLayout layout;
  final Duration playhead;
  final double bpm;
  final double totalSeconds;

  /// Only the grid lines and notes whose time falls within
  /// [windowStartSeconds, windowEndSeconds] are actually drawn. The canvas
  /// itself is still sized for the *whole* track (so scrolling/scrollbar
  /// extents stay correct) — this just bounds the cost of building the
  /// draw-command list to roughly "one buffered viewport" instead of the
  /// entire track. Without it, a multi-minute MP3 makes every repaint
  /// (which fires on every playhead tick during playback) redo thousands
  /// of off-screen grid-line draws proportional to track length.
  final double windowStartSeconds;
  final double windowEndSeconds;

  /// Time signature numerator (e.g. 4 for 4/4, 3 for 3/4) — controls where
  /// the brighter measure bar-lines fall.
  final int beatsPerMeasure;

  /// How many beats light up together as one highlight block. Independent
  /// of [beatsPerMeasure] — a 3/4 song might want exactly 3 beats
  /// highlighted, not a fixed measure width.
  final int highlightBeats;

  final int? selectedIndex;

  bool _isRinging(TabNote note) {
    final start = note.timeOffset;
    final end = note.timeOffset + note.duration;
    return playhead >= start && playhead < end;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    final gridPaint = Paint()
      ..color = Colors.white10
      ..strokeWidth = 1;

    final bottomY =
        layout.topPadding +
        (TabTimelineLayout.stringOrderTopToBottom.length - 1) *
            layout.stringSpacing;

    // Current highlight block — previews the block used in the exported
    // video, computed with the same shared math so both agree on where it
    // falls. Sized in beats directly, independent of the measure width.
    final (blockStart, blockEnd) = TabTimelineLayout.beatBlockBoundsSeconds(
      playhead,
      bpm,
      highlightBeats,
    );
    if (blockEnd > blockStart) {
      final x0 = layout.xForTime(
        Duration(microseconds: (blockStart * 1e6).round()),
      );
      final x1 = layout.xForTime(
        Duration(microseconds: (blockEnd * 1e6).round()),
      );
      canvas.drawRect(
        Rect.fromLTRB(x0, layout.topPadding - 16, x1, bottomY + 16),
        Paint()..color = const Color(0x59FFEB3B), // amber @ ~35% opacity
      );
    }

    // Beat subdivision grid lines; a brighter line marks each measure
    // boundary (every beatsPerMeasure beats), matching the project's
    // actual time signature instead of assuming 4/4. Bounded to the
    // buffered visible window (see [windowStartSeconds]) rather than the
    // whole track.
    final beatMs = 60000 / bpm;
    final gridMs = beatMs / 4;
    final measurePaint = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1.5;
    final windowStartMs = (windowStartSeconds * 1000).clamp(0, double.infinity);
    final gridStartMs = (windowStartMs / gridMs).floor() * gridMs;
    final gridEndMs = (windowEndSeconds * 1000).clamp(0, totalSeconds * 1000);
    for (double ms = gridStartMs; ms <= gridEndMs; ms += gridMs) {
      final x = layout.xForTime(Duration(milliseconds: ms.round()));
      final beatIndex = (ms / beatMs).round();
      final isBeat = (ms % beatMs).abs() < 1 || (beatMs - ms % beatMs) < 1;
      final isMeasureLine = isBeat && beatIndex % beatsPerMeasure == 0;
      canvas.drawLine(
        Offset(x, layout.topPadding - 10),
        Offset(x, bottomY + 10),
        isMeasureLine ? measurePaint : (isBeat ? linePaint : gridPaint),
      );
    }

    // String lines + labels.
    const labels = {
      BassString.g: 'G',
      BassString.d: 'D',
      BassString.a: 'A',
      BassString.e: 'E',
    };
    for (final string in TabTimelineLayout.stringOrderTopToBottom) {
      final y = layout.yForString(string);
      canvas.drawLine(
        Offset(layout.leftPadding, y),
        Offset(size.width, y),
        linePaint,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: labels[string],
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(12, y - tp.height / 2));
    }

    // Notes. Same buffered-window bound as the grid lines above.
    for (var i = 0; i < notes.length; i++) {
      final note = notes[i];
      final noteSeconds =
          note.timeOffset.inMicroseconds / Duration.microsecondsPerSecond;
      if (noteSeconds < windowStartSeconds || noteSeconds > windowEndSeconds) {
        continue;
      }
      final x = layout.xForTime(note.timeOffset);
      final y = layout.yForString(note.string);
      final ringing = _isRinging(note);
      final selected = i == selectedIndex;

      if (selected) {
        canvas.drawCircle(
          Offset(x, y),
          16,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }

      final circlePaint = Paint()
        ..color = ringing ? Colors.orangeAccent : Colors.blueGrey.shade700;
      canvas.drawCircle(Offset(x, y), 12, circlePaint);

      final tp = TextPainter(
        text: TextSpan(
          text: '${note.fret}',
          style: TextStyle(
            color: ringing ? Colors.black : Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, y - tp.height / 2));
    }

    // Playhead.
    final playheadX = layout.xForTime(playhead);
    final playheadPaint = Paint()
      ..color = Colors.redAccent
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(playheadX, layout.topPadding - 20),
      Offset(playheadX, bottomY + 20),
      playheadPaint,
    );
  }

  @override
  bool shouldRepaint(covariant TabTimelinePainter oldDelegate) {
    return oldDelegate.notes != notes ||
        oldDelegate.playhead != playhead ||
        oldDelegate.selectedIndex != selectedIndex ||
        oldDelegate.highlightBeats != highlightBeats ||
        oldDelegate.beatsPerMeasure != beatsPerMeasure ||
        oldDelegate.bpm != bpm ||
        oldDelegate.totalSeconds != totalSeconds ||
        oldDelegate.windowStartSeconds != windowStartSeconds ||
        oldDelegate.windowEndSeconds != windowEndSeconds ||
        oldDelegate.layout != layout;
  }
}
