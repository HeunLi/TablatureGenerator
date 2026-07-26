import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import '../audio/audio_controller.dart';
import '../export/tab_video_exporter.dart';
import '../models/tab_note.dart';
import '../models/tab_project.dart';
import '../persistence/project_store.dart';
import '../widgets/tab_timeline_layout.dart';
import '../widgets/tab_timeline_painter.dart';

/// A pan recognizer that only enters the gesture arena when the drag
/// actually starts on a note. Without this, a plain `onPan*` handler on the
/// timeline claims every drag (including ones meant to scroll the
/// horizontally-scrolling timeline), starving the ancestor
/// `SingleChildScrollView`'s drag recognizer and making the timeline
/// unscrollable. Rejecting the pointer outright (instead of accepting then
/// losing) lets the scroll view's recognizer win those drags instead.
class _NoteDragGestureRecognizer extends PanGestureRecognizer {
  _NoteDragGestureRecognizer({required this.hitTest});

  final bool Function(Offset localPosition) hitTest;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (!hitTest(event.localPosition)) return;
    super.addAllowedPointer(event);
  }
}

/// Editor screen: tap the timeline to add notes, drag existing notes to
/// reposition them (time + string), use the side panel to edit the
/// fret/duration of whichever note is selected, and upload an audio file
/// to play back with the tab highlighting in sync.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen>
    with SingleTickerProviderStateMixin {
  late TabProject _project;
  final _audio = AudioController();
  final _store = ProjectStore();
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<PlayerState>? _playerStateSub;

  // A ValueNotifier, not a plain field: it's updated every animation frame
  // during playback (see [_ticker]), and driving that through setState
  // would rebuild the entire screen (toolbar, controls, etc.) 60 times a
  // second. Only the CustomPaint subtree listens to this directly (see
  // build()), so a tick only ever repaints the timeline itself.
  final _playhead = ValueNotifier<Duration>(Duration.zero);

  // just_audio's positionStream does not fire every frame — browsers
  // commonly throttle real <audio> element position updates to a handful
  // of times per second — so driving the red playhead line directly from
  // it makes it visibly jump between updates instead of gliding. Instead,
  // each positionStream event is only used to (re)anchor `_lastKnownPosition`
  // + restart `_positionClock`; a per-frame `Ticker` then interpolates the
  // displayed position as `_lastKnownPosition + _positionClock.elapsed`,
  // which is smooth by construction and gets nudged back in sync every
  // time a real update arrives (correcting for any audio clock drift).
  Duration _lastKnownPosition = Duration.zero;
  final _positionClock = Stopwatch();
  late final Ticker _ticker;
  double _totalSeconds = 12.0;
  bool _audioLoaded = false;
  bool _isPlaying = false;
  bool _isSeeking = false;
  String? _audioFileName;
  Uint8List? _audioBytes;
  String? _audioExtension;
  // Shift+click toggles membership in this set instead of replacing it,
  // for selecting multiple notes at once. A plain click replaces it with a
  // single-element set.
  Set<int> _selectedIndices = {};

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

  // When off, notes are placed/dragged at the exact clicked time instead of
  // being forced onto the BPM-derived grid — needed for tracks whose real
  // tempo doesn't precisely match the set BPM (or has any rubato/human
  // timing drift), where grid-snapping otherwise pulls every note off its
  // true audio position.
  bool _snapToGrid = true;
  final _timelineScrollController = ScrollController();

  // The buffered [start, end] time range (seconds) that the timeline
  // painter actually draws — see [_recomputeWindow]. Defaults match the
  // initial `_totalSeconds` placeholder until the first layout/scroll
  // recomputes them for the real viewport.
  double _windowStart = 0;
  double _windowEnd = 12;

  // Screen width is anchored to a fixed pixels-*per-beat*, not a fixed
  // pixels-per-second. At a fixed pixels-per-second, a higher BPM packs
  // more beats into the same horizontal space — the grid visually
  // compresses and note placement gets fiddly even though nothing about
  // the window changed. Deriving pixelsPerSecond from BPM keeps each beat
  // the same width on screen regardless of tempo; the timeline just gets
  // longer (more to scroll) at higher BPM instead of denser.
  // 72 px/beat matches the previous fixed 120px/sec at the old default of
  // 100 BPM, so the default view is unchanged.
  static const _pixelsPerBeat = 72.0;
  double get _pixelsPerSecond => _pixelsPerBeat * _project.bpm / 60;
  TabTimelineLayout get _layout => TabTimelineLayout(
        pixelsPerSecond: _pixelsPerSecond,
        stringSpacing: 48,
        topPadding: 40,
        leftPadding: 40,
      );

  @override
  void initState() {
    super.initState();
    _project = TabProject(
      title: 'Untitled',
      bpm: 100,
      notes: [
        TabNote(
          string: BassString.e,
          fret: 3,
          timeOffset: const Duration(milliseconds: 0),
          duration: const Duration(milliseconds: 500),
        ),
        TabNote(
          string: BassString.a,
          fret: 2,
          timeOffset: const Duration(milliseconds: 600),
          duration: const Duration(milliseconds: 500),
        ),
        TabNote(
          string: BassString.d,
          fret: 0,
          timeOffset: const Duration(milliseconds: 1200),
          duration: const Duration(milliseconds: 500),
        ),
        TabNote(
          string: BassString.g,
          fret: 5,
          timeOffset: const Duration(milliseconds: 1800),
          duration: const Duration(milliseconds: 700),
        ),
        TabNote(
          string: BassString.e,
          fret: 3,
          timeOffset: const Duration(milliseconds: 2600),
          duration: const Duration(milliseconds: 500),
        ),
      ],
    );

    // A real update is a correction, not the thing that moves the line —
    // see the field docs on `_ticker` for why.
    _positionSub = _audio.positionStream.listen((position) {
      if (_isSeeking) return;
      _lastKnownPosition = position;
      _positionClock
        ..reset()
        ..start();
      if (!_isPlaying) {
        // The ticker isn't advancing it, so apply this directly (e.g. a
        // late event arriving right as playback paused).
        _playhead.value = position;
      }
    });
    _durationSub = _audio.durationStream.listen((duration) {
      if (duration != null && duration.inMilliseconds > 0) {
        setState(() {
          _totalSeconds = duration.inMilliseconds / 1000;
          _recomputeWindow();
        });
      }
    });
    _playerStateSub = _audio.playerStateStream.listen((state) {
      setState(() => _isPlaying = state.playing);
      if (state.playing) {
        _positionClock
          ..reset()
          ..start();
        _ticker.start();
      } else {
        _positionClock.stop();
        _ticker.stop();
      }
      if (state.processingState == ProcessingState.completed) {
        setState(() => _isPlaying = false);
        _positionClock.stop();
        _ticker.stop();
        _lastKnownPosition = Duration.zero;
        _playhead.value = Duration.zero;
        _audio.seek(Duration.zero);
      }
    });

    // A running Ticker makes Flutter keep pumping frames at the display's
    // full refresh rate for as long as it's running, so it's only started
    // while actually playing (above) rather than for the widget's whole
    // lifetime — otherwise we'd be undoing the point of this by burning
    // frames continuously even while paused/idle.
    _ticker = createTicker(_onTick);

    _timelineScrollController.addListener(_handleScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(_recomputeWindow);
    });

    _restoreSavedProject();
  }

  void _onTick(Duration elapsed) {
    if (!_isPlaying || _isSeeking) return;
    _playhead.value = _lastKnownPosition + _positionClock.elapsed;
  }

  Future<void> _restoreSavedProject() async {
    await _store.init();
    final saved = _store.load();
    if (saved == null) return;

    setState(() {
      _project = saved.project;
      _audioBytes = saved.audioBytes;
      _audioExtension = saved.audioExtension;
    });

    if (saved.audioBytes != null && saved.audioExtension != null) {
      await _audio.loadFromBytes(saved.audioBytes!, saved.audioExtension!);
      setState(() {
        _audioFileName = 'restored audio';
        _audioLoaded = true;
      });
    }
  }

  Future<void> _saveProject() async {
    await _store.save(
      _project,
      audioBytes: _audioBytes,
      audioExtension: _audioExtension,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Project saved locally'), duration: Duration(seconds: 1)),
    );
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playerStateSub?.cancel();
    _audio.dispose();
    _ticker.dispose();
    _timelineScrollController.removeListener(_handleScroll);
    _timelineScrollController.dispose();
    _playhead.dispose();
    super.dispose();
  }

  // How many extra viewport-widths of buffer to keep rendered beyond each
  // edge of the visible area, so small scrolls don't force an immediate
  // re-render — only scrolling far enough to approach the buffer's edge
  // does.
  static const _windowBufferScreens = 2.0;

  /// Recomputes the buffered [_windowStart, _windowEnd] time range that
  /// [TabTimelinePainter] actually draws, centered on whatever's currently
  /// visible in the scroll view. Without this, painting scales with the
  /// *entire* track's grid/notes every repaint — fine for the ~12s
  /// placeholder, but a real multi-minute MP3 turns every playhead tick
  /// during playback into thousands of wasted off-screen draw calls.
  /// Bounding the drawn range to "visible plus a buffer" makes per-repaint
  /// cost scale with viewport size instead of track length.
  void _recomputeWindow() {
    if (!_timelineScrollController.hasClients) return;
    final position = _timelineScrollController.position;
    final viewportSeconds = position.viewportDimension / _pixelsPerSecond;
    final visibleStart = position.pixels / _pixelsPerSecond;
    final visibleEnd = visibleStart + viewportSeconds;
    _windowStart = (visibleStart - viewportSeconds * _windowBufferScreens)
        .clamp(0, double.infinity);
    _windowEnd = visibleEnd + viewportSeconds * _windowBufferScreens;
  }

  /// Only recomputes (and thus repaints) once the visible viewport gets
  /// close to the edge of the already-rendered buffer, not on every scroll
  /// pixel — scrolling within the buffer needs no repaint at all.
  void _handleScroll() {
    if (!_timelineScrollController.hasClients) return;
    final position = _timelineScrollController.position;
    final viewportSeconds = position.viewportDimension / _pixelsPerSecond;
    final visibleStart = position.pixels / _pixelsPerSecond;
    final visibleEnd = visibleStart + viewportSeconds;
    final nearEdge = visibleStart < _windowStart + viewportSeconds * 0.5 ||
        visibleEnd > _windowEnd - viewportSeconds * 0.5;
    if (!nearEdge) return;
    setState(_recomputeWindow);
  }


  void _updateNotes(List<TabNote> Function(List<TabNote>) transform) {
    setState(() {
      _project = _project.copyWith(notes: transform([..._project.notes]));
    });
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
    setState(() {
      _audioFileName = file.name;
      _audioBytes = bytes;
      _audioExtension = extension;
      _audioLoaded = true;
    });
    _lastKnownPosition = Duration.zero;
    _playhead.value = Duration.zero;
  }

  Future<void> _togglePlayback() async {
    if (_isPlaying) {
      await _audio.pause();
    } else {
      await _audio.play();
    }
  }

  Future<void> _exportVideo() async {
    if (_isPlaying) {
      await _audio.pause();
    }
    final duration = _audioLoaded && _audio.duration != null
        ? _audio.duration!
        : Duration(milliseconds: (_totalSeconds * 1000).round());
    if (!mounted) return;
    await TabVideoExporter.exportChromaKey(
      context,
      notes: _project.notes,
      bpm: _project.bpm,
      totalDuration: duration,
      beatsPerMeasure: _project.beatsPerMeasure,
      highlightBeats: _highlightBeats,
    );
  }

  void _adjustHighlightBeats(int delta) {
    setState(() {
      _highlightBeats = (_highlightBeats + delta).clamp(1, 16);
    });
  }

  void _adjustBeatsPerMeasure(int delta) {
    setState(() {
      _project = _project.copyWith(
        beatsPerMeasure: (_project.beatsPerMeasure + delta).clamp(1, 12),
      );
    });
  }

  /// Grid snapping ([TabTimelineLayout.snapToGrid]) and the highlight
  /// block's width ([TabTimelineLayout.beatBlockBoundsSeconds]) are both
  /// already derived from `bpm`, so changing it here immediately reflows
  /// where notes snap to and how fast the highlight block sweeps through
  /// beats — no other state needs to change.
  void _adjustBpm(double delta) {
    setState(() {
      _project = _project.copyWith(bpm: (_project.bpm + delta).clamp(20, 300));
      // pixelsPerSecond is derived from bpm, so the buffered window (which
      // is computed in seconds from the fixed pixel viewport) needs to be
      // recomputed too, or it'll no longer line up with what's on screen.
      _recomputeWindow();
    });
  }

  /// Stepping by 1 to reach an arbitrary tempo (e.g. 139) from the default
  /// is tedious, so the BPM readout itself is tappable to type an exact
  /// value directly.
  Future<void> _promptBpm() async {
    final controller =
        TextEditingController(text: _project.bpm.toStringAsFixed(0));
    final result = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Set BPM'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(),
          // Popping the dialog synchronously inside onSubmitted tears down
          // the field's focus scope while EditableText is still in the
          // middle of its own submit handling, which trips a framework
          // assertion ("_dependents.isEmpty is not true"). A microtask
          // still runs before the frame finishes; waiting for the next
          // full frame via addPostFrameCallback lets that finish first.
          onSubmitted: (value) {
            final parsed = double.tryParse(value);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) Navigator.of(context).pop(parsed);
            });
          },
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
    if (result == null) return;
    setState(() {
      _project = _project.copyWith(bpm: result.clamp(20, 300));
      _recomputeWindow();
    });
  }

  /// Flutter's `Scrollable` only maps mouse-wheel *vertical* motion
  /// (`scrollDelta.dy`) onto a scroll axis when that axis is vertical — our
  /// timeline scrolls horizontally, so the default wheel handling ignores
  /// `dy` entirely and the wheel does nothing. This routes vertical wheel
  /// deltas onto the horizontal scroll controller ourselves. Horizontal
  /// wheel/trackpad deltas (`dx`) are left alone; the built-in handling
  /// already applies those to the horizontal axis correctly.
  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && event.scrollDelta.dy != 0) {
      GestureBinding.instance.pointerSignalResolver
          .register(event, _handleWheelScroll);
    }
  }

  void _handleWheelScroll(PointerSignalEvent event) {
    final controller = _timelineScrollController;
    if (!controller.hasClients) return;
    final scrollEvent = event as PointerScrollEvent;
    final position = controller.position;
    final target = (position.pixels + scrollEvent.scrollDelta.dy)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    controller.jumpTo(target);
  }

  void _handleTapUp(TapUpDetails details) {
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
      setState(() {
        if (shiftHeld) {
          // Toggle membership so shift-clicking an already-selected note
          // removes it from the selection instead of just no-oping.
          _selectedIndices = _selectedIndices.contains(hit)
              ? ({..._selectedIndices}..remove(hit))
              : {..._selectedIndices, hit};
        } else {
          _selectedIndices = {hit};
        }
      });
      return;
    }

    _lastTapNoteIndex = null;
    _lastTapTime = null;

    // Shift-clicking empty space is presumably an attempt to extend the
    // selection that missed a note, not a request to add a new one.
    if (shiftHeld) return;

    final rawTime = _layout.timeForX(details.localPosition.dx);
    final time = _snapToGrid
        ? _layout.snapToGrid(rawTime, _project.bpm)
        : rawTime;
    final string = _layout.stringForY(details.localPosition.dy);
    final newNote = TabNote(
      string: string,
      fret: 0,
      timeOffset: time,
      duration: const Duration(milliseconds: 400),
    );
    _updateNotes((notes) => notes..add(newNote));
    setState(() => _selectedIndices = {_project.notes.length - 1});
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
    if (!_selectedIndices.contains(hit)) {
      setState(() => _selectedIndices = {hit});
    }
    _dragStartPosition = details.localPosition;
    _dragOriginalNotes = {
      for (final index in _selectedIndices) index: _project.notes[index],
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

    _updateNotes((notes) {
      for (final entry in originals.entries) {
        var newTime = entry.value.timeOffset + deltaTime;
        if (newTime.isNegative) newTime = Duration.zero;
        if (_snapToGrid) newTime = _layout.snapToGrid(newTime, _project.bpm);
        final originalStringIndex = stringOrder.indexOf(entry.value.string);
        final newStringIndex = (originalStringIndex + stringDelta)
            .clamp(0, stringOrder.length - 1);
        notes[entry.key] = notes[entry.key].copyWith(
          timeOffset: newTime,
          string: stringOrder[newStringIndex],
        );
      }
      return notes;
    });
  }

  void _handlePanEnd(DragEndDetails details) {
    _dragOriginalNotes = null;
    _dragStartPosition = null;
  }

  void _adjustFret(int delta) {
    if (_selectedIndices.isEmpty) return;
    _updateNotes((notes) {
      for (final index in _selectedIndices) {
        final current = notes[index];
        notes[index] = current.copyWith(fret: (current.fret + delta).clamp(0, 24));
      }
      return notes;
    });
  }

  void _deleteSelected() {
    if (_selectedIndices.isEmpty) return;
    final sortedDescending = _selectedIndices.toList()
      ..sort((a, b) => b.compareTo(a));
    _updateNotes((notes) {
      for (final index in sortedDescending) {
        notes.removeAt(index);
      }
      return notes;
    });
    setState(() => _selectedIndices = {});
  }

  /// Deletes a single note by index (double-click shortcut) — separate from
  /// [_deleteSelected] because the target isn't necessarily part of the
  /// current multi-selection, so the rest of the selection needs its
  /// indices shifted down rather than cleared.
  void _deleteNoteAt(int index) {
    _updateNotes((notes) => notes..removeAt(index));
    setState(() {
      _selectedIndices = {
        for (final i in _selectedIndices)
          if (i != index) (i > index ? i - 1 : i),
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Bass Tab Studio — ${_project.title}'),
        actions: [
          if (_audioLoaded)
            IconButton(
              icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
              tooltip: _isPlaying ? 'Pause' : 'Play',
              onPressed: _togglePlayback,
            ),
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: 'Upload audio',
            onPressed: _pickAudio,
          ),
          IconButton(
            icon: const Icon(Icons.save_outlined),
            tooltip: 'Save project locally',
            onPressed: _saveProject,
          ),
          IconButton(
            icon: const Icon(Icons.movie_creation_outlined),
            tooltip: 'Export chroma-key video',
            onPressed: _exportVideo,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _audioFileName == null
                  ? 'No audio loaded — tap the upload icon to sync a track.'
                  : 'Synced to: $_audioFileName',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 4),
            const Text(
              'Tap the grid to add a note. Drag a note to move it. '
              'Select a note to edit its fret or delete it.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: 4,
              children: [
                const Text(
                  'BPM:',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                IconButton(
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => _adjustBpm(-1),
                ),
                InkWell(
                  onTap: _promptBpm,
                  child: Text(
                    _project.bpm.toStringAsFixed(0),
                    style: const TextStyle(
                      fontSize: 13,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
                IconButton(
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () => _adjustBpm(1),
                ),
                const SizedBox(width: 16),
                const Text(
                  'Time signature:',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                IconButton(
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => _adjustBeatsPerMeasure(-1),
                ),
                Text(
                  '${_project.beatsPerMeasure}/4',
                  style: const TextStyle(fontSize: 13),
                ),
                IconButton(
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () => _adjustBeatsPerMeasure(1),
                ),
                const SizedBox(width: 16),
                const Text(
                  'Highlight:',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                IconButton(
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => _adjustHighlightBeats(-1),
                ),
                Text(
                  '$_highlightBeats beat${_highlightBeats == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 13),
                ),
                IconButton(
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () => _adjustHighlightBeats(1),
                ),
                const SizedBox(width: 16),
                const Text(
                  'Snap to grid:',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                Switch(
                  value: _snapToGrid,
                  onChanged: (value) => setState(() => _snapToGrid = value),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Listener(
                onPointerSignal: _handlePointerSignal,
                child: Scrollbar(
                  controller: _timelineScrollController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _timelineScrollController,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: _totalSeconds * _pixelsPerSecond + 80,
                      child: RawGestureDetector(
                        behavior: HitTestBehavior.opaque,
                        gestures: {
                          TapGestureRecognizer:
                              GestureRecognizerFactoryWithHandlers<
                                  TapGestureRecognizer>(
                            () => TapGestureRecognizer(),
                            (instance) => instance.onTapUp = _handleTapUp,
                          ),
                          _NoteDragGestureRecognizer:
                              GestureRecognizerFactoryWithHandlers<
                                  _NoteDragGestureRecognizer>(
                            () => _NoteDragGestureRecognizer(
                              hitTest: (position) =>
                                  _layout.hitTestNoteIndex(
                                    _project.notes,
                                    position,
                                  ) !=
                                  null,
                            ),
                            (instance) {
                              instance
                                ..onStart = _handlePanStart
                                ..onUpdate = _handlePanUpdate
                                ..onEnd = _handlePanEnd;
                            },
                          ),
                        },
                        // Scoping the playhead subscription to just this
                        // leaf means a playhead tick during playback only
                        // ever repaints the timeline itself — the toolbar,
                        // controls, scrollbar, and gesture detector above
                        // never rebuild for it.
                        child: ValueListenableBuilder<Duration>(
                          valueListenable: _playhead,
                          builder: (context, playhead, _) => CustomPaint(
                            painter: TabTimelinePainter(
                              notes: _project.notes,
                              layout: _layout,
                              playhead: playhead,
                              bpm: _project.bpm,
                              totalSeconds: _totalSeconds,
                              beatsPerMeasure: _project.beatsPerMeasure,
                              highlightBeats: _highlightBeats,
                              selectedIndices: _selectedIndices,
                              windowStartSeconds: _windowStart,
                              windowEndSeconds: _windowEnd,
                            ),
                            size: Size(
                              _totalSeconds * _pixelsPerSecond + 80,
                              220,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<Duration>(
              valueListenable: _playhead,
              builder: (context, playhead, _) => Row(
                children: [
                  Text(_formatDuration(playhead)),
                  Expanded(
                    child: Slider(
                      value: playhead.inMilliseconds
                          .clamp(0, (_totalSeconds * 1000).toInt())
                          .toDouble(),
                      min: 0,
                      max: _totalSeconds * 1000,
                      onChangeStart: (_) => _isSeeking = true,
                      onChanged: (value) {
                        _playhead.value = Duration(milliseconds: value.toInt());
                      },
                      onChangeEnd: (value) {
                        _isSeeking = false;
                        final sought = Duration(milliseconds: value.toInt());
                        // Re-anchor immediately rather than waiting for the
                        // next positionStream event, so pressing play right
                        // after a seek doesn't extrapolate from stale data.
                        _lastKnownPosition = sought;
                        _positionClock
                          ..reset()
                          ..start();
                        if (_audioLoaded) {
                          _audio.seek(sought);
                        }
                      },
                    ),
                  ),
                  Text('${_totalSeconds.toStringAsFixed(1)}s'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _buildEditPanel(),
          ],
        ),
      ),
    );
  }

  Widget _buildEditPanel() {
    if (_selectedIndices.isEmpty) {
      return const SizedBox(
        height: 48,
        child: Center(
          child: Text(
            'No note selected',
            style: TextStyle(color: Colors.white38),
          ),
        ),
      );
    }
    // Single-selection shows the exact string/fret; multi-selection shows a
    // count and lets fret +/- apply as a relative shift to every selected
    // note (their frets may differ, so there's no single value to display).
    final single = _selectedIndices.length == 1
        ? _project.notes[_selectedIndices.single]
        : null;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Text(single != null
              ? 'String ${single.string.name.toUpperCase()}'
              : '${_selectedIndices.length} notes selected'),
          const SizedBox(width: 16),
          const Text('Fret:'),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: () => _adjustFret(-1),
          ),
          Text(single != null ? '${single.fret}' : '±',
              style: const TextStyle(fontSize: 16)),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => _adjustFret(1),
          ),
          const SizedBox(width: 16),
          TextButton.icon(
            onPressed: _deleteSelected,
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            label: Text(
              single != null ? 'Delete' : 'Delete all',
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final seconds = d.inMilliseconds / 1000;
    return '${seconds.toStringAsFixed(1)}s';
  }
}
