import 'dart:js_interop';
import 'dart:math' as math;

import 'package:web/web.dart' as web;

import '../models/tab_note.dart';
import '../widgets/tab_timeline_layout.dart';

/// Draws a single export frame straight onto a native `<canvas>` 2D
/// context using the browser's own Canvas API, instead of going through
/// Flutter's `dart:ui` rendering + GPU readback.
///
/// Layout is a **static, paginated** tab: only [measuresPerWindow]
/// measures are visible at once, positioned at a fixed, legible spacing.
/// Once playback moves past the last measure in the current window, the
/// whole frame jumps to the next window of measures — rather than trying
/// to cram the entire clip into one frame (illegibly squished for
/// anything longer than a few measures) or continuously scrolling
/// (expensive for the video encoder to predict). Within a window, nothing
/// moves except the highlight block/playhead, so frames stay nearly
/// identical to the previous one — cheap for VP8 to encode — and only pay
/// the "whole frame changed" cost at the infrequent window boundaries.
///
/// A `VideoFrame` can be built directly from an `HTMLCanvasElement` with
/// no CPU-side pixel copy at all, whereas painting via a Flutter
/// `CustomPainter` requires rasterizing to a `ui.Image` and reading its
/// pixels back from the GPU on every frame — that readback was the
/// original export bottleneck, this sidesteps it entirely.
class CanvasTabRenderer {
  CanvasTabRenderer({
    required this.ctx,
    required this.width,
    required this.height,
    required this.pixelsPerSecond,
    required this.stringSpacing,
    required this.topPadding,
    required this.leftPadding,
    required this.bpm,
    required this.totalDuration,
    required this.backgroundColor,
    this.measuresPerWindow = 6,
    this.beatsPerMeasure = 4,
    this.highlightBeats = 4,
    this.showPlayhead = true,
  });

  final web.CanvasRenderingContext2D ctx;
  final int width;
  final int height;
  final double pixelsPerSecond;
  final double stringSpacing;
  final double topPadding;
  final double leftPadding;
  final double bpm;
  final Duration totalDuration;
  final String backgroundColor; // CSS color string, e.g. '#00B140'
  final int measuresPerWindow;

  /// Time signature numerator — how many beats make up a measure for
  /// pagination purposes (matches the project's actual time signature
  /// instead of assuming 4/4).
  final int beatsPerMeasure;

  /// How many beats light up together as one highlight block. Independent
  /// of [beatsPerMeasure] — a 3/4 song might want exactly 3 beats
  /// highlighted, not a fixed measure width.
  final int highlightBeats;

  /// Whether to draw the thin sweeping playhead line. The amber
  /// beat-highlight block is drawn either way — some users find just the
  /// line distracting, but still want the highlight block to show which
  /// beats are current.
  final bool showPlayhead;

  static const _stringOrder = TabTimelineLayout.stringOrderTopToBottom;

  /// Perceived luminance (0=black, 1=white) of [backgroundColor], used to
  /// pick a readable foreground for string lines/fret text/labels — a
  /// hardcoded dark foreground (fine for the original bright chroma-green
  /// default) would be invisible against a dark background color.
  double get _backgroundLuminance {
    final hex = backgroundColor.replaceFirst('#', '');
    if (hex.length != 6) return 1.0;
    final r = int.parse(hex.substring(0, 2), radix: 16) / 255;
    final g = int.parse(hex.substring(2, 4), radix: 16) / 255;
    final b = int.parse(hex.substring(4, 6), radix: 16) / 255;
    return 0.299 * r + 0.587 * g + 0.114 * b;
  }

  bool get _isDarkBackground => _backgroundLuminance <= 0.5;

  String get _foregroundColor => _isDarkBackground ? '#F5F5F5' : '#1A1A1A';
  String get _foregroundColorMuted => _isDarkBackground
      ? 'rgba(255, 255, 255, 0.65)'
      : 'rgba(0, 0, 0, 0.55)';

  double get _bottomY =>
      topPadding + (_stringOrder.length - 1) * stringSpacing;

  double get _measureDurationSeconds => beatsPerMeasure * 60 / bpm;
  double get _windowDurationSeconds =>
      _measureDurationSeconds * measuresPerWindow;

  double _currentMeasureIndex(Duration time) {
    final seconds = time.inMicroseconds / Duration.microsecondsPerSecond;
    return (seconds / _measureDurationSeconds).floorToDouble();
  }

  double _windowStartSeconds(Duration currentTime) {
    final measureIndex = _currentMeasureIndex(currentTime).toInt();
    final windowIndex = measureIndex ~/ measuresPerWindow;
    return windowIndex * _windowDurationSeconds;
  }

  double _yForString(BassString string) =>
      topPadding + _stringOrder.indexOf(string) * stringSpacing;

  double _xForTime(double secondsSinceWindowStart) =>
      leftPadding + secondsSinceWindowStart * pixelsPerSecond;

  double _xForNoteTime(Duration noteTime, double windowStart) {
    final seconds = noteTime.inMicroseconds / Duration.microsecondsPerSecond;
    return _xForTime(seconds - windowStart);
  }

  void drawFrame(List<TabNote> notes, Duration currentTime) {
    final windowStart = _windowStartSeconds(currentTime);

    ctx.fillStyle = backgroundColor.toJS;
    ctx.fillRect(0, 0, width, height);

    _drawMeasureHighlight(currentTime, windowStart);
    _drawStringLines();
    _drawNotes(notes, windowStart);
    if (showPlayhead) _drawPlayhead(currentTime, windowStart);
    _drawWindowLabel(currentTime);
  }

  void _drawMeasureHighlight(Duration currentTime, double windowStart) {
    final (blockStart, blockEnd) = TabTimelineLayout.beatBlockBoundsSeconds(
      currentTime,
      bpm,
      highlightBeats,
    );
    if (blockEnd <= blockStart) return;

    final x0 = _xForTime(blockStart - windowStart);
    final x1 = _xForTime(blockEnd - windowStart);

    ctx.fillStyle = 'rgba(255, 235, 59, 0.35)'.toJS;
    ctx.fillRect(x0, topPadding - 16, x1 - x0, _bottomY - topPadding + 32);
  }

  void _drawStringLines() {
    ctx.strokeStyle = _foregroundColorMuted.toJS;
    ctx.lineWidth = 1;
    for (final string in _stringOrder) {
      final y = _yForString(string);
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(width.toDouble(), y);
      ctx.stroke();
    }
  }

  void _drawNotes(List<TabNote> notes, double windowStart) {
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.font = 'bold 15px sans-serif';

    for (final note in notes) {
      final x = _xForNoteTime(note.timeOffset, windowStart);
      if (x < -20 || x > width + 20) continue;
      final y = _yForString(note.string);

      // Blank out the string line under the digit so it reads clearly,
      // same convention as printed tab.
      ctx.fillStyle = backgroundColor.toJS;
      ctx.beginPath();
      ctx.arc(x, y, 10, 0, 2 * math.pi);
      ctx.fill();

      ctx.fillStyle = _foregroundColor.toJS;
      ctx.fillText('${note.fret}', x, y + 1);
    }
  }

  void _drawPlayhead(Duration currentTime, double windowStart) {
    final seconds =
        currentTime.inMicroseconds / Duration.microsecondsPerSecond;
    final x = _xForTime(seconds - windowStart);
    ctx.strokeStyle = '#3949AB'.toJS;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(x, topPadding - 16);
    ctx.lineTo(x, _bottomY + 16);
    ctx.stroke();
  }

  void _drawWindowLabel(Duration currentTime) {
    final measureIndex = _currentMeasureIndex(currentTime).toInt();
    final windowNumber = measureIndex ~/ measuresPerWindow + 1;
    final totalWindows =
        ((totalDuration.inMicroseconds / Duration.microsecondsPerSecond) /
                    _windowDurationSeconds)
                .ceil()
                .clamp(1, 1 << 30);

    ctx.textAlign = 'right';
    ctx.textBaseline = 'alphabetic';
    ctx.font = '12px sans-serif';
    ctx.fillStyle = _foregroundColorMuted.toJS;
    ctx.fillText('$windowNumber / $totalWindows', width - 12, 20);
  }
}
