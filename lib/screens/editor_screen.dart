import 'dart:async';

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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

class _EditorScreenState extends State<EditorScreen> {
  late TabProject _project;
  final _audio = AudioController();
  final _store = ProjectStore();
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<PlayerState>? _playerStateSub;

  Duration _playhead = Duration.zero;
  double _totalSeconds = 12.0;
  bool _audioLoaded = false;
  bool _isPlaying = false;
  bool _isSeeking = false;
  String? _audioFileName;
  Uint8List? _audioBytes;
  String? _audioExtension;
  int? _selectedIndex;
  int? _draggingIndex;
  int _highlightBeats = 4;
  final _timelineScrollController = ScrollController();

  static const _pixelsPerSecond = 120.0;
  static const _layout = TabTimelineLayout(
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

    _positionSub = _audio.positionStream.listen((position) {
      if (_isSeeking) return;
      setState(() => _playhead = position);
    });
    _durationSub = _audio.durationStream.listen((duration) {
      if (duration != null && duration.inMilliseconds > 0) {
        setState(() => _totalSeconds = duration.inMilliseconds / 1000);
      }
    });
    _playerStateSub = _audio.playerStateStream.listen((state) {
      setState(() => _isPlaying = state.playing);
      if (state.processingState == ProcessingState.completed) {
        setState(() {
          _isPlaying = false;
          _playhead = Duration.zero;
        });
        _audio.seek(Duration.zero);
      }
    });

    _restoreSavedProject();
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
    _timelineScrollController.dispose();
    super.dispose();
  }

  TabNote? get _selectedNote =>
      _selectedIndex == null ? null : _project.notes[_selectedIndex!];

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
      _playhead = Duration.zero;
    });
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
    if (hit != null) {
      setState(() => _selectedIndex = hit);
      return;
    }

    final time = _layout.snapToGrid(
      _layout.timeForX(details.localPosition.dx),
      _project.bpm,
    );
    final string = _layout.stringForY(details.localPosition.dy);
    final newNote = TabNote(
      string: string,
      fret: 0,
      timeOffset: time,
      duration: const Duration(milliseconds: 400),
    );
    _updateNotes((notes) => notes..add(newNote));
    setState(() => _selectedIndex = _project.notes.length - 1);
  }

  void _handlePanStart(DragStartDetails details) {
    _draggingIndex =
        _layout.hitTestNoteIndex(_project.notes, details.localPosition);
    if (_draggingIndex != null) {
      setState(() => _selectedIndex = _draggingIndex);
    }
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    final index = _draggingIndex;
    if (index == null) return;
    final time = _layout.snapToGrid(
      _layout.timeForX(details.localPosition.dx),
      _project.bpm,
    );
    final string = _layout.stringForY(details.localPosition.dy);
    _updateNotes((notes) {
      notes[index] = notes[index].copyWith(timeOffset: time, string: string);
      return notes;
    });
  }

  void _handlePanEnd(DragEndDetails details) {
    _draggingIndex = null;
  }

  void _adjustFret(int delta) {
    final index = _selectedIndex;
    if (index == null) return;
    _updateNotes((notes) {
      final current = notes[index];
      final newFret = (current.fret + delta).clamp(0, 24);
      notes[index] = current.copyWith(fret: newFret);
      return notes;
    });
  }

  void _deleteSelected() {
    final index = _selectedIndex;
    if (index == null) return;
    _updateNotes((notes) => notes..removeAt(index));
    setState(() => _selectedIndex = null);
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
                        child: CustomPaint(
                          painter: TabTimelinePainter(
                            notes: _project.notes,
                            layout: _layout,
                            playhead: _playhead,
                            bpm: _project.bpm,
                            totalSeconds: _totalSeconds,
                            beatsPerMeasure: _project.beatsPerMeasure,
                            highlightBeats: _highlightBeats,
                            selectedIndex: _selectedIndex,
                          ),
                          size:
                              Size(_totalSeconds * _pixelsPerSecond + 80, 220),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(_formatDuration(_playhead)),
                Expanded(
                  child: Slider(
                    value: _playhead.inMilliseconds
                        .clamp(0, (_totalSeconds * 1000).toInt())
                        .toDouble(),
                    min: 0,
                    max: _totalSeconds * 1000,
                    onChangeStart: (_) => _isSeeking = true,
                    onChanged: (value) {
                      setState(() {
                        _playhead = Duration(milliseconds: value.toInt());
                      });
                    },
                    onChangeEnd: (value) {
                      _isSeeking = false;
                      if (_audioLoaded) {
                        _audio.seek(Duration(milliseconds: value.toInt()));
                      }
                    },
                  ),
                ),
                Text('${_totalSeconds.toStringAsFixed(1)}s'),
              ],
            ),
            const SizedBox(height: 12),
            _buildEditPanel(),
          ],
        ),
      ),
    );
  }

  Widget _buildEditPanel() {
    final note = _selectedNote;
    if (note == null) {
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
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Text('String ${note.string.name.toUpperCase()}'),
          const SizedBox(width: 16),
          const Text('Fret:'),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: () => _adjustFret(-1),
          ),
          Text('${note.fret}', style: const TextStyle(fontSize: 16)),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => _adjustFret(1),
          ),
          const SizedBox(width: 16),
          TextButton.icon(
            onPressed: _deleteSelected,
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            label: const Text(
              'Delete',
              style: TextStyle(color: Colors.redAccent),
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
