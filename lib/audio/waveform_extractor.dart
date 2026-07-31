import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Downsampled amplitude envelope for drawing a waveform preview, stored as
/// a **max pyramid** (a mipmap): level 0 holds one peak per
/// [bucketsPerSecond]-th of a second, and each higher level halves the
/// resolution by taking the max of each adjacent pair.
///
/// Why a pyramid rather than one flat peak array: the drawing code needs
/// "the loudest sample anywhere in this one screen pixel", and how much
/// audio a screen pixel covers depends on zoom (which is BPM-derived here —
/// see `StudioScreen._pixelsPerSecond`) and could later depend on a real
/// zoom control. With a flat array that query costs
/// O(buckets-per-pixel), so zooming out makes every pixel of the waveform
/// progressively more expensive to draw. With the pyramid the renderer
/// picks the level where a pixel spans only a handful of entries, so the
/// cost per pixel is **constant at any zoom level** — which is what keeps
/// this cheap if the timeline ever grows a zoom-out control that goes well
/// past the current 20–300 BPM range.
///
/// Peaks are stored as a single non-negative magnitude per bucket
/// (`max(|min|, max)`) rather than separate min/max arrays: the strip is
/// drawn symmetrically around its center line, so the two were always
/// collapsed to exactly this value at draw time anyway — storing it
/// pre-collapsed halves the memory and removes that work from the hot path.
class WaveformData {
  WaveformData._(this._levels, this.bucketsPerSecond);

  /// Builds the pyramid from a level-0 peak array. Total memory is ~2x
  /// [peaks] (a halving series sums to 2), which for a 5-minute track at
  /// the default rate is well under a megabyte.
  factory WaveformData.fromPeaks(
    Float32List peaks, {
    required double bucketsPerSecond,
  }) {
    final levels = <Float32List>[peaks];
    var current = peaks;
    while (current.length > 2) {
      final next = Float32List((current.length + 1) ~/ 2);
      for (var i = 0; i < next.length; i++) {
        final a = current[i * 2];
        final rightIndex = i * 2 + 1;
        final b = rightIndex < current.length ? current[rightIndex] : a;
        next[i] = a > b ? a : b;
      }
      levels.add(next);
      current = next;
    }
    return WaveformData._(levels, bucketsPerSecond);
  }

  static final empty = WaveformData._(const <Float32List>[], 1);

  final List<Float32List> _levels;

  /// Resolution of level 0, in buckets per second of audio. Fixed at
  /// extraction time and independent of playback BPM/zoom — only the
  /// time->pixel mapping used to *draw* these buckets depends on that,
  /// same as notes and grid lines.
  final double bucketsPerSecond;

  /// How many level-0 entries a single lookup is allowed to scan before
  /// stepping up a pyramid level. Small enough that the scan stays a
  /// couple of array reads, large enough that the chosen level is never
  /// coarser than the query actually needs.
  static const _maxEntriesPerLookup = 4;

  int get bucketCount => _levels.isEmpty ? 0 : _levels.first.length;
  bool get isEmpty => bucketCount == 0;
  double get durationSeconds => bucketCount / bucketsPerSecond;

  /// Loudest magnitude (0..1) anywhere in `[startSeconds, endSeconds)`, in
  /// roughly constant time regardless of how wide that span is — see the
  /// class doc. Ranges partly or wholly outside the decoded audio simply
  /// contribute nothing.
  double peakBetween(double startSeconds, double endSeconds) {
    if (_levels.isEmpty || endSeconds <= startSeconds) return 0;

    final spanEntries = (endSeconds - startSeconds) * bucketsPerSecond;
    var level = 0;
    if (spanEntries > _maxEntriesPerLookup) {
      level = (math.log(spanEntries / _maxEntriesPerLookup) / math.ln2).ceil();
      if (level >= _levels.length) level = _levels.length - 1;
    }
    final data = _levels[level];
    final entriesPerSecond = bucketsPerSecond / (1 << level);

    var first = (startSeconds * entriesPerSecond).floor();
    var last = (endSeconds * entriesPerSecond).ceil();
    if (first < 0) first = 0;
    if (last > data.length) last = data.length;
    // A sub-entry-wide query (zoomed in past level-0 resolution) still has
    // to read the one entry it lands in, not an empty range.
    if (last <= first) last = first + 1 <= data.length ? first + 1 : data.length;
    if (first >= last) return 0;

    var peak = 0.0;
    for (var i = first; i < last; i++) {
      final value = data[i];
      if (value > peak) peak = value;
    }
    return peak;
  }
}

/// Decodes an in-memory audio file (the same bytes already held for
/// playback/persistence) into [WaveformData] via the browser's Web Audio
/// API — the only way to get raw PCM samples out of a compressed file
/// (MP3/WAV/etc.) without shipping a decoder ourselves.
class WaveformExtractor {
  /// Level-0 resolution of the extracted pyramid. At the timeline's highest
  /// zoom (300 BPM => 360 px/sec) this is still slightly finer than one
  /// bucket per screen pixel, so the strip stays smooth rather than visibly
  /// stepping; the pyramid handles the zoomed-out end (see [WaveformData]).
  static const bucketsPerSecond = 400.0;

  /// Sample rate to decode at. Per the Web Audio spec, `decodeAudioData`
  /// resamples the decoded result to the context's own sample rate — so
  /// asking an [web.OfflineAudioContext] built at a low rate to do the
  /// decode hands back ~4x fewer samples than the file's native 44.1/48 kHz
  /// for exactly the same envelope, since anything above this rate is far
  /// beyond what a 400-buckets/sec preview could show anyway. This is the
  /// difference between scanning ~8M samples and ~2M for a 3-minute track.
  ///
  /// Comfortably above every browser's minimum allowed context rate (8 kHz
  /// on Safari/Firefox, 3 kHz on Chromium), and the code reads back
  /// `AudioBuffer.sampleRate` regardless — so a browser that ignores the
  /// hint and decodes natively still produces a correct waveform, just
  /// with more samples to scan.
  static const _decodeSampleRate = 11025;

  /// How long the peak scan may run before yielding to the browser. The
  /// scan is a tight loop over millions of samples; without breaks it
  /// blocks the single JS thread outright, freezing rendering *and* input
  /// for the whole decode. Yielding on a time budget (rather than a fixed
  /// iteration count) keeps each pause short on a slow phone as well as a
  /// fast desktop, at the cost of the waveform appearing a few frames
  /// later — which is fine, since it renders a placeholder until then.
  static const _sliceBudgetMs = 6;

  /// Checked every this many buckets — often enough to honour the budget
  /// above, rare enough that the clock read itself isn't part of the hot
  /// loop.
  static const _budgetCheckInterval = 256;

  static Future<WaveformData> extract(Uint8List bytes) async {
    final audioBuffer = await _decode(bytes);
    final samples = audioBuffer.getChannelData(0).toDart;
    final sampleRate = audioBuffer.sampleRate;
    if (samples.isEmpty || sampleRate <= 0) return WaveformData.empty;

    final samplesPerBucket =
        (sampleRate / bucketsPerSecond).round().clamp(1, samples.length);
    final bucketCount = (samples.length / samplesPerBucket).ceil();
    final peaks = Float32List(bucketCount);

    final clock = Stopwatch()..start();
    for (var bucket = 0; bucket < bucketCount; bucket++) {
      final start = bucket * samplesPerBucket;
      var end = start + samplesPerBucket;
      if (end > samples.length) end = samples.length;
      var peak = 0.0;
      for (var i = start; i < end; i++) {
        final value = samples[i];
        final magnitude = value < 0 ? -value : value;
        if (magnitude > peak) peak = magnitude;
      }
      peaks[bucket] = peak;

      if (bucket % _budgetCheckInterval == 0 &&
          clock.elapsedMilliseconds >= _sliceBudgetMs) {
        // A zero-duration `Future.delayed` is a macrotask (setTimeout),
        // which actually lets the browser paint — `await null` would only
        // drain the microtask queue and never give up the frame.
        await Future<void>.delayed(Duration.zero);
        clock.reset();
      }
    }

    return WaveformData.fromPeaks(peaks, bucketsPerSecond: bucketsPerSecond);
  }

  static Future<web.AudioBuffer> _decode(Uint8List bytes) async {
    try {
      // `length` only sizes the (unused) render buffer of an offline
      // context; 1 frame is the minimum the constructor accepts and costs
      // nothing. Nothing is ever rendered through this context — it exists
      // purely to pin the decode's output sample rate.
      final offline = web.OfflineAudioContext(1.toJS, 1, _decodeSampleRate);
      return await offline.decodeAudioData(_detachableCopy(bytes)).toDart;
    } catch (_) {
      // Some browser rejected either the low rate or the offline decode —
      // fall back to a normal context at its native rate. Correct either
      // way, just more samples to scan.
    }
    final context = web.AudioContext();
    try {
      return await context.decodeAudioData(_detachableCopy(bytes)).toDart;
    } finally {
      // Browsers cap how many live AudioContexts a page may hold, and this
      // one has served its purpose the moment the decode resolves.
      unawaited(context.close().toDart);
    }
  }

  /// `decodeAudioData` reads (and, per an older revision of the spec, may
  /// detach) the `ArrayBuffer` it's given, so it always gets a copy — the
  /// caller's bytes are still needed elsewhere (playback, persistence,
  /// export) and must stay intact.
  static JSArrayBuffer _detachableCopy(Uint8List bytes) =>
      Uint8List.fromList(bytes).buffer.toJS;
}
