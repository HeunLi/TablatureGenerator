import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../models/tempo_map.dart';

/// A click track synthesized with the Web Audio API, scheduled ahead of the
/// playhead so it stays locked to the audio.
///
/// **Why not just fire a sound on a Dart `Timer` each beat.** JavaScript
/// timers are not remotely accurate enough for a metronome — they're
/// coalesced, throttled, and pushed around by whatever else is on the
/// single thread (a repaint, a decode, a GC pause), which at 120 BPM turns
/// into audible flamming within a few bars. Web Audio has its own
/// high-precision clock (`AudioContext.currentTime`) and can be told to
/// start a sound at an exact future time on the audio thread. So the timer
/// here is only a *scheduler*: it wakes up periodically and books every
/// click falling inside the next [_lookahead], and the audio thread plays
/// them precisely regardless of how busy the main thread is. Being late by
/// a whole wake-up interval is harmless as long as the interval is shorter
/// than the lookahead. (This is the standard "two clocks" arrangement for
/// browser metronomes.)
///
/// Clicks are synthesized from an oscillator + gain envelope rather than
/// shipping audio assets — nothing to download, and the pitch/length can be
/// tuned in code.
class Metronome {
  web.AudioContext? _context;
  Timer? _scheduler;

  TempoMap? _tempo;

  /// Maps audio-track position to audio-context time. `contextTime =
  /// _anchorContextTime + (position - _anchorPosition) / rate`, i.e. the
  /// playback rate scales real time against track time — at 0.5x, one
  /// second of track takes two real seconds and the clicks slow down with
  /// it.
  double _anchorContextTime = 0;
  Duration _anchorPosition = Duration.zero;
  double _rate = 1;

  /// Track position that clicks have already been booked through, so a
  /// re-anchor mid-playback can't double-book the beats it already
  /// scheduled.
  double _scheduledThroughSeconds = 0;

  bool _running = false;

  /// 0..1. Read at schedule time, so a change takes effect within one
  /// lookahead window rather than needing a restart.
  double volume = 0.5;

  /// How far ahead clicks are booked. Long enough to absorb a stalled main
  /// thread, short enough that a tempo edit or a seek is heard almost
  /// immediately.
  static const _lookahead = Duration(milliseconds: 150);
  static const _tick = Duration(milliseconds: 25);

  /// Drift below this is ignored. The playhead anchor is refreshed from the
  /// audio element's own reported position, which jitters by a few
  /// milliseconds between updates; re-anchoring on every one of those would
  /// add jitter rather than remove it.
  static const _resyncThreshold = Duration(milliseconds: 60);

  static const _accentFrequency = 1600.0;
  static const _beatFrequency = 1000.0;
  static const _clickSeconds = 0.045;

  bool get isRunning => _running;

  /// Creates and unblocks the audio context ahead of time.
  ///
  /// Browsers only allow an `AudioContext` to leave its suspended state off
  /// the back of a user gesture. Playback starts the click indirectly — a
  /// tap on play, then a player-state event a few async hops later — so by
  /// then the original gesture is long gone. Calling this from the direct
  /// tap that *enables* the metronome gets the context running while
  /// permission is unambiguous.
  Future<void> prepare() => _resume(_ensureContext());

  web.AudioContext _ensureContext() {
    final existing = _context;
    if (existing != null) return existing;
    final created = web.AudioContext();
    _context = created;
    return created;
  }

  /// Plays [beats] clicks at [bpm] starting immediately, and completes once
  /// the last one has sounded — the count-in before playback begins.
  ///
  /// Returns the count-in's real-world duration so the caller can start the
  /// track at the right moment. The final click lands exactly on the
  /// downbeat where audio should begin, which is what makes a count-in
  /// useful rather than merely decorative.
  Future<void> countIn({
    required int beats,
    required double bpm,
    required int beatsPerMeasure,
    double rate = 1,
  }) async {
    if (beats <= 0) return;
    final context = _ensureContext();
    await _resume(context);

    final secondsPerBeat = 60 / bpm / rate;
    final start = context.currentTime + 0.08;
    for (var beat = 0; beat < beats; beat++) {
      _click(
        context,
        start + beat * secondsPerBeat,
        accent: beat % beatsPerMeasure == 0,
      );
    }
    await Future<void>.delayed(
      Duration(microseconds: ((0.08 + beats * secondsPerBeat) * 1e6).round()),
    );
  }

  /// Begins (or restarts) scheduling against [tempo], with the track
  /// currently at [position] and playing at [rate].
  Future<void> start({
    required TempoMap tempo,
    required Duration position,
    required double rate,
  }) async {
    final context = _ensureContext();
    await _resume(context);

    _tempo = tempo;
    _rate = rate <= 0 ? 1.0 : rate;
    _anchorContextTime = context.currentTime;
    _anchorPosition = position;
    _scheduledThroughSeconds =
        position.inMicroseconds / Duration.microsecondsPerSecond;
    _running = true;

    _scheduler?.cancel();
    _scheduler = Timer.periodic(_tick, (_) => _schedule());
    _schedule();
  }

  void stop() {
    _running = false;
    _scheduler?.cancel();
    _scheduler = null;
  }

  /// Re-anchors against a freshly-measured [position] — after a seek, a
  /// loop wrap, a rate change, or routine drift correction. Cheap enough to
  /// call on every position update; it no-ops when the predicted and actual
  /// positions already agree (see [_resyncThreshold]).
  void resync({
    required Duration position,
    required double rate,
    bool force = false,
  }) {
    if (!_running) return;
    final context = _context;
    if (context == null) return;

    final normalizedRate = rate <= 0 ? 1.0 : rate;
    final predicted = _positionAt(context.currentTime);
    if (!force &&
        normalizedRate == _rate &&
        (predicted - position).abs() < _resyncThreshold) {
      return;
    }

    _rate = normalizedRate;
    _anchorContextTime = context.currentTime;
    _anchorPosition = position;
    // Clicks already handed to the audio thread can't be recalled, so only
    // rewind the booking cursor — never advance it past what's pending, or
    // a backwards seek would silently swallow the beats it lands on.
    final seconds = position.inMicroseconds / Duration.microsecondsPerSecond;
    if (force || seconds < _scheduledThroughSeconds) {
      _scheduledThroughSeconds = seconds;
    }
  }

  void setTempo(TempoMap tempo) => _tempo = tempo;

  Duration _positionAt(double contextTime) =>
      _anchorPosition +
      Duration(
        microseconds:
            ((contextTime - _anchorContextTime) * _rate * 1e6).round(),
      );

  void _schedule() {
    final context = _context;
    final tempo = _tempo;
    if (!_running || context == null || tempo == null) return;

    final now = _positionAt(context.currentTime);
    final untilSeconds =
        (now + _lookahead).inMicroseconds / Duration.microsecondsPerSecond;
    final fromSeconds = _scheduledThroughSeconds;
    if (untilSeconds <= fromSeconds) return;

    tempo.visitBeats(
      fromSeconds,
      untilSeconds,
      visit: (seconds, isDownbeat) {
        // `visitBeats` is inclusive at both ends, but consecutive windows
        // share a boundary — so treat the window as half-open `[from, until)`
        // and let the next tick own a beat sitting exactly on `until`.
        // Without this, every beat that lands on a window edge flams.
        if (seconds < fromSeconds || seconds >= untilSeconds) return;
        final when = _anchorContextTime +
            (seconds -
                    _anchorPosition.inMicroseconds /
                        Duration.microsecondsPerSecond) /
                _rate;
        if (when < context.currentTime) return;
        _click(context, when, accent: isDownbeat);
      },
    );
    _scheduledThroughSeconds = untilSeconds;
  }

  /// One click: a short tone with a fast exponential decay, which reads as
  /// a percussive tick rather than a beep. The envelope matters more than
  /// the waveform — an un-enveloped oscillator produces an audible click at
  /// both ends from the discontinuity.
  void _click(web.AudioContext context, double when, {required bool accent}) {
    final oscillator = context.createOscillator();
    final gain = context.createGain();
    oscillator.type = 'square';
    oscillator.frequency.setValueAtTime(
      accent ? _accentFrequency : _beatFrequency,
      when,
    );

    final peak = (accent ? volume : volume * 0.7).clamp(0.0001, 1.0);
    gain.gain
      ..setValueAtTime(0.0001, when)
      ..exponentialRampToValueAtTime(peak, when + 0.002)
      // Exponential ramps can't reach zero, hence the small floor rather
      // than 0 — the node is stopped immediately afterwards anyway.
      ..exponentialRampToValueAtTime(0.0001, when + _clickSeconds);

    oscillator.connect(gain);
    gain.connect(context.destination);
    oscillator.start(when);
    oscillator.stop(when + _clickSeconds + 0.01);
  }

  Future<void> _resume(web.AudioContext context) async {
    // Browsers start an AudioContext suspended until a user gesture. Every
    // path here is reached from a tap on play or the metronome toggle, so
    // resuming is allowed — it just has to be asked for explicitly.
    if (context.state == 'suspended') {
      await context.resume().toDart;
    }
  }

  void dispose() {
    stop();
    final context = _context;
    _context = null;
    if (context != null) {
      unawaited(context.close().toDart);
    }
  }
}
