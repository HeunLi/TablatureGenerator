import 'package:flutter/material.dart';

import '../models/tab_note.dart';
import '../widgets/tab_timeline_layout.dart';

/// Renders the tab as a horizontally scrolling strip with a fixed playhead
/// at [playheadX] — the layout used for video export/overlay, as opposed to
/// [TabTimelinePainter]'s static, scrollable-by-the-user editor view.
class ScrollingTabPainter extends CustomPainter {
  ScrollingTabPainter({
    required this.notes,
    required this.currentTime,
    required this.pixelsPerSecond,
    required this.stringSpacing,
    required this.topPadding,
    required this.playheadX,
    required this.backgroundColor,
  });

  final List<TabNote> notes;
  final Duration currentTime;
  final double pixelsPerSecond;
  final double stringSpacing;
  final double topPadding;
  final double playheadX;
  final Color backgroundColor;

  static const _stringOrder = TabTimelineLayout.stringOrderTopToBottom;

  double _xForNoteTime(Duration noteTime) {
    final deltaSeconds =
        (noteTime - currentTime).inMicroseconds / Duration.microsecondsPerSecond;
    return playheadX + deltaSeconds * pixelsPerSecond;
  }

  double _yForString(BassString string) =>
      topPadding + _stringOrder.indexOf(string) * stringSpacing;

  bool _isRinging(TabNote note) {
    final start = note.timeOffset;
    final end = note.timeOffset + note.duration;
    return currentTime >= start && currentTime < end;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = backgroundColor);

    final bottomY = topPadding + (_stringOrder.length - 1) * stringSpacing;
    final linePaint = Paint()
      ..color = Colors.white54
      ..strokeWidth = 1;

    for (final string in _stringOrder) {
      final y = _yForString(string);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }

    for (final note in notes) {
      final x = _xForNoteTime(note.timeOffset);
      if (x < -20 || x > size.width + 20) continue;
      final y = _yForString(note.string);
      final ringing = _isRinging(note);

      canvas.drawCircle(
        Offset(x, y),
        14,
        Paint()..color = ringing ? Colors.orangeAccent : Colors.blueGrey.shade800,
      );

      final tp = TextPainter(
        text: TextSpan(
          text: '${note.fret}',
          style: TextStyle(
            color: ringing ? Colors.black : Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, y - tp.height / 2));
    }

    canvas.drawLine(
      Offset(playheadX, topPadding - 20),
      Offset(playheadX, bottomY + 20),
      Paint()
        ..color = Colors.redAccent
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant ScrollingTabPainter oldDelegate) =>
      oldDelegate.currentTime != currentTime || oldDelegate.notes != notes;
}
