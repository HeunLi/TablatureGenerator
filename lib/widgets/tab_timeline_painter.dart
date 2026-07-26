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
    this.selectedIndex,
  });

  final List<TabNote> notes;
  final TabTimelineLayout layout;
  final Duration playhead;
  final double bpm;
  final double totalSeconds;
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

    // Beat subdivision grid lines.
    final beatMs = 60000 / bpm;
    final gridMs = beatMs / 4;
    for (double ms = 0; ms <= totalSeconds * 1000; ms += gridMs) {
      final x = layout.xForTime(Duration(milliseconds: ms.round()));
      final isBeat = (ms % beatMs).abs() < 1 || (beatMs - ms % beatMs) < 1;
      canvas.drawLine(
        Offset(x, layout.topPadding - 10),
        Offset(x, bottomY + 10),
        isBeat ? linePaint : gridPaint,
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

    // Notes.
    for (var i = 0; i < notes.length; i++) {
      final note = notes[i];
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
        oldDelegate.layout != layout;
  }
}
