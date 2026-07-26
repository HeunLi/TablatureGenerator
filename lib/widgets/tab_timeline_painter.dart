import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../audio/waveform_extractor.dart';
import '../models/tab_note.dart';
import 'glass_panel.dart';
import 'tab_timeline_layout.dart';

/// Caches the waveform preview strip as a recorded [ui.Picture] so
/// [TabTimelinePainter] doesn't have to rebuild it from scratch on every
/// single playhead tick during playback (~60/sec via the interpolating
/// `Ticker` — see `StudioScreen`). The waveform bars themselves only
/// actually change when the buffered window scrolls, the zoom (BPM)
/// changes, or the waveform data itself changes (new audio decoded) — not
/// when the playhead moves — so a cache keyed on those inputs turns
/// "rebuild ~2000 pixel columns of bucket lookups + Path construction" into
/// "one cheap `canvas.drawPicture` call" for every frame where only the
/// playhead moved, which during steady playback with no scrolling is
/// nearly every frame.
///
/// Owned by `_StudioScreenState` (one instance, created once) rather than
/// by [TabTimelinePainter] itself, since a fresh painter instance is
/// constructed on every rebuild (each `ValueListenableBuilder` playhead
/// tick) — a cache field on the painter wouldn't survive between frames.
class WaveformPictureCache {
  ui.Picture? _picture;
  double? _windowStartSeconds;
  double? _windowEndSeconds;
  double? _pixelsPerSecond;
  double? _waveformTop;
  WaveformData? _waveform;

  ui.Picture? get({
    required double windowStartSeconds,
    required double windowEndSeconds,
    required double pixelsPerSecond,
    required double waveformTop,
    required WaveformData waveform,
  }) {
    if (_picture != null &&
        _windowStartSeconds == windowStartSeconds &&
        _windowEndSeconds == windowEndSeconds &&
        _pixelsPerSecond == pixelsPerSecond &&
        _waveformTop == waveformTop &&
        identical(_waveform, waveform)) {
      return _picture;
    }
    return null;
  }

  void store(
    ui.Picture picture, {
    required double windowStartSeconds,
    required double windowEndSeconds,
    required double pixelsPerSecond,
    required double waveformTop,
    required WaveformData waveform,
  }) {
    _picture?.dispose();
    _picture = picture;
    _windowStartSeconds = windowStartSeconds;
    _windowEndSeconds = windowEndSeconds;
    _pixelsPerSecond = pixelsPerSecond;
    _waveformTop = waveformTop;
    _waveform = waveform;
  }

  void dispose() {
    _picture?.dispose();
    _picture = null;
  }
}

/// Caches the beat/measure grid (lines + per-measure number labels) and
/// the string lines/labels as a recorded [ui.Picture] — same idea and same
/// reason as [WaveformPictureCache], for a cost that turned out to matter
/// even more in practice: none of this content depends on the *notes* at
/// all, but `TabTimelinePainter.paint()` runs on every note-drag update too
/// (`shouldRepaint` returns true whenever the `notes` list changes, which
/// it does on every pointer-move frame of a drag) — without this cache, a
/// fully static grid (potentially a couple hundred lines across a buffered
/// window, several with their own `TextPainter` for the measure number)
/// was being rebuilt from scratch on every single frame of a note drag,
/// not just every playhead tick.
class GridPictureCache {
  ui.Picture? _picture;
  double? _windowStartSeconds;
  double? _windowEndSeconds;
  double? _bpm;
  int? _beatsPerMeasure;
  TabTimelineLayout? _layout;
  double? _canvasWidth;

  ui.Picture? get({
    required double windowStartSeconds,
    required double windowEndSeconds,
    required double bpm,
    required int beatsPerMeasure,
    required TabTimelineLayout layout,
    required double canvasWidth,
  }) {
    if (_picture != null &&
        _windowStartSeconds == windowStartSeconds &&
        _windowEndSeconds == windowEndSeconds &&
        _bpm == bpm &&
        _beatsPerMeasure == beatsPerMeasure &&
        _layout == layout &&
        _canvasWidth == canvasWidth) {
      return _picture;
    }
    return null;
  }

  void store(
    ui.Picture picture, {
    required double windowStartSeconds,
    required double windowEndSeconds,
    required double bpm,
    required int beatsPerMeasure,
    required TabTimelineLayout layout,
    required double canvasWidth,
  }) {
    _picture?.dispose();
    _picture = picture;
    _windowStartSeconds = windowStartSeconds;
    _windowEndSeconds = windowEndSeconds;
    _bpm = bpm;
    _beatsPerMeasure = beatsPerMeasure;
    _layout = layout;
    _canvasWidth = canvasWidth;
  }

  void dispose() {
    _picture?.dispose();
    _picture = null;
  }
}

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
    this.selectedIndices = const {},
    this.windowStartSeconds = 0,
    this.waveform,
    this.audioLoaded = false,
    this.waveformCache,
    this.gridCache,
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

  final Set<int> selectedIndices;

  /// Precomputed peak buckets for the waveform preview strip drawn beneath
  /// the string lines — null while no audio is loaded, or while it's still
  /// being decoded/extracted (see `StudioScreen._extractWaveform`).
  final WaveformData? waveform;

  /// Distinguishes "no audio loaded" from "audio loaded, waveform still
  /// decoding" for the placeholder text shown when [waveform] is null.
  final bool audioLoaded;

  /// Optional cache for the recorded waveform [ui.Picture] — see
  /// [WaveformPictureCache]. Null falls back to rebuilding the waveform
  /// path directly every paint (correct, just not cheap on every frame).
  final WaveformPictureCache? waveformCache;

  /// Optional cache for the recorded grid/string-lines [ui.Picture] — see
  /// [GridPictureCache]. Null falls back to rebuilding the grid directly
  /// every paint (correct, just not cheap on every frame).
  final GridPictureCache? gridCache;

  static const _waveformHeight = 56.0;
  static const _waveformGapAboveBottomY = 30.0;

  bool _isRinging(TabNote note) {
    final start = note.timeOffset;
    final end = note.timeOffset + note.duration;
    return playhead >= start && playhead < end;
  }

  @override
  void paint(Canvas canvas, Size size) {
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

    // Beat/measure grid + string lines/labels — entirely independent of
    // `notes`, but this paint() call runs on every note-drag update too
    // (shouldRepaint triggers on `notes` changes), so this is cached the
    // same way as the waveform (see GridPictureCache) rather than rebuilt
    // — potentially a couple hundred lines plus a TextPainter per measure
    // — on every single drag frame.
    final gridCached = gridCache?.get(
      windowStartSeconds: windowStartSeconds,
      windowEndSeconds: windowEndSeconds,
      bpm: bpm,
      beatsPerMeasure: beatsPerMeasure,
      layout: layout,
      canvasWidth: size.width,
    );
    if (gridCached != null) {
      canvas.drawPicture(gridCached);
    } else {
      final recorder = ui.PictureRecorder();
      _paintGridAndStrings(Canvas(recorder), bottomY, size.width);
      final picture = recorder.endRecording();
      gridCache?.store(
        picture,
        windowStartSeconds: windowStartSeconds,
        windowEndSeconds: windowEndSeconds,
        bpm: bpm,
        beatsPerMeasure: beatsPerMeasure,
        layout: layout,
        canvasWidth: size.width,
      );
      canvas.drawPicture(picture);
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
      final selected = selectedIndices.contains(i);

      if (selected) {
        canvas.drawCircle(
          Offset(x, y),
          16,
          Paint()
            ..color = accentColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }

      final circlePaint = Paint()
        ..color = ringing ? Colors.orangeAccent : const Color(0xFF3A3D52);
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

    // Waveform preview strip, drawn beneath the string lines using the
    // same time->pixel mapping as everything else (via layout.xForTime),
    // so it scrolls and rescales in lockstep with the notes/grid rather
    // than needing a separately-synced scroll view. One vertical bar per
    // screen pixel — not per waveform bucket — bounds its cost to roughly
    // "viewport width" regardless of how finely [waveform] was sampled or
    // how long the track is, matching the buffered-window discipline used
    // everywhere else in this painter.
    final waveformTop = bottomY + _waveformGapAboveBottomY;
    final waveformBottom = waveformTop + _waveformHeight;
    final waveformMidY = waveformTop + _waveformHeight / 2;
    final waveform = this.waveform;
    if (waveform != null && waveform.bucketCount > 0) {
      // Rebuilding the bars (bucket lookups + Path construction across
      // potentially ~2000 pixel columns) on every single playhead tick was
      // still measurably costly even after batching into one Path/drawPath
      // (see WaveformPictureCache doc) — the playhead moving doesn't change
      // the bars at all, only scrolling/zoom/new-audio does. So: reuse a
      // cached recording keyed on those inputs when possible, and only
      // pay the rebuild cost when something that actually changes the bars
      // has changed.
      final cached = waveformCache?.get(
        windowStartSeconds: windowStartSeconds,
        windowEndSeconds: windowEndSeconds,
        pixelsPerSecond: layout.pixelsPerSecond,
        waveformTop: waveformTop,
        waveform: waveform,
      );
      if (cached != null) {
        canvas.drawPicture(cached);
      } else {
        final recorder = ui.PictureRecorder();
        _paintWaveformBars(
          Canvas(recorder),
          waveform,
          waveformMidY,
          size.width,
        );
        final picture = recorder.endRecording();
        waveformCache?.store(
          picture,
          windowStartSeconds: windowStartSeconds,
          windowEndSeconds: windowEndSeconds,
          pixelsPerSecond: layout.pixelsPerSecond,
          waveformTop: waveformTop,
          waveform: waveform,
        );
        canvas.drawPicture(picture);
      }
    } else {
      final tp = TextPainter(
        text: TextSpan(
          text: audioLoaded ? 'Decoding waveform…' : 'No audio loaded',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.3),
            fontSize: 12,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(layout.leftPadding, waveformMidY - tp.height / 2),
      );
    }

    // Playhead. Extends down through the waveform strip too, so it's
    // obvious where playback currently sits relative to the waveform, not
    // just relative to the notes.
    final playheadX = layout.xForTime(playhead);
    final playheadPaint = Paint()
      ..color = Colors.redAccent
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(playheadX, layout.topPadding - 20),
      Offset(playheadX, waveformBottom),
      playheadPaint,
    );
  }

  /// Draws the beat/measure grid (with per-measure number labels) and the
  /// string lines/labels onto [canvas] — either the real timeline canvas
  /// (when [gridCache] is null) or a throwaway recording [Canvas] backed
  /// by a [ui.PictureRecorder], whose result then gets cached (see
  /// [GridPictureCache]). Entirely independent of [notes]/[selectedIndices]
  /// /[playhead] — everything drawn here only depends on the buffered
  /// window, tempo, and time signature.
  void _paintGridAndStrings(Canvas canvas, double bottomY, double canvasWidth) {
    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..strokeWidth = 1;
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.07)
      ..strokeWidth = 1;

    // Beat subdivision grid lines; a brighter line marks each measure
    // boundary (every beatsPerMeasure beats), matching the project's
    // actual time signature instead of assuming 4/4. Bounded to the
    // buffered visible window (see [windowStartSeconds]) rather than the
    // whole track.
    final beatMs = 60000 / bpm;
    final gridMs = beatMs / 4;
    final measurePaint = Paint()
      ..color = accentColor.withValues(alpha: 0.55)
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

      // Measure number, drawn above the grid at each measure boundary so
      // it's obvious which measure you're looking at while scrolled deep
      // into a long track — easy to lose track of otherwise since nothing
      // else on the timeline is numbered.
      if (isMeasureLine) {
        final measureNumber = beatIndex ~/ beatsPerMeasure + 1;
        final tp = TextPainter(
          text: TextSpan(
            text: '$measureNumber',
            style: TextStyle(
              color: accentColor.withValues(alpha: 0.85),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x - tp.width / 2, 4));
      }
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
        Offset(canvasWidth, y),
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
  }

  /// Draws the waveform baseline + bars onto [canvas] — either the real
  /// timeline canvas (when [waveformCache] is null) or a throwaway
  /// recording [Canvas] backed by a [ui.PictureRecorder], whose result
  /// then gets cached (see [WaveformPictureCache]). One vertical bar per
  /// screen pixel, not per waveform bucket — bounds cost to roughly
  /// "viewport width" regardless of how finely [waveform] was sampled or
  /// how long the track is, matching the buffered-window discipline used
  /// everywhere else in this painter. Batched into a single `Path` +
  /// `drawPath` call rather than one `drawLine` per pixel — far fewer
  /// draw-call submissions for the same visual output (note: `drawPath`
  /// respects `Paint.style`, unlike `drawLine`, which always strokes
  /// regardless — the stroke style below is required, not cosmetic).
  void _paintWaveformBars(
    Canvas canvas,
    WaveformData waveform,
    double waveformMidY,
    double canvasWidth,
  ) {
    canvas.drawLine(
      Offset(layout.leftPadding, waveformMidY),
      Offset(canvasWidth, waveformMidY),
      Paint()..color = Colors.white.withValues(alpha: 0.08),
    );
    final startX = layout.xForTime(
      Duration(microseconds: (windowStartSeconds * 1e6).round()),
    );
    final endX = layout.xForTime(
      Duration(microseconds: (windowEndSeconds * 1e6).round()),
    );
    final secondsPerPixel = 1 / layout.pixelsPerSecond;
    final lastBucket = waveform.bucketCount - 1;
    final barPath = Path();
    for (var x = startX.floorToDouble(); x <= endX; x += 1) {
      final pixelStartSeconds =
          (x - layout.leftPadding) / layout.pixelsPerSecond;
      if (pixelStartSeconds < 0) continue;
      final bucketStart =
          waveform.bucketForSeconds(pixelStartSeconds).clamp(0, lastBucket);
      final bucketEnd = waveform
          .bucketForSeconds(pixelStartSeconds + secondsPerPixel)
          .clamp(bucketStart, lastBucket);
      var amplitude = 0.0;
      for (var b = bucketStart; b <= bucketEnd; b++) {
        final peak = waveform.maxPeaks[b] > -waveform.minPeaks[b]
            ? waveform.maxPeaks[b]
            : -waveform.minPeaks[b];
        if (peak > amplitude) amplitude = peak;
      }
      final halfHeight = amplitude.clamp(0.0, 1.0) * (_waveformHeight / 2);
      barPath
        ..moveTo(x, waveformMidY - halfHeight)
        ..lineTo(x, waveformMidY + halfHeight);
    }
    canvas.drawPath(
      barPath,
      Paint()
        ..color = accentColor.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant TabTimelinePainter oldDelegate) {
    return oldDelegate.notes != notes ||
        oldDelegate.playhead != playhead ||
        oldDelegate.selectedIndices != selectedIndices ||
        oldDelegate.highlightBeats != highlightBeats ||
        oldDelegate.beatsPerMeasure != beatsPerMeasure ||
        oldDelegate.bpm != bpm ||
        oldDelegate.totalSeconds != totalSeconds ||
        oldDelegate.windowStartSeconds != windowStartSeconds ||
        oldDelegate.windowEndSeconds != windowEndSeconds ||
        oldDelegate.waveform != waveform ||
        oldDelegate.audioLoaded != audioLoaded ||
        oldDelegate.layout != layout;
  }
}
