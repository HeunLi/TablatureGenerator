import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Downsampled min/max amplitude buckets for drawing a waveform preview.
///
/// Computed once (via [WaveformExtractor.extract]) when audio loads, rather
/// than scanning raw samples at paint time — a multi-minute track can be
/// tens of millions of samples, and [TabTimelinePainter] already goes out
/// of its way to keep repaint cost bounded (it fires on every playhead
/// tick during playback), so re-scanning raw audio per frame is a
/// non-starter.
class WaveformData {
  const WaveformData({
    required this.minPeaks,
    required this.maxPeaks,
    required this.bucketsPerSecond,
  });

  /// Per-bucket minimum sample value, roughly in [-1, 1].
  final Float32List minPeaks;

  /// Per-bucket maximum sample value, roughly in [-1, 1].
  final Float32List maxPeaks;

  /// How many buckets make up one second of audio. Fixed at extraction
  /// time and independent of playback BPM/zoom — only the time-to-pixel
  /// mapping used to *draw* these buckets depends on that, same as notes
  /// and grid lines.
  final double bucketsPerSecond;

  int bucketForSeconds(double seconds) =>
      (seconds * bucketsPerSecond).floor();

  int get bucketCount => maxPeaks.length;
}

/// Decodes an in-memory audio file (the same bytes already held for
/// playback/persistence) into [WaveformData] via the browser's Web Audio
/// API (`AudioContext.decodeAudioData`) — the only way to get raw PCM
/// samples out of a compressed file (MP3/WAV/etc.) without shipping a
/// decoder ourselves.
class WaveformExtractor {
  /// Buckets per second of audio. Fine enough that even at the timeline's
  /// highest zoom (300 BPM) there's still sub-pixel resolution to work
  /// with, coarse enough that a multi-minute track's peak arrays stay a
  /// fraction of a megabyte.
  static const bucketsPerSecond = 200.0;

  static Future<WaveformData> extract(Uint8List bytes) async {
    final context = web.AudioContext();
    try {
      // decodeAudioData reads (and per an older revision of the spec, may
      // detach) the ArrayBuffer it's given, so hand it a copy rather than
      // a view over the caller's original bytes — those are still needed
      // elsewhere (persistence, export) and must stay intact.
      final copy = Uint8List.fromList(bytes);
      final audioBuffer =
          await context.decodeAudioData(copy.buffer.toJS).toDart;
      final samples = audioBuffer.getChannelData(0).toDart;
      final sampleRate = audioBuffer.sampleRate;

      final samplesPerBucket = (sampleRate / bucketsPerSecond)
          .ceil()
          .clamp(1, samples.isEmpty ? 1 : samples.length);
      final bucketCount = samples.isEmpty
          ? 0
          : (samples.length / samplesPerBucket).ceil();
      final minPeaks = Float32List(bucketCount);
      final maxPeaks = Float32List(bucketCount);

      for (var bucket = 0; bucket < bucketCount; bucket++) {
        final start = bucket * samplesPerBucket;
        final end = (start + samplesPerBucket).clamp(0, samples.length);
        var minValue = 0.0;
        var maxValue = 0.0;
        for (var i = start; i < end; i++) {
          final value = samples[i];
          if (value < minValue) minValue = value;
          if (value > maxValue) maxValue = value;
        }
        minPeaks[bucket] = minValue;
        maxPeaks[bucket] = maxValue;
      }

      return WaveformData(
        minPeaks: minPeaks,
        maxPeaks: maxPeaks,
        bucketsPerSecond: bucketsPerSecond,
      );
    } finally {
      unawaited(context.close().toDart);
    }
  }
}
