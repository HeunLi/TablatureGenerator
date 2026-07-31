import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import '../audio/audio_controller.dart';
import '../audio/metronome.dart';
import '../audio/waveform_extractor.dart';
import '../export/tab_video_exporter.dart';
import '../models/tab_note.dart';
import '../models/tab_project.dart';
import '../models/tempo_map.dart';
import '../persistence/project_store.dart';
import '../utils/safe_pop.dart';
import '../widgets/glass_panel.dart';
import '../widgets/tab_timeline_layout.dart';
import '../widgets/tab_timeline_view.dart';
import '../widgets/tempo_map_dialog.dart';

/// The tab editor for a single project: tap the timeline to add notes, drag
/// existing notes to reposition them (time + string), use the side panel to
/// edit the fret/duration of whichever note is selected, and upload an
/// audio file to play back with the tab highlighting in sync.
///
/// Reached from [DashboardScreen] (`lib/screens/dashboard_screen.dart`),
/// which owns project creation/listing/deletion — this screen only ever
/// works on the one project identified by [projectId].
///
/// **State that changes at interaction/frame rate lives in
/// [ValueNotifier]s, not in `setState`.** The playhead, the note list, the
/// selection, the decoded waveform, and the unsaved-changes flag all update
/// far too often for a full-screen rebuild each time — this screen paints
/// three `BackdropFilter`-blurred glass panels, so rebuilding it on every
/// pointer-move of a note drag or every playhead tick was itself a
/// meaningful share of the frame budget. Everything that consumes them
/// subscribes at the narrowest point that needs the value (the timeline
/// layers via `CustomPainter.repaint`, the transport row and floating edit
/// panel via builders), so an edit repaints what changed and nothing else.
/// `setState` is reserved for the genuinely occasional things — tempo,
/// zoom, track duration, audio-loaded state — that really do reflow the
/// screen.
class StudioScreen extends StatefulWidget {
  const StudioScreen({
    super.key,
    required this.projectId,
    this.isNewProject = false,
  });

  /// The project to load from [ProjectStore], or — when [isNewProject] is
  /// true — the id a brand-new, not-yet-saved project should use once the
  /// user does save.
  final String projectId;

  /// Skips the store lookup and starts from an empty project instead. Set
  /// by the dashboard's "New project" action, whose generated id has
  /// nothing saved under it yet.
  final bool isNewProject;

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen>
    with SingleTickerProviderStateMixin {
  late TabProject _project;
  final _audio = AudioController();
  final _store = ProjectStore();
  final _metronome = Metronome();
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<PlayerState>? _playerStateSub;

  // Updated every animation frame during playback (see [_ticker]); only the
  // timeline's note/playhead layer listens to it, so a tick repaints that
  // one layer and touches nothing else.
  final _playhead = ValueNotifier<Duration>(Duration.zero);

  // The transport bar's scrub slider and time readout track the playhead at
  // a deliberately coarser rate than the timeline does. A Material `Slider`
  // is a real widget subtree, and rebuilding it 60 times a second is
  // needless when the readout only shows tenths of a second and the thumb
  // moves a sub-pixel distance per frame on any track longer than a few
  // seconds — so it only updates once the position has moved far enough to
  // actually look different.
  final _playheadCoarse = ValueNotifier<Duration>(Duration.zero);
  static const _coarsePlayheadStep = Duration(milliseconds: 100);

  // Which tempo marker governs the current playhead position. The toolbar's
  // tempo/meter chips edit *this* marker rather than a single global tempo,
  // so tuning the grid always affects the section actually being listened
  // to. Notified only on a crossing, not every tick.
  final _activeMarker = ValueNotifier<int>(0);

  // just_audio's positionStream does not fire every frame — browsers
  // commonly throttle real <audio> element position updates to a handful
  // of times per second — so driving the red playhead line directly from
  // it makes it visibly jump between updates instead of gliding. Instead,
  // each positionStream event is only used to (re)anchor `_lastKnownPosition`
  // + restart `_positionClock`; a per-frame `Ticker` then interpolates the
  // displayed position, which is smooth by construction and gets nudged
  // back in sync every time a real update arrives (correcting for any audio
  // clock drift).
  Duration _lastKnownPosition = Duration.zero;
  final _positionClock = Stopwatch();
  late final Ticker _ticker;
  double _totalSeconds = 12.0;
  bool _audioLoaded = false;
  bool _isPlaying = false;
  bool _isSeeking = false;
  bool _countingIn = false;
  String? _audioFileName;
  Uint8List? _audioBytes;
  String? _audioExtension;

  /// Playback speed. Slowing a passage down is the core transcription move
  /// — it's how a fast line becomes something you can actually place notes
  /// against. Pitch is preserved (see [AudioController.setSpeed]).
  double _playbackRate = 1;
  static const _speedPresets = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5];

  // Null while no audio is loaded, or while a just-loaded/just-picked
  // track is still being decoded — see [_extractWaveform]. Decoding is
  // keyed by an incrementing token so a slow decode for a track the user
  // has since replaced can't clobber a newer (or absent) result when it
  // finally resolves.
  final _waveform = ValueNotifier<WaveformData?>(null);
  int _waveformRequestId = 0;

  // The live note list. `_project` stays the source of truth (it's what
  // gets saved and exported); this mirrors `_project.notes` so the timeline
  // and the floating edit panel can subscribe to note changes without a
  // screen-wide rebuild. Always reassigned together — see [_updateNotes].
  final _notes = ValueNotifier<List<TabNote>>(const []);

  // Shift+click toggles membership in this set instead of replacing it,
  // for selecting multiple notes at once. A plain click replaces it with a
  // single-element set.
  final _selection = ValueNotifier<Set<int>>(const {});

  /// A/B loop bounds in seconds, or null when none is set. Dragged out
  /// directly on the waveform strip (see [TabTimelineView]) — looping a bar
  /// while you work it out is half of how transcription actually gets done,
  /// and picking the region off the waveform is far quicker than typing
  /// timestamps.
  final _loopRegion = ValueNotifier<(double, double)?>(null);
  bool _loopEnabled = false;

  /// Guards against firing a burst of seeks while the previous one is still
  /// resolving — the ticker runs at display rate, so the position stays
  /// past the loop end for several frames after the wrap is requested.
  bool _loopWrapPending = false;

  bool _metronomeEnabled = false;

  /// Off by default: placing notes means pressing play constantly to
  /// re-hear a bar, and a mandatory bar of clicks before each one would be
  /// a tax on the most-repeated action in the app. It's here for when
  /// you're playing along, not scrubbing.
  bool _countInEnabled = false;

  // Snapshot of the dragged notes' original state, captured at pan-start,
  // so every note in the drag moves by the same delta relative to where it
  // started rather than all snapping to the cursor position independently.
  Map<int, TabNote>? _dragOriginalNotes;
  Offset? _dragStartPosition;

  // Manual double-click tracking (rather than a DoubleTapGestureRecognizer)
  // so a single click on a note still selects it immediately instead of
  // waiting out `kDoubleTapTimeout` to see if a second tap follows.
  int? _lastTapNoteIndex;
  DateTime? _lastTapTime;

  int _highlightBeats = 4;

  /// Grid resolution, in subdivisions per beat. Fixed at sixteenths for
  /// now, but passed explicitly rather than hardcoded in the painter so the
  /// grid and the snapping can never disagree about what the grid is.
  static const _subdivisionsPerBeat = 4;

  // When off, notes are placed/dragged at the exact clicked time instead of
  // being forced onto the grid — needed for passages with rubato or human
  // timing drift that no tempo marker can fully describe.
  bool _snapToGrid = true;
  final _timelineScrollController = ScrollController();

  /// Horizontal zoom, in pixels per second. Now an independent control
  /// rather than being derived from BPM: with a tempo map there is no
  /// single BPM to derive it from, and being able to zoom in on a passage
  /// without changing the tempo interpretation is what makes fine placement
  /// possible in the first place.
  double _pixelsPerSecond = _defaultZoom;
  static const _defaultZoom = 120.0;
  static const _minZoom = 12.0;
  static const _maxZoom = 1600.0;
  static const _zoomStep = 1.25;

  // Autosave: any edit that touches `_project` (or picking new audio)
  // (re)starts this debounce timer rather than saving immediately, so
  // rapid-fire changes (dragging a note, holding a stepper) don't each
  // trigger their own IndexedDB write. `_audioDirty` is tracked
  // separately from "the project needs saving" because audio bytes can be
  // multiple MB — re-writing them on every autosave tick even when only a
  // note moved would be needless IndexedDB churn; they're only sent to
  // `ProjectStore.save` when they've actually changed since the last save.
  static const _autosaveDelay = Duration(seconds: 2);
  Timer? _autosaveTimer;
  final _unsaved = ValueNotifier<bool>(false);
  bool _audioDirty = false;

  void _scheduleAutosave() {
    _unsaved.value = true;
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(_autosaveDelay, _autosave);
  }

  Future<void> _autosave() async {
    await _store.save(
      _project,
      audioBytes: _audioDirty ? _audioBytes : null,
      audioExtension: _audioDirty ? _audioExtension : null,
    );
    _audioDirty = false;
    if (!mounted) return;
    _unsaved.value = false;
  }

  TempoMap get _tempo => _project.tempo;

  TabTimelineLayout get _layout => TabTimelineLayout(
        pixelsPerSecond: _pixelsPerSecond,
        stringSpacing: 48,
        // Taller than the strings strictly need: the band above the grid
        // carries measure numbers *and* tempo-marker flags now.
        topPadding: 52,
        leftPadding: 40,
      );

  Duration get _totalDuration =>
      Duration(milliseconds: (_totalSeconds * 1000).round());

  @override
  void initState() {
    super.initState();
    // Placeholder until [_loadProject] resolves (or permanently, for a
    // brand-new project) — kept empty rather than seeded with demo notes
    // now that every project starts this way, not just the app's very
    // first run.
    _project = TabProject(
      id: widget.projectId,
      title: 'Untitled',
      notes: [],
      tempo: TempoMap.single(),
    );
    _notes.value = _project.notes;
    // A brand-new project has nothing saved under its id yet, so it starts
    // "unsaved" rather than waiting for the first edit to say so.
    _unsaved.value = widget.isNewProject;

    // A real update is a correction, not the thing that moves the line —
    // see the field docs on `_ticker` for why.
    _positionSub = _audio.positionStream.listen((position) {
      if (_isSeeking) return;
      _lastKnownPosition = position;
      _positionClock
        ..reset()
        ..start();
      if (_isPlaying) {
        // Keep the click locked to the audio rather than to the Dart
        // clock; the metronome ignores corrections small enough to be
        // measurement jitter.
        _metronome.resync(position: position, rate: _playbackRate);
      } else {
        // The ticker isn't advancing it, so apply this directly (e.g. a
        // late event arriving right as playback paused).
        _setPlayhead(position);
      }
    });
    _durationSub = _audio.durationStream.listen((duration) {
      if (duration != null && duration.inMilliseconds > 0) {
        setState(() => _totalSeconds = duration.inMilliseconds / 1000);
      }
    });
    _playerStateSub = _audio.playerStateStream.listen((state) {
      setState(() => _isPlaying = state.playing);
      if (state.playing) {
        _positionClock
          ..reset()
          ..start();
        _ticker.start();
        _startMetronomeIfEnabled();
      } else {
        _positionClock.stop();
        _ticker.stop();
        _metronome.stop();
      }
      if (state.processingState == ProcessingState.completed) {
        setState(() => _isPlaying = false);
        _positionClock.stop();
        _ticker.stop();
        _metronome.stop();
        _lastKnownPosition = Duration.zero;
        _setPlayhead(Duration.zero);
        _audio.seek(Duration.zero);
      }
    });

    // A running Ticker makes Flutter keep pumping frames at the display's
    // full refresh rate for as long as it's running, so it's only started
    // while actually playing (above) rather than for the widget's whole
    // lifetime — otherwise we'd be undoing the point of this by burning
    // frames continuously even while paused/idle.
    _ticker = createTicker(_onTick);

    _loadProject();
  }

  void _onTick(Duration elapsed) {
    if (!_isPlaying || _isSeeking) return;
    // Scaled by the playback rate: at 0.5x, a second of wall clock advances
    // the track by half a second. Without this the interpolated playhead
    // races ahead of the audio the moment the speed leaves 1.0, and gets
    // yanked back on every real position update.
    final position = _lastKnownPosition + _positionClock.elapsed * _playbackRate;
    _playhead.value = position;
    if ((position - _playheadCoarse.value).abs() >= _coarsePlayheadStep) {
      _playheadCoarse.value = position;
    }
    final marker = _tempo.indexAt(position);
    if (marker != _activeMarker.value) _activeMarker.value = marker;
    _enforceLoop(position);
  }

  /// Wraps playback back to the loop start once it runs past the end.
  void _enforceLoop(Duration position) {
    if (!_loopEnabled || _loopWrapPending) return;
    final loop = _loopRegion.value;
    if (loop == null) return;
    final seconds = position.inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds < loop.$2) return;

    _loopWrapPending = true;
    _seekTo(
      Duration(microseconds: (loop.$1 * Duration.microsecondsPerSecond).round()),
    );
    // The audio element takes a moment to actually land on the new
    // position; until it does, the interpolated playhead is still past the
    // loop end and would request the same wrap again every frame.
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      _loopWrapPending = false;
    });
  }

  /// Moves the playhead outside of playback (seek, reset, a late position
  /// event while paused), where there's no reason to throttle the
  /// transport bar — it should land on the new position immediately.
  void _setPlayhead(Duration position) {
    _playhead.value = position;
    _playheadCoarse.value = position;
    final marker = _tempo.indexAt(position);
    if (marker != _activeMarker.value) _activeMarker.value = marker;
  }

  /// The one place a seek happens, so the interpolation anchor, the
  /// displayed playhead and the metronome's clock can't drift apart.
  void _seekTo(Duration position) {
    var target = position;
    if (target < Duration.zero) target = Duration.zero;
    if (target > _totalDuration) target = _totalDuration;
    _lastKnownPosition = target;
    _positionClock
      ..reset()
      ..start();
    _setPlayhead(target);
    if (_audioLoaded) _audio.seek(target);
    _metronome.resync(position: target, rate: _playbackRate, force: true);
  }

  void _startMetronomeIfEnabled() {
    if (!_metronomeEnabled) return;
    unawaited(
      _metronome.start(
        tempo: _tempo,
        position: _playhead.value,
        rate: _playbackRate,
      ),
    );
  }

  Future<void> _loadProject() async {
    await _store.init();
    if (widget.isNewProject) return;

    final saved = _store.load(widget.projectId);
    if (saved == null) return;

    setState(() {
      _project = saved.project;
      _audioBytes = saved.audioBytes;
      _audioExtension = saved.audioExtension;
    });
    _notes.value = _project.notes;

    if (saved.audioBytes != null && saved.audioExtension != null) {
      await _audio.loadFromBytes(saved.audioBytes!, saved.audioExtension!);
      if (!mounted) return;
      setState(() {
        _audioFileName = 'restored audio';
        _audioLoaded = true;
      });
      // The rate can only be pushed to the player once a source exists, so
      // a speed chosen before any audio was loaded has to be re-applied
      // here rather than silently reverting to 1x.
      if (_playbackRate != 1) await _audio.setSpeed(_playbackRate);
      _extractWaveform(saved.audioBytes!);
    }
  }

  /// Decodes [bytes] into the waveform preview's peak pyramid (see
  /// [WaveformExtractor]). Fire-and-forget from the caller's perspective —
  /// it runs in the background, yielding to the browser as it goes, and
  /// publishes to [_waveform] when it finishes rather than blocking audio
  /// load/pick on it.
  Future<void> _extractWaveform(Uint8List bytes) async {
    final requestId = ++_waveformRequestId;
    _waveform.value = null;
    try {
      final data = await WaveformExtractor.extract(bytes);
      // A newer request (a different track picked while this one was still
      // decoding) has since started — this result is stale, drop it rather
      // than overwriting the newer (or absent) waveform.
      if (!mounted || requestId != _waveformRequestId) return;
      _waveform.value = data;
    } catch (e) {
      debugPrint('Waveform extraction failed: $e');
    }
  }

  Future<void> _saveProject() async {
    // A manual save always sends the full audio blob (simpler and rare
    // enough not to matter) and preempts any pending debounced autosave.
    _autosaveTimer?.cancel();
    await _store.save(
      _project,
      audioBytes: _audioBytes,
      audioExtension: _audioExtension,
    );
    _audioDirty = false;
    if (!mounted) return;
    _unsaved.value = false;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Project saved locally'), duration: Duration(seconds: 1)),
    );
  }

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    if (_unsaved.value) {
      // Best-effort: a debounced autosave that hadn't fired yet shouldn't
      // silently drop the last few seconds of edits just because the user
      // navigated away. Can't await inside dispose(), so this is
      // fire-and-forget — ProjectStore/Hive don't depend on this widget's
      // lifecycle, so the write still completes after disposal.
      unawaited(_store.save(
        _project,
        audioBytes: _audioDirty ? _audioBytes : null,
        audioExtension: _audioDirty ? _audioExtension : null,
      ));
    }
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playerStateSub?.cancel();
    _audio.dispose();
    _metronome.dispose();
    _ticker.dispose();
    _timelineScrollController.dispose();
    _playhead.dispose();
    _playheadCoarse.dispose();
    _activeMarker.dispose();
    _waveform.dispose();
    _notes.dispose();
    _selection.dispose();
    _loopRegion.dispose();
    _unsaved.dispose();
    super.dispose();
  }

  /// Applies [transform] to the note list and republishes it. Deliberately
  /// does **not** call `setState`: every widget that renders notes reads
  /// them through [_notes], so a drag (which lands here on every
  /// pointer-move frame) repaints the timeline's note layer and the
  /// floating edit panel, and leaves the rest of the screen — including
  /// three blurred glass panels — untouched.
  void _updateNotes(List<TabNote> Function(List<TabNote>) transform) {
    final next = transform([..._project.notes]);
    _project = _project.copyWith(notes: next);
    _notes.value = next;
    _scheduleAutosave();
  }

  /// Applies a new tempo track. Everything downstream — grid lines,
  /// snapping, the highlight block, the metronome, the export pagination —
  /// reads from this one value, so nothing else needs updating.
  void _updateTempo(TempoMap tempo) {
    setState(() => _project = _project.copyWith(tempo: tempo));
    _metronome.setTempo(tempo);
    _activeMarker.value = tempo.indexAt(_playhead.value);
    _scheduleAutosave();
  }

  Future<void> _pickAudio() async {
    final result = await FilePicker.pickFiles(
      type: FileType.audio,
      withData: true,
    );
    final file = result?.files.single;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return;

    final extension = file.extension ?? 'mp3';
    await _audio.loadFromBytes(bytes, extension);
    if (!mounted) return;
    setState(() {
      _audioFileName = file.name;
      _audioBytes = bytes;
      _audioExtension = extension;
      _audioLoaded = true;
    });
    _audioDirty = true;
    _scheduleAutosave();
    _extractWaveform(bytes);
    _lastKnownPosition = Duration.zero;
    _setPlayhead(Duration.zero);
    // A loop region points at times in the *old* track; keeping it would
    // silently trap playback in an arbitrary window of the new one.
    _loopRegion.value = null;
    _loopEnabled = false;
    if (_playbackRate != 1) await _audio.setSpeed(_playbackRate);
  }

  Future<void> _togglePlayback() async {
    if (_isPlaying) {
      await _audio.pause();
      return;
    }
    if (_countInEnabled) {
      final marker = _tempo.markerAt(_playhead.value);
      setState(() => _countingIn = true);
      await _metronome.countIn(
        beats: marker.beatsPerMeasure,
        bpm: marker.bpm,
        beatsPerMeasure: marker.beatsPerMeasure,
        rate: _playbackRate,
      );
      if (!mounted) return;
      setState(() => _countingIn = false);
    }
    await _audio.play();
  }

  Future<void> _setPlaybackRate(double rate) async {
    setState(() => _playbackRate = rate);
    // Re-anchor before changing the rate: the interpolated playhead has
    // been accumulating at the old rate up to this instant, and that
    // accumulated part must be banked before the new one takes over.
    _lastKnownPosition = _playhead.value;
    _positionClock
      ..reset()
      ..start();
    if (_audioLoaded) await _audio.setSpeed(rate);
    _metronome.resync(position: _playhead.value, rate: rate, force: true);
  }

  Future<void> _toggleMetronome() async {
    setState(() => _metronomeEnabled = !_metronomeEnabled);
    if (!_metronomeEnabled) {
      _metronome.stop();
      return;
    }
    // This tap is the clearest user gesture the click will ever get; use it
    // to unblock the audio context rather than relying on the indirect path
    // through a player-state event later. See Metronome.prepare.
    await _metronome.prepare();
    if (!mounted || !_isPlaying) return;
    await _metronome.start(
      tempo: _tempo,
      position: _playhead.value,
      rate: _playbackRate,
    );
  }

  // --- Loop region ---

  void _handleLoopChanged(Duration start, Duration end) {
    _loopRegion.value = (
      start.inMicroseconds / Duration.microsecondsPerSecond,
      end.inMicroseconds / Duration.microsecondsPerSecond,
    );
  }

  void _handleLoopCommitted() {
    final loop = _loopRegion.value;
    if (loop == null) return;
    // A click (or a twitch) inside the waveform strip isn't a loop — it's
    // a seek that happened to wobble. Anything under a beat's worth of
    // drag is discarded rather than becoming an unusable loop.
    if (loop.$2 - loop.$1 < 0.15) {
      _loopRegion.value = null;
      if (_loopEnabled) setState(() => _loopEnabled = false);
      return;
    }
    if (!_loopEnabled) setState(() => _loopEnabled = true);
  }

  void _toggleLoop() {
    if (_loopRegion.value == null) return;
    setState(() => _loopEnabled = !_loopEnabled);
  }

  void _clearLoop() {
    _loopRegion.value = null;
    setState(() => _loopEnabled = false);
  }

  // --- Zoom ---

  void _zoomBy(double factor, {double? anchorViewportX}) {
    _setZoom(
      (_pixelsPerSecond * factor).clamp(_minZoom, _maxZoom),
      anchorViewportX: anchorViewportX,
    );
  }

  /// Changes zoom while keeping one point on the timeline pinned under the
  /// same screen position — the cursor for a wheel zoom, the viewport
  /// centre otherwise. Zooming that doesn't anchor throws away your place
  /// in the track, which makes it useless for the close-in work it exists
  /// for.
  void _setZoom(double next, {double? anchorViewportX}) {
    final controller = _timelineScrollController;
    double? anchorSeconds;
    double? anchorX;
    if (controller.hasClients) {
      anchorX = anchorViewportX ?? controller.position.viewportDimension / 2;
      anchorSeconds = (controller.position.pixels + anchorX - _layout.leftPadding) /
          _pixelsPerSecond;
    }

    setState(() => _pixelsPerSecond = next);

    if (anchorSeconds == null || anchorX == null) return;
    final seconds = anchorSeconds;
    final viewportX = anchorX;
    // The new scroll extent doesn't exist until the wider/narrower content
    // has been laid out, so the correcting jump has to wait for it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.hasClients) return;
      final position = controller.position;
      controller.jumpTo(
        (_layout.leftPadding + seconds * next - viewportX)
            .clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    });
  }

  void _handleZoomGesture(double delta, double viewportX) {
    _zoomBy(delta > 0 ? 1 / _zoomStep : _zoomStep, anchorViewportX: viewportX);
  }

  // --- Tempo editing ---

  void _adjustBpm(double delta) =>
      _updateTempo(_tempo.adjustBpmAt(_playhead.value, delta));

  void _adjustBeatsPerMeasure(int delta) =>
      _updateTempo(_tempo.adjustBeatsPerMeasureAt(_playhead.value, delta));

  /// Drops a tempo/meter change at the playhead, inheriting the current
  /// section's values so it starts as a no-op you then tune — which is the
  /// actual workflow: play until the grid drifts, mark the spot, adjust
  /// until it locks back on.
  void _addMarkerAtPlayhead() {
    final current = _tempo.markerAt(_playhead.value);
    _updateTempo(
      _tempo.withMarker(
        TempoMarker(
          time: _playhead.value,
          bpm: current.bpm,
          beatsPerMeasure: current.beatsPerMeasure,
        ),
      ),
    );
  }

  Future<void> _openTempoMap() async {
    final result = await showTempoMapDialog(
      context,
      initial: _tempo,
      playhead: _playhead.value,
    );
    if (result == null || !mounted) return;
    _updateTempo(result);
  }

  /// Stepping by 1 to reach an arbitrary tempo (e.g. 139) is tedious, so
  /// the BPM readout itself is tappable to type an exact value for the
  /// current section.
  Future<void> _promptBpm() async {
    final controller = TextEditingController(
      text: _tempo.bpmAt(_playhead.value).toStringAsFixed(0),
    );
    final result = await showDialog<double>(
      context: context,
      builder: (context) => GlassAlertDialog(
        title: const Text('Set tempo for this section'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          // See safePopOnSubmit — popping synchronously (or even after a
          // single deferred frame) inside onSubmitted can trip a framework
          // assertion ("_dependents.isEmpty is not true").
          onSubmitted: (value) =>
              safePopOnSubmit(context, double.tryParse(value)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(double.tryParse(controller.text)),
            child: const Text('Set'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || !mounted) return;
    _updateTempo(_tempo.setBpmAt(_playhead.value, result));
  }

  // --- Timeline gestures ---

  bool _hitTestNote(Offset position) =>
      _layout.hitTestNoteIndex(_project.notes, position) != null;

  void _handleTapUp(TapUpDetails details) {
    // The waveform strip is a scrub zone, not part of the note grid —
    // clicking a spot in the audio to hear it is the single most-repeated
    // action when timing notes, and it previously dropped a stray note on
    // the E string instead.
    if (_layout.isWaveformY(details.localPosition.dy)) {
      _seekTo(_layout.timeForX(details.localPosition.dx));
      return;
    }

    final hit = _layout.hitTestNoteIndex(_project.notes, details.localPosition);
    final shiftHeld = HardwareKeyboard.instance.isShiftPressed;
    if (hit != null) {
      if (!shiftHeld) {
        final now = DateTime.now();
        final isDoubleClick = _lastTapNoteIndex == hit &&
            _lastTapTime != null &&
            now.difference(_lastTapTime!) <= kDoubleTapTimeout;
        _lastTapNoteIndex = hit;
        _lastTapTime = now;
        if (isDoubleClick) {
          _lastTapNoteIndex = null;
          _lastTapTime = null;
          _deleteNoteAt(hit);
          return;
        }
      }
      if (shiftHeld) {
        // Toggle membership so shift-clicking an already-selected note
        // removes it from the selection instead of just no-oping.
        _selection.value = _selection.value.contains(hit)
            ? ({..._selection.value}..remove(hit))
            : {..._selection.value, hit};
      } else {
        _selection.value = {hit};
      }
      return;
    }

    _lastTapNoteIndex = null;
    _lastTapTime = null;

    // Shift-clicking empty space is presumably an attempt to extend the
    // selection that missed a note, not a request to add a new one.
    if (shiftHeld) return;

    final rawTime = _layout.timeForX(details.localPosition.dx);
    final time = _snapToGrid
        ? _tempo.snap(rawTime, subdivisionsPerBeat: _subdivisionsPerBeat)
        : rawTime;
    final string = _layout.stringForY(details.localPosition.dy);
    final newNote = TabNote(
      string: string,
      fret: 0,
      timeOffset: time,
      duration: const Duration(milliseconds: 400),
    );
    _updateNotes((notes) => notes..add(newNote));
    _selection.value = {_project.notes.length - 1};
  }

  void _handlePanStart(DragStartDetails details) {
    final hit = _layout.hitTestNoteIndex(_project.notes, details.localPosition);
    if (hit == null) {
      _dragOriginalNotes = null;
      _dragStartPosition = null;
      return;
    }
    // Dragging a note outside the current selection starts a fresh
    // single-note selection/drag rather than dragging the whole old group.
    if (!_selection.value.contains(hit)) {
      _selection.value = {hit};
    }
    _dragStartPosition = details.localPosition;
    _dragOriginalNotes = {
      for (final index in _selection.value) index: _project.notes[index],
    };
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    final originals = _dragOriginalNotes;
    final start = _dragStartPosition;
    if (originals == null || start == null) return;

    final pixelDx = details.localPosition.dx - start.dx;
    final pixelDy = details.localPosition.dy - start.dy;
    final deltaTime = Duration(
      microseconds:
          (pixelDx / _layout.pixelsPerSecond * Duration.microsecondsPerSecond)
              .round(),
    );
    final stringDelta = (pixelDy / _layout.stringSpacing).round();
    const stringOrder = TabTimelineLayout.stringOrderTopToBottom;

    // Pointer-move events fire far more often than the snapped grid cell
    // (or string row) actually changes — computing the would-be new values
    // first and bailing out here when nothing actually changed skips a
    // repaint (and an autosave-timer reset) for what would otherwise be a
    // no-op update.
    var changed = false;
    final updates = <int, TabNote>{};
    for (final entry in originals.entries) {
      var newTime = entry.value.timeOffset + deltaTime;
      if (newTime.isNegative) newTime = Duration.zero;
      if (_snapToGrid) {
        newTime = _tempo.snap(
          newTime,
          subdivisionsPerBeat: _subdivisionsPerBeat,
        );
      }
      final originalStringIndex = stringOrder.indexOf(entry.value.string);
      final newStringIndex = (originalStringIndex + stringDelta)
          .clamp(0, stringOrder.length - 1);
      final newString = stringOrder[newStringIndex];
      final current = _project.notes[entry.key];
      if (current.timeOffset != newTime || current.string != newString) {
        changed = true;
      }
      updates[entry.key] =
          current.copyWith(timeOffset: newTime, string: newString);
    }
    if (!changed) return;

    _updateNotes((notes) {
      for (final entry in updates.entries) {
        notes[entry.key] = entry.value;
      }
      return notes;
    });
  }

  void _handlePanEnd(DragEndDetails details) {
    _dragOriginalNotes = null;
    _dragStartPosition = null;
  }

  void _adjustFret(int delta) {
    if (_selection.value.isEmpty) return;
    _updateNotes((notes) {
      for (final index in _selection.value) {
        final current = notes[index];
        notes[index] = current.copyWith(fret: (current.fret + delta).clamp(0, 24));
      }
      return notes;
    });
  }

  void _deleteSelected() {
    if (_selection.value.isEmpty) return;
    final sortedDescending = _selection.value.toList()
      ..sort((a, b) => b.compareTo(a));
    _updateNotes((notes) {
      for (final index in sortedDescending) {
        notes.removeAt(index);
      }
      return notes;
    });
    _selection.value = const {};
  }

  /// Deletes a single note by index (double-click shortcut) — separate from
  /// [_deleteSelected] because the target isn't necessarily part of the
  /// current multi-selection, so the rest of the selection needs its
  /// indices shifted down rather than cleared.
  void _deleteNoteAt(int index) {
    _updateNotes((notes) => notes..removeAt(index));
    _selection.value = {
      for (final i in _selection.value)
        if (i != index) (i > index ? i - 1 : i),
    };
  }

  void _adjustHighlightBeats(int delta) {
    setState(() {
      _highlightBeats = (_highlightBeats + delta).clamp(1, 16);
    });
  }

  Future<void> _exportVideo() async {
    if (_isPlaying) {
      await _audio.pause();
    }
    final duration = _audioLoaded && _audio.duration != null
        ? _audio.duration!
        : _totalDuration;
    if (!mounted) return;
    await TabVideoExporter.exportChromaKey(
      context,
      notes: _project.notes,
      tempo: _tempo,
      totalDuration: duration,
      highlightBeats: _highlightBeats,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12131A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _project.title,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: _unsaved,
              builder: (context, unsaved, _) => Text(
                unsaved ? 'Unsaved changes…' : 'All changes saved',
                style: TextStyle(
                  fontSize: 11,
                  color: unsaved
                      ? Colors.amber.withValues(alpha: 0.85)
                      : Colors.white.withValues(alpha: 0.4),
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: 'Upload audio',
            onPressed: _pickAudio,
          ),
          IconButton(
            icon: const Icon(Icons.save_outlined),
            tooltip: 'Save now',
            onPressed: _saveProject,
          ),
          IconButton(
            icon: const Icon(Icons.movie_creation_outlined),
            tooltip: 'Export video',
            onPressed: _exportVideo,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: backgroundGradient),
        child: Column(
          children: [
            // Each of these glass panels (BackdropFilter blur, one of the
            // more expensive things Flutter can paint) is wrapped in its
            // own RepaintBoundary, so an unrelated rebuild elsewhere on the
            // screen can't force them to reconsider their (unchanged) blur.
            RepaintBoundary(child: _buildToolbar()),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Stack(
                  children: [
                    Positioned.fill(child: _buildTimelinePanel()),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 12,
                      child: Center(
                        child: RepaintBoundary(
                          child: AnimatedBuilder(
                            animation: Listenable.merge([_notes, _selection]),
                            builder: (context, _) => AnimatedSwitcher(
                              duration: const Duration(milliseconds: 180),
                              child: _selection.value.isEmpty
                                  ? const SizedBox.shrink(
                                      key: ValueKey('empty'),
                                    )
                                  : _buildFloatingEditPanel(
                                      key: const ValueKey('panel'),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            RepaintBoundary(child: _buildTransportBar()),
          ],
        ),
      ),
    );
  }

  /// The editing controls: tempo track, zoom, highlight width, snap. The
  /// tempo/meter chips act on whichever section the playhead is inside, so
  /// they're wrapped in a listener on the active marker rather than reading
  /// a single project-wide value.
  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: GlassPanel(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              InkWell(
                onTap: _pickAudio,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _audioLoaded ? Icons.graphic_eq : Icons.music_off,
                        size: 16,
                        color: Colors.white.withValues(alpha: 0.5),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _audioFileName ?? 'No audio — tap to upload',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _toolbarDivider(),
              ValueListenableBuilder<int>(
                valueListenable: _activeMarker,
                builder: (context, index, _) {
                  final marker = _tempo.markers[
                      index.clamp(0, _tempo.markers.length - 1)];
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _StepperChip(
                        label: 'Tempo',
                        value: _formatBpm(marker.bpm),
                        onDecrement: () => _adjustBpm(-1),
                        onIncrement: () => _adjustBpm(1),
                        onTapValue: _promptBpm,
                      ),
                      _toolbarDivider(),
                      _StepperChip(
                        label: 'Time',
                        value: '${marker.beatsPerMeasure}/4',
                        onDecrement: () => _adjustBeatsPerMeasure(-1),
                        onIncrement: () => _adjustBeatsPerMeasure(1),
                      ),
                    ],
                  );
                },
              ),
              _toolbarDivider(),
              _IconChip(
                icon: Icons.add_location_alt_outlined,
                label: 'Mark',
                tooltip: 'Add a tempo/meter change at the playhead',
                onTap: _addMarkerAtPlayhead,
              ),
              const SizedBox(width: 4),
              _IconChip(
                icon: Icons.timeline,
                label: 'Tempo map',
                tooltip: 'Edit every tempo marker',
                badge: _tempo.markers.length > 1
                    ? '${_tempo.markers.length}'
                    : null,
                onTap: _openTempoMap,
              ),
              _toolbarDivider(),
              _StepperChip(
                label: 'Zoom',
                value: '${(_pixelsPerSecond / _defaultZoom * 100).round()}%',
                onDecrement: () => _zoomBy(1 / _zoomStep),
                onIncrement: () => _zoomBy(_zoomStep),
                onTapValue: () => _setZoom(_defaultZoom),
              ),
              _toolbarDivider(),
              _StepperChip(
                label: 'Highlight',
                value:
                    '$_highlightBeats beat${_highlightBeats == 1 ? '' : 's'}',
                onDecrement: () => _adjustHighlightBeats(-1),
                onIncrement: () => _adjustHighlightBeats(1),
              ),
              _toolbarDivider(),
              _SnapToggleChip(
                enabled: _snapToGrid,
                onChanged: (value) => setState(() => _snapToGrid = value),
              ),
              _toolbarDivider(),
              Tooltip(
                message: 'Tap to add a note. Drag to move it. Shift+click to '
                    'multi-select. Double-click a note to delete it.\n'
                    'Click the waveform to seek; drag across it to set an '
                    'A–B loop.\nCtrl/Cmd + scroll to zoom.',
                child: Icon(
                  Icons.info_outline,
                  size: 18,
                  color: Colors.white.withValues(alpha: 0.35),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbarDivider() => Container(
        width: 1,
        height: 24,
        margin: const EdgeInsets.symmetric(horizontal: 10),
        color: Colors.white.withValues(alpha: 0.08),
      );

  /// The scrollable/gesture-driven timeline, wrapped in a solid dark panel
  /// surface (not blurred glass — this is a precision editing surface that
  /// repaints while playing, so a steady, high-contrast background matters
  /// more here than the glass look used for static chrome elsewhere).
  Widget _buildTimelinePanel() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF15161D),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: TabTimelineView(
          controller: _timelineScrollController,
          layout: _layout,
          notes: _notes,
          selection: _selection,
          playhead: _playhead,
          waveform: _waveform,
          loopRegion: _loopRegion,
          tempo: _tempo,
          subdivisionsPerBeat: _subdivisionsPerBeat,
          highlightBeats: _highlightBeats,
          totalSeconds: _totalSeconds,
          audioLoaded: _audioLoaded,
          hitTestNote: _hitTestNote,
          onTapUp: _handleTapUp,
          onPanStart: _handlePanStart,
          onPanUpdate: _handlePanUpdate,
          onPanEnd: _handlePanEnd,
          onLoopChanged: _handleLoopChanged,
          onLoopCommitted: _handleLoopCommitted,
          onZoomGesture: _handleZoomGesture,
        ),
      ),
    );
  }

  /// Playback transport: play/pause and scrubbing, plus the practice
  /// controls (speed, loop, click) that belong to *listening* rather than
  /// to editing. Reflows onto two rows on a narrow window rather than
  /// squeezing the scrub slider down to nothing.
  Widget _buildTransportBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: GlassPanel(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 780) {
              return Row(
                children: [
                  _buildPlayButton(),
                  const SizedBox(width: 4),
                  ..._buildScrubber(context),
                  const SizedBox(width: 8),
                  ..._buildPracticeControls(),
                ],
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    _buildPlayButton(),
                    const SizedBox(width: 4),
                    ..._buildScrubber(context),
                  ],
                ),
                SizedBox(
                  height: 40,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: _buildPracticeControls()),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildPlayButton() {
    return IconButton(
      iconSize: 30,
      icon: Icon(
        _countingIn
            ? Icons.hourglass_top
            : (_isPlaying
                ? Icons.pause_circle_filled
                : Icons.play_circle_fill),
        color: _audioLoaded
            ? accentColor
            : Colors.white.withValues(alpha: 0.25),
      ),
      tooltip: _isPlaying ? 'Pause' : 'Play',
      onPressed: _audioLoaded && !_countingIn ? _togglePlayback : null,
    );
  }

  /// Only the readout and the slider track the playhead, and only at the
  /// coarse rate — the buttons around them don't depend on it at all, so
  /// they stay out of the rebuilt subtree.
  List<Widget> _buildScrubber(BuildContext context) {
    return [
      ValueListenableBuilder<Duration>(
        valueListenable: _playheadCoarse,
        builder: (context, playhead, _) => Text(
          _formatDuration(playhead),
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 12,
          ),
        ),
      ),
      Expanded(
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: accentColor,
            thumbColor: accentColor,
            overlayColor: accentColor.withValues(alpha: 0.2),
            inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
          ),
          child: ValueListenableBuilder<Duration>(
            valueListenable: _playheadCoarse,
            builder: (context, playhead, _) => Slider(
              value: playhead.inMilliseconds
                  .clamp(0, (_totalSeconds * 1000).toInt())
                  .toDouble(),
              min: 0,
              max: _totalSeconds * 1000,
              onChangeStart: (_) => _isSeeking = true,
              onChanged: (value) {
                _setPlayhead(Duration(milliseconds: value.toInt()));
              },
              onChangeEnd: (value) {
                _isSeeking = false;
                _seekTo(Duration(milliseconds: value.toInt()));
              },
            ),
          ),
        ),
      ),
      Text(
        '${_totalSeconds.toStringAsFixed(1)}s',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.5),
          fontSize: 12,
        ),
      ),
    ];
  }

  List<Widget> _buildPracticeControls() {
    return [
      PopupMenuButton<double>(
        tooltip: 'Playback speed',
        initialValue: _playbackRate,
        onSelected: _setPlaybackRate,
        itemBuilder: (context) => [
          for (final rate in _speedPresets)
            PopupMenuItem(value: rate, child: Text('${_formatRate(rate)}×')),
        ],
        child: _TransportChip(
          icon: Icons.speed,
          label: '${_formatRate(_playbackRate)}×',
          active: _playbackRate != 1,
        ),
      ),
      const SizedBox(width: 6),
      ValueListenableBuilder<(double, double)?>(
        valueListenable: _loopRegion,
        builder: (context, loop, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: loop == null
                  ? 'Drag across the waveform to set an A–B loop'
                  : (_loopEnabled ? 'Looping on' : 'Looping off'),
              child: InkWell(
                onTap: loop == null ? null : _toggleLoop,
                borderRadius: BorderRadius.circular(20),
                child: _TransportChip(
                  icon: Icons.repeat,
                  label: loop == null
                      ? 'Loop'
                      : '${_formatSeconds(loop.$1)}–${_formatSeconds(loop.$2)}',
                  active: _loopEnabled && loop != null,
                  dimmed: loop == null,
                ),
              ),
            ),
            if (loop != null)
              IconButton(
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                tooltip: 'Clear loop',
                icon: Icon(
                  Icons.close,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
                onPressed: _clearLoop,
              ),
          ],
        ),
      ),
      const SizedBox(width: 6),
      Tooltip(
        message: 'Metronome click, following the tempo map',
        child: InkWell(
          onTap: _toggleMetronome,
          borderRadius: BorderRadius.circular(20),
          child: _TransportChip(
            icon: Icons.av_timer,
            label: 'Click',
            active: _metronomeEnabled,
          ),
        ),
      ),
      const SizedBox(width: 6),
      Tooltip(
        message: 'Count in one bar before playback starts',
        child: InkWell(
          onTap: () => setState(() => _countInEnabled = !_countInEnabled),
          borderRadius: BorderRadius.circular(20),
          child: _TransportChip(
            icon: Icons.timer_outlined,
            label: 'Count-in',
            active: _countInEnabled,
          ),
        ),
      ),
      if (_metronomeEnabled) ...[
        const SizedBox(width: 6),
        SizedBox(
          width: 90,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              activeTrackColor: accentColor,
              thumbColor: accentColor,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
            ),
            child: Slider(
              value: _metronome.volume,
              onChanged: (value) => setState(() => _metronome.volume = value),
            ),
          ),
        ),
      ],
    ];
  }

  /// The note-editing panel (fret +/-, delete) only exists while something
  /// is selected — floating over the bottom of the timeline instead of
  /// permanently reserving space that reads "No note selected" most of the
  /// time.
  Widget _buildFloatingEditPanel({Key? key}) {
    // Single-selection shows the exact string/fret; multi-selection shows a
    // count and lets fret +/- apply as a relative shift to every selected
    // note (their frets may differ, so there's no single value to display).
    final selection = _selection.value;
    final notes = _notes.value;
    final single = selection.length == 1 && selection.single < notes.length
        ? notes[selection.single]
        : null;
    return GlassPanel(
      key: key,
      borderColor: accentColor,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            single != null
                ? 'String ${single.string.name.toUpperCase()}'
                : '${selection.length} notes selected',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 14),
          const Text('Fret', style: TextStyle(color: Colors.white54, fontSize: 11)),
          _ChipIconButton(icon: Icons.remove, onPressed: () => _adjustFret(-1)),
          SizedBox(
            width: 26,
            child: Text(
              single != null ? '${single.fret}' : '±',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          _ChipIconButton(icon: Icons.add, onPressed: () => _adjustFret(1)),
          const SizedBox(width: 10),
          InkWell(
            onTap: _deleteSelected,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                  const SizedBox(width: 4),
                  Text(
                    single != null ? 'Delete' : 'Delete all',
                    style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) =>
      '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
}

String _formatBpm(double bpm) =>
    bpm == bpm.roundToDouble() ? bpm.toStringAsFixed(0) : bpm.toStringAsFixed(1);

String _formatRate(double rate) =>
    rate == rate.roundToDouble() ? rate.toStringAsFixed(0) : '$rate';

String _formatSeconds(double seconds) => '${seconds.toStringAsFixed(1)}s';

/// A labeled value with -/+ steppers, e.g. "Tempo  −  100  +". Shared by
/// the tempo/time-signature/zoom/highlight toolbar chips so they can't
/// visually drift apart from each other.
class _StepperChip extends StatelessWidget {
  const _StepperChip({
    required this.label,
    required this.value,
    required this.onDecrement,
    required this.onIncrement,
    this.onTapValue,
  });

  final String label;
  final String value;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;
  final VoidCallback? onTapValue;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.45),
            fontSize: 11,
          ),
        ),
        const SizedBox(width: 6),
        _ChipIconButton(icon: Icons.remove, onPressed: onDecrement),
        InkWell(
          onTap: onTapValue,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ),
        _ChipIconButton(icon: Icons.add, onPressed: onIncrement),
      ],
    );
  }
}

/// An icon + label toolbar action (as opposed to a value with steppers),
/// with an optional count badge.
class _IconChip extends StatelessWidget {
  const _IconChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.tooltip,
    this.badge,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? tooltip;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final chip = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: Colors.white.withValues(alpha: 0.65)),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.75),
              ),
            ),
            if (badge != null) ...[
              const SizedBox(width: 5),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  badge!,
                  style: const TextStyle(fontSize: 10, color: Colors.white),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    if (tooltip == null) return chip;
    return Tooltip(message: tooltip!, child: chip);
  }
}

/// A compact on/off pill for the transport bar's practice controls.
class _TransportChip extends StatelessWidget {
  const _TransportChip({
    required this.icon,
    required this.label,
    this.active = false,
    this.dimmed = false,
  });

  final IconData icon;
  final String label;
  final bool active;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final foreground = dimmed
        ? Colors.white.withValues(alpha: 0.3)
        : (active ? Colors.white : Colors.white.withValues(alpha: 0.6));
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: active
            ? accentColor.withValues(alpha: 0.25)
            : Colors.white.withValues(alpha: 0.05),
        border: Border.all(
          color: active
              ? accentColor.withValues(alpha: 0.6)
              : Colors.white.withValues(alpha: 0.12),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: active ? accentColor : foreground),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small round tap target used for the -/+ steppers and the floating edit
/// panel's fret adjusters — a compact alternative to a full `IconButton`
/// that fits the toolbar's tighter chip spacing.
class _ChipIconButton extends StatelessWidget {
  const _ChipIconButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Icon(
          icon,
          size: 15,
          color: Colors.white.withValues(alpha: 0.65),
        ),
      ),
    );
  }
}

/// The snap-to-grid toggle, styled as a pill that fills with the accent
/// color when enabled rather than a bare `Switch` + label — reads more
/// like a toolbar mode toggle (e.g. a DAW's magnet/snap icon) than a
/// settings checkbox.
class _SnapToggleChip extends StatelessWidget {
  const _SnapToggleChip({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!enabled),
      borderRadius: BorderRadius.circular(20),
      child: _TransportChip(
        icon: Icons.grid_4x4,
        label: 'Snap',
        active: enabled,
      ),
    );
  }
}
