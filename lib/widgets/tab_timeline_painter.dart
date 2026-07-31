import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../audio/waveform_extractor.dart';
import '../models/tab_note.dart';
import '../models/tempo_map.dart';
import 'glass_panel.dart';
import 'tab_timeline_layout.dart';
import 'waveform_tile_cache.dart';

/// Keeps laid-out [ui.Paragraph]s around instead of building a fresh
/// `TextPainter` per label per frame.
///
/// Text layout is one of the more expensive things a `CustomPainter` can
/// do, and the timeline's labels are drawn from a tiny fixed vocabulary —
/// fret numbers 0–24 in two states, the four string names, and whatever
/// measure numbers are on screen — so essentially every layout after the
/// first few is redundant. Building a `TextPainter` per visible note on
/// every frame of a note drag was a real cost; a map lookup is not.
///
/// Owned by the timeline widget's `State` (not by a painter, which is
/// reconstructed on every rebuild) so the cache actually survives between
/// frames.
class TimelineTextCache {
  TimelineTextCache({this.maxEntries = 256});

  /// Bound on retained paragraphs. Only measure numbers can grow without
  /// limit (one per measure of a long track), and they're re-laid-out
  /// cheaply if an eviction turns out to have been premature.
  final int maxEntries;

  final _paragraphs = <String, ui.Paragraph>{};

  /// Fret numbers get a dedicated flat array rather than going through the
  /// keyed map: they're the only label drawn once per *note* per frame, so
  /// this is the one lookup worth making allocation-free (no key string to
  /// build, no hashing) — everything else is a handful of lookups a frame.
  /// Indexed `fret * 2 + (ringing ? 1 : 0)`.
  static const _maxFret = 24;
  final _fretLabels = List<ui.Paragraph?>.filled((_maxFret + 1) * 2, null);

  /// Fixed layout width for centred labels: wide enough for any label the
  /// timeline draws, so a single constraint works for all of them and the
  /// draw offset is a plain `x - width / 2`.
  static const centeredWidth = 64.0;

  static const _fretFontSize = 13.0;

  /// The fret number drawn inside a note circle. [ringing] picks the
  /// against-orange dark variant used while the playhead is inside the
  /// note's duration.
  ui.Paragraph fretLabel(int fret, {required bool ringing}) {
    final color = ringing ? Colors.black : Colors.white;
    if (fret < 0 || fret > _maxFret) {
      // Frets are clamped to 0..24 everywhere they're edited, so this is
      // only reachable via externally-authored project JSON.
      return label(
        '$fret',
        color: color,
        fontSize: _fretFontSize,
        fontWeight: FontWeight.bold,
      );
    }
    final index = fret * 2 + (ringing ? 1 : 0);
    return _fretLabels[index] ??= _build(
      '$fret',
      color: color,
      fontSize: _fretFontSize,
      fontWeight: FontWeight.bold,
      align: TextAlign.center,
      width: centeredWidth,
    );
  }

  ui.Paragraph label(
    String text, {
    required Color color,
    required double fontSize,
    FontWeight fontWeight = FontWeight.normal,
    TextAlign align = TextAlign.center,
    double width = centeredWidth,
  }) {
    final key = '$text|${color.toARGB32()}|$fontSize|${fontWeight.index}'
        '|${align.index}|$width';
    final cached = _paragraphs.remove(key);
    if (cached != null) {
      _paragraphs[key] = cached; // Re-inserted at the back: most recent.
      return cached;
    }
    while (_paragraphs.length >= maxEntries) {
      _paragraphs.remove(_paragraphs.keys.first)?.dispose();
    }
    final paragraph = _build(
      text,
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      align: align,
      width: width,
    );
    _paragraphs[key] = paragraph;
    return paragraph;
  }

  ui.Paragraph _build(
    String text, {
    required Color color,
    required double fontSize,
    required FontWeight fontWeight,
    required TextAlign align,
    required double width,
  }) {
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: align,
        fontSize: fontSize,
        fontWeight: fontWeight,
      ),
    )
      ..pushStyle(
        ui.TextStyle(color: color, fontSize: fontSize, fontWeight: fontWeight),
      )
      ..addText(text);
    return builder.build()..layout(ui.ParagraphConstraints(width: width));
  }

  void dispose() {
    for (final paragraph in _paragraphs.values) {
      paragraph.dispose();
    }
    _paragraphs.clear();
    for (final paragraph in _fretLabels) {
      paragraph?.dispose();
    }
    _fretLabels.fillRange(0, _fretLabels.length, null);
  }
}

/// Shared plumbing for the timeline's two layers.
///
/// Both paint into a **viewport-sized** canvas that they translate by the
/// current scroll offset, rather than into a canvas as wide as the whole
/// track. That distinction is the single biggest thing separating this from
/// the version that lagged: a track-sized canvas makes the rasterized area
/// (and the buffered slice of content that has to be built to fill it)
/// scale with track length and zoom, so a multi-minute MP3 at a high BPM
/// was asking the rasterizer for tens of thousands of pixels of width every
/// frame to show ~1400 of them. Here, cost is bounded by the viewport and
/// is flat in track length, zoom, and note count outside the viewport.
///
/// Repaints are driven by [Listenable]s passed to `super.repaint` rather
/// than by rebuilding the widget tree: a scroll or a playhead tick marks
/// the relevant layer for repaint directly, without a `setState`, so
/// neither one rebuilds a single widget.
abstract class _TimelineLayerPainter extends CustomPainter {
  _TimelineLayerPainter({
    required this.scrollOffset,
    required this.layout,
    required this.textCache,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final ValueListenable<double> scrollOffset;
  final TabTimelineLayout layout;
  final TimelineTextCache textCache;

  /// Slack (in logical pixels) painted beyond each edge of the viewport, so
  /// content whose anchor point sits just off-screen — a note circle, a
  /// measure number — isn't clipped away mid-glyph as it scrolls in.
  static const _overdraw = 32.0;

  /// Applies the scroll translation and returns the content-x range that
  /// is (or nearly is) on screen. Everything downstream works in content
  /// coordinates, exactly like `TabTimelineLayout`'s time->pixel math and
  /// the gesture handlers' hit testing, so there is only ever one
  /// coordinate space to reason about.
  (double, double) _enterContentSpace(Canvas canvas, Size size) {
    final offset = scrollOffset.value;
    canvas.translate(-offset, 0);
    return (offset - _overdraw, offset + size.width + _overdraw);
  }
}

/// The timeline's slow-changing layer: beat/measure grid, measure numbers,
/// string lines and names, the amber highlight block, and the waveform
/// strip.
///
/// None of this depends on the playhead's exact position or on where notes
/// are, so it is deliberately kept off the per-frame path: during steady
/// playback it repaints only when the highlight block advances to the next
/// beat block (seconds apart, not 60x/sec), and during a note drag it does
/// not repaint at all. Because it also sits behind its own
/// `RepaintBoundary` and is marked `isComplex`/`!willChange`, the engine
/// can hold its rasterization in the raster cache across the many frames
/// where nothing here changed.
class TabTimelineBackdropPainter extends _TimelineLayerPainter {
  TabTimelineBackdropPainter({
    required super.scrollOffset,
    required super.layout,
    required super.textCache,
    required this.highlightBounds,
    required this.waveform,
    required this.waveformTiles,
    required this.devicePixelRatio,
    required this.tempo,
    required this.subdivisionsPerBeat,
    required this.loopRegion,
    required this.totalSeconds,
    required this.audioLoaded,
  }) : super(
          repaint: Listenable.merge([
            scrollOffset,
            highlightBounds,
            waveform,
            loopRegion,
          ]),
        );

  /// Start/end seconds of the beat block currently lit up. Notified only
  /// when the block actually changes, not on every playhead tick — see the
  /// class doc.
  final ValueListenable<(double, double)> highlightBounds;

  final ValueListenable<WaveformData?> waveform;
  final WaveformTileCache waveformTiles;
  final double devicePixelRatio;

  /// Drives where every grid line falls. Grid spacing is no longer uniform
  /// across the track — a slower section has visibly wider beats, since the
  /// x axis stays linear in *time* so the waveform underneath it stays
  /// honest. See [TempoMap].
  final TempoMap tempo;

  /// Grid resolution, matching whatever the snap setting is — drawing a
  /// finer grid than notes can actually land on is just noise, and drawing
  /// a coarser one hides where they'll go.
  final int subdivisionsPerBeat;

  /// The A/B loop range in seconds, or null when no loop is set. Shaded
  /// across the full timeline height so it's readable at a glance without
  /// hunting for bracket markers.
  final ValueListenable<(double, double)?> loopRegion;

  final double totalSeconds;

  /// Distinguishes "no audio loaded" from "audio loaded, waveform still
  /// decoding" for the placeholder shown while [waveform] is null.
  final bool audioLoaded;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    final (visibleLeft, visibleRight) = _enterContentSpace(canvas, size);

    _paintHighlightBlock(canvas);
    _paintGrid(canvas, visibleLeft, visibleRight);
    _paintTempoMarkers(canvas, visibleLeft, visibleRight);
    _paintStrings(canvas, visibleLeft, visibleRight);
    _paintWaveform(canvas, visibleLeft, visibleRight);
    // Last, so it actually dims what it's drawn over. Notes and the
    // playhead live on the layer above and stay at full contrast, which is
    // what you want: the loop shades the *material* you're working against,
    // not the work.
    _paintLoopRegion(canvas, size);

    canvas.restore();
  }

  /// Dims everything *outside* the loop rather than tinting what's inside:
  /// the loop region is where the work is happening, so it should read as
  /// the normal, un-messed-with colour, with the rest pushed back.
  void _paintLoopRegion(Canvas canvas, Size size) {
    final region = loopRegion.value;
    if (region == null) return;
    final (start, end) = region;
    if (end <= start) return;

    final startX = layout.leftPadding + start * layout.pixelsPerSecond;
    final endX = layout.leftPadding + end * layout.pixelsPerSecond;
    final offset = scrollOffset.value;
    final dim = Paint()..color = const Color(0x4D000000);
    canvas
      ..drawRect(Rect.fromLTRB(offset, 0, startX, size.height), dim)
      ..drawRect(
        Rect.fromLTRB(endX, 0, offset + size.width, size.height),
        dim,
      );

    final edge = Paint()
      ..color = accentColor.withValues(alpha: 0.9)
      ..strokeWidth = 2;
    canvas
      ..drawLine(Offset(startX, 0), Offset(startX, size.height), edge)
      ..drawLine(Offset(endX, 0), Offset(endX, size.height), edge);
  }

  void _paintHighlightBlock(Canvas canvas) {
    final (blockStart, blockEnd) = highlightBounds.value;
    if (blockEnd <= blockStart) return;
    canvas.drawRect(
      Rect.fromLTRB(
        layout.leftPadding + blockStart * layout.pixelsPerSecond,
        layout.topPadding - 16,
        layout.leftPadding + blockEnd * layout.pixelsPerSecond,
        layout.bottomY + 16,
      ),
      Paint()..color = const Color(0x59FFEB3B), // amber @ ~35% opacity
    );
  }

  void _paintGrid(Canvas canvas, double visibleLeft, double visibleRight) {
    final startSeconds =
        ((visibleLeft - layout.leftPadding) / layout.pixelsPerSecond)
            .clamp(0.0, double.infinity);
    final endSeconds =
        ((visibleRight - layout.leftPadding) / layout.pixelsPerSecond)
            .clamp(0.0, totalSeconds);
    if (endSeconds < startSeconds) return;

    final beatPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..strokeWidth = 1;
    final subdivisionPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.07)
      ..strokeWidth = 1;
    final measurePaint = Paint()
      ..color = accentColor.withValues(alpha: 0.55)
      ..strokeWidth = 1.5;

    final top = layout.topPadding - 10;
    final bottom = layout.bottomY + 10;

    // Line positions come from the tempo map rather than a uniform step, so
    // the grid tracks tempo and meter changes. The callback form keeps this
    // allocation-free on a path that runs every scrolled frame.
    tempo.visitGridLines(
      startSeconds,
      endSeconds,
      subdivisionsPerBeat: subdivisionsPerBeat,
      visit: (seconds, isBeat, isMeasure, measureNumber) {
        final x = layout.leftPadding + seconds * layout.pixelsPerSecond;
        canvas.drawLine(
          Offset(x, top),
          Offset(x, bottom),
          isMeasure ? measurePaint : (isBeat ? beatPaint : subdivisionPaint),
        );

        // Measure number, drawn above the grid so it stays obvious which
        // measure you're looking at while scrolled deep into a long track.
        // Null for pick-up bars before the first downbeat, which have no
        // meaningful number.
        if (measureNumber == null) return;
        final paragraph = textCache.label(
          '$measureNumber',
          color: accentColor.withValues(alpha: 0.85),
          fontSize: 11,
          fontWeight: FontWeight.w600,
        );
        canvas.drawParagraph(
          paragraph,
          Offset(x - TimelineTextCache.centeredWidth / 2, 4),
        );
      },
    );
  }

  /// Draws a flag at each tempo/meter change so the tempo track is visible
  /// on the timeline itself, not just in a dialog — you need to see *where*
  /// a section changes while listening to it, which is the whole point of
  /// being able to place one.
  void _paintTempoMarkers(
    Canvas canvas,
    double visibleLeft,
    double visibleRight,
  ) {
    final labelTop = layout.markerLabelTop;
    final chipPaint = Paint()..color = accentColor.withValues(alpha: 0.85);
    final stemPaint = Paint()
      ..color = accentColor
      ..strokeWidth = 2;

    for (final marker in tempo.markers) {
      final seconds =
          marker.time.inMicroseconds / Duration.microsecondsPerSecond;
      final x = layout.leftPadding + seconds * layout.pixelsPerSecond;
      if (x < visibleLeft - 90 || x > visibleRight) continue;

      canvas.drawLine(
        Offset(x, labelTop),
        Offset(x, layout.bottomY + 10),
        stemPaint,
      );

      final text = '${_formatBpm(marker.bpm)} · ${marker.beatsPerMeasure}/4';
      final paragraph = textCache.label(
        text,
        color: Colors.black,
        fontSize: 10,
        fontWeight: FontWeight.w700,
        align: TextAlign.left,
        width: 96,
      );
      final width = paragraph.longestLine + 10;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, labelTop, width, layout.markerLabelHeight),
          const Radius.circular(3),
        ),
        chipPaint,
      );
      canvas.drawParagraph(
        paragraph,
        Offset(x + 5, labelTop + (layout.markerLabelHeight - paragraph.height) / 2),
      );
    }
  }

  static String _formatBpm(double bpm) =>
      bpm == bpm.roundToDouble() ? bpm.toStringAsFixed(0) : bpm.toStringAsFixed(1);

  void _paintStrings(Canvas canvas, double visibleLeft, double visibleRight) {
    const labels = {
      BassString.g: 'G',
      BassString.d: 'D',
      BassString.a: 'A',
      BassString.e: 'E',
    };
    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..strokeWidth = 1;
    final lineStart = visibleLeft > layout.leftPadding
        ? visibleLeft
        : layout.leftPadding;
    // The string names live at the very start of the track, so once
    // scrolled past them there is nothing to lay out or draw.
    final labelsVisible = visibleLeft <= 12 + TimelineTextCache.centeredWidth;

    for (final string in TabTimelineLayout.stringOrderTopToBottom) {
      final y = layout.yForString(string);
      canvas.drawLine(
        Offset(lineStart, y),
        Offset(visibleRight, y),
        linePaint,
      );
      if (!labelsVisible) continue;
      final paragraph = textCache.label(
        labels[string]!,
        color: Colors.white70,
        fontSize: 14,
        align: TextAlign.left,
      );
      canvas.drawParagraph(paragraph, Offset(12, y - paragraph.height / 2));
    }
  }

  void _paintWaveform(Canvas canvas, double visibleLeft, double visibleRight) {
    final midY = layout.waveformTop + TabTimelineLayout.waveformHeight / 2;
    final data = waveform.value;

    if (data == null || data.isEmpty) {
      if (visibleLeft > layout.leftPadding + 200) return;
      final paragraph = textCache.label(
        audioLoaded ? 'Decoding waveform…' : 'No audio loaded',
        color: Colors.white.withValues(alpha: 0.3),
        fontSize: 12,
        align: TextAlign.left,
        width: 200,
      );
      canvas.drawParagraph(
        paragraph,
        Offset(layout.leftPadding, midY - paragraph.height / 2),
      );
      return;
    }

    canvas.drawLine(
      Offset(
        visibleLeft > layout.leftPadding ? visibleLeft : layout.leftPadding,
        midY,
      ),
      Offset(visibleRight, midY),
      Paint()..color = Colors.white.withValues(alpha: 0.08),
    );
    waveformTiles.paint(
      canvas,
      waveform: data,
      layout: layout,
      devicePixelRatio: devicePixelRatio,
      color: accentColor.withValues(alpha: 0.55),
      fromX: visibleLeft,
      toX: visibleRight,
    );
  }

  @override
  bool shouldRepaint(covariant TabTimelineBackdropPainter oldDelegate) {
    return oldDelegate.layout != layout ||
        oldDelegate.tempo != tempo ||
        oldDelegate.subdivisionsPerBeat != subdivisionsPerBeat ||
        oldDelegate.totalSeconds != totalSeconds ||
        oldDelegate.audioLoaded != audioLoaded ||
        oldDelegate.devicePixelRatio != devicePixelRatio;
  }
}

/// The timeline's per-frame layer: notes, the selection rings, and the
/// playhead.
///
/// Everything here genuinely changes often — notes light up as the playhead
/// passes through them, so they can't be cached against the playhead the
/// way the backdrop is — but the work is bounded by *visible* note count,
/// and every label it draws comes out of [TimelineTextCache]. Isolating it
/// behind its own `RepaintBoundary` is what lets a playhead tick or a drag
/// frame repaint a handful of circles instead of the grid and waveform too.
class TabTimelineForegroundPainter extends _TimelineLayerPainter {
  TabTimelineForegroundPainter({
    required super.scrollOffset,
    required super.layout,
    required super.textCache,
    required this.notes,
    required this.selection,
    required this.playhead,
  }) : super(
          repaint: Listenable.merge([scrollOffset, notes, selection, playhead]),
        );

  final ValueListenable<List<TabNote>> notes;
  final ValueListenable<Set<int>> selection;
  final ValueListenable<Duration> playhead;

  static const _noteRadius = 12.0;
  static const _selectionRadius = 16.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    final (visibleLeft, visibleRight) = _enterContentSpace(canvas, size);

    _paintNotes(canvas, visibleLeft, visibleRight);
    _paintPlayhead(canvas);

    canvas.restore();
  }

  void _paintNotes(Canvas canvas, double visibleLeft, double visibleRight) {
    final noteList = notes.value;
    final selected = selection.value;
    final now = playhead.value;

    // Culling in *time* rather than pixels lets the comparison happen
    // against each note's stored offset directly, with no per-note pixel
    // conversion for the (usually large) majority that are off-screen.
    final fromSeconds =
        (visibleLeft - _noteRadius - layout.leftPadding) / layout.pixelsPerSecond;
    final toSeconds =
        (visibleRight + _noteRadius - layout.leftPadding) / layout.pixelsPerSecond;

    final selectionPaint = Paint()
      ..color = accentColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final idlePaint = Paint()..color = const Color(0xFF3A3D52);
    final ringingPaint = Paint()..color = Colors.orangeAccent;

    for (var i = 0; i < noteList.length; i++) {
      final note = noteList[i];
      final seconds =
          note.timeOffset.inMicroseconds / Duration.microsecondsPerSecond;
      if (seconds < fromSeconds || seconds > toSeconds) continue;

      final x = layout.leftPadding + seconds * layout.pixelsPerSecond;
      final y = layout.yForString(note.string);
      final ringing =
          now >= note.timeOffset && now < note.timeOffset + note.duration;

      if (selected.contains(i)) {
        canvas.drawCircle(Offset(x, y), _selectionRadius, selectionPaint);
      }
      canvas.drawCircle(
        Offset(x, y),
        _noteRadius,
        ringing ? ringingPaint : idlePaint,
      );

      final paragraph = textCache.fretLabel(note.fret, ringing: ringing);
      canvas.drawParagraph(
        paragraph,
        Offset(
          x - TimelineTextCache.centeredWidth / 2,
          y - paragraph.height / 2,
        ),
      );
    }
  }

  /// Extends down through the waveform strip too, so it's obvious where
  /// playback sits relative to the waveform, not just relative to the
  /// notes.
  void _paintPlayhead(Canvas canvas) {
    final x = layout.xForTime(playhead.value);
    canvas.drawLine(
      Offset(x, layout.topPadding - 20),
      Offset(x, layout.waveformBottom),
      Paint()
        ..color = Colors.redAccent
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant TabTimelineForegroundPainter oldDelegate) =>
      oldDelegate.layout != layout;
}
