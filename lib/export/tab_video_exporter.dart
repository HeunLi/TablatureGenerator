import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../models/tab_note.dart';
import 'canvas_tab_renderer.dart';
import 'webm_muxer.dart';

/// Renders the tab to a chroma-key (solid background) WebM video, timed to
/// match [totalDuration], and triggers a browser download.
///
/// Real transparency isn't achievable via MediaRecorder in browsers, so we
/// render on a solid, distinct green background instead — the resulting
/// clip drops into any video editor and gets keyed out like a green screen.
///
/// Frames are painted straight onto a native `<canvas>` via
/// [CanvasTabRenderer] instead of through Flutter's `dart:ui` rendering —
/// no widget tree, no GPU readback per frame. That readback (not the
/// pacing model below) was the actual export bottleneck.
///
/// Two export paths:
///  - **Fast path**: encodes frames directly with the WebCodecs
///    `VideoEncoder` API and muxes them ourselves ([WebmMuxer]), with no
///    real-time pacing — export runs as fast as painting + encoding
///    allows instead of being locked to the track's actual duration.
///    Chromium-only.
///  - **Fallback path**: the original `MediaRecorder`-based real-time
///    capture, used when WebCodecs isn't available.
class TabVideoExporter {
  static Future<void> exportChromaKey(
    BuildContext context, {
    required List<TabNote> notes,
    required double bpm,
    required Duration totalDuration,
    required int beatsPerMeasure,
    required int highlightBeats,
  }) async {
    final settings = await showDialog<_ExportSettings>(
      context: context,
      builder: (_) => const _ExportSettingsDialog(),
    );
    if (settings == null || !context.mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ExportDialog(
        notes: notes,
        bpm: bpm,
        totalDuration: totalDuration,
        beatsPerMeasure: beatsPerMeasure,
        measuresPerWindow: settings.measuresPerWindow,
        highlightBeats: highlightBeats,
        showPlayhead: settings.showPlayhead,
        backgroundColor: settings.backgroundColor,
      ),
    );
  }
}

/// Result of [_ExportSettingsDialog].
class _ExportSettings {
  const _ExportSettings({
    required this.measuresPerWindow,
    required this.showPlayhead,
    required this.backgroundColor,
  });

  final int measuresPerWindow;
  final bool showPlayhead;

  /// CSS hex color string, e.g. '#FFFFFF'.
  final String backgroundColor;
}

/// Lets the user pick how many measures are visible per page, and whether
/// the sweeping playhead line (and its accompanying highlight block) shows
/// up in the rendered video, before rendering starts. Time signature and
/// highlight-block size aren't asked here — they're already set in the
/// editor, so export just uses those directly rather than making the user
/// configure them twice.
class _ExportSettingsDialog extends StatefulWidget {
  const _ExportSettingsDialog();

  @override
  State<_ExportSettingsDialog> createState() => _ExportSettingsDialogState();
}

class _ExportSettingsDialogState extends State<_ExportSettingsDialog> {
  static const _minWindow = 2;
  static const _maxWindow = 12;
  static const _presetColors = {
    'White': '#FFFFFF',
    'Chroma green': '#00B140',
    'Chroma blue': '#0047AB',
    'Black': '#000000',
  };
  static final _hexPattern = RegExp(r'^#[0-9A-Fa-f]{6}$');

  int _measuresPerWindow = 6;
  bool _showPlayhead = true;
  String _backgroundColorHex = '#FFFFFF';
  late final _colorController = TextEditingController(text: _backgroundColorHex);

  void _adjustWindow(int delta) {
    setState(() {
      _measuresPerWindow = (_measuresPerWindow + delta).clamp(
        _minWindow,
        _maxWindow,
      );
    });
  }

  void _setBackgroundColor(String hex) {
    setState(() {
      _backgroundColorHex = hex;
      _colorController.text = hex;
    });
  }

  void _onHexChanged(String value) {
    final trimmed = value.trim();
    final normalized = trimmed.startsWith('#') ? trimmed : '#$trimmed';
    if (_hexPattern.hasMatch(normalized)) {
      setState(() => _backgroundColorHex = normalized.toUpperCase());
    }
  }

  Color _colorFromHex(String hex) =>
      Color(int.parse('FF${hex.substring(1)}', radix: 16));

  @override
  void dispose() {
    _colorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Export settings'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Measures visible per page. The video jumps to the next page '
            'once playback moves past the last measure shown.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () => _adjustWindow(-1),
              ),
              SizedBox(
                width: 48,
                child: Text(
                  '$_measuresPerWindow',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 20),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => _adjustWindow(1),
              ),
            ],
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _showPlayhead,
            onChanged: (value) =>
                setState(() => _showPlayhead = value ?? true),
            title: const Text('Show playhead line', style: TextStyle(fontSize: 14)),
            subtitle: const Text(
              'The amber beat-highlight block stays either way.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(height: 8),
          const Text('Background color', style: TextStyle(fontSize: 13)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in _presetColors.entries)
                _ColorSwatch(
                  color: _colorFromHex(entry.value),
                  selected: _backgroundColorHex == entry.value,
                  tooltip: entry.key,
                  onTap: () => _setBackgroundColor(entry.value),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: _hexPattern.hasMatch(_backgroundColorHex)
                      ? _colorFromHex(_backgroundColorHex)
                      : Colors.transparent,
                  border: Border.all(color: Colors.white24),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _colorController,
                  decoration: const InputDecoration(
                    labelText: 'Hex color',
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 14),
                  onChanged: _onHexChanged,
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _ExportSettings(
              measuresPerWindow: _measuresPerWindow,
              showPlayhead: _showPlayhead,
              backgroundColor: _backgroundColorHex,
            ),
          ),
          child: const Text('Start Export'),
        ),
      ],
    );
  }
}

/// A small tappable color circle used for background-color presets.
class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.selected,
    required this.tooltip,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? Colors.blueAccent : Colors.white24,
              width: selected ? 2 : 1,
            ),
          ),
          child: selected
              ? Icon(
                  Icons.check,
                  size: 16,
                  color: color.computeLuminance() > 0.5
                      ? Colors.black
                      : Colors.white,
                )
              : null,
        ),
      ),
    );
  }
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({
    required this.notes,
    required this.bpm,
    required this.totalDuration,
    required this.beatsPerMeasure,
    required this.measuresPerWindow,
    required this.highlightBeats,
    required this.showPlayhead,
    required this.backgroundColor,
  });

  final List<TabNote> notes;
  final double bpm;
  final Duration totalDuration;
  final int beatsPerMeasure;
  final int measuresPerWindow;
  final int highlightBeats;
  final bool showPlayhead;
  final String backgroundColor;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

typedef _FastPathHandles = ({web.VideoEncoder encoder, WebmMuxer muxer});

class _ExportDialogState extends State<_ExportDialog> {
  static const _fps = 24;
  static const _height = 220;
  static const _pixelsPerSecond = 140.0;
  static const _leftPadding = 60.0;
  static const _rightPadding = 60.0;
  static const _keyFrameIntervalFrames = 96; // ~every 4s at 24fps

  // Layout only ever shows widget.measuresPerWindow measures at once (see
  // CanvasTabRenderer) rather than the whole clip, so canvas width only
  // needs to fit one window's worth of time at a legible, fixed spacing —
  // it no longer has to shrink to accommodate arbitrarily long tracks.
  late final int _width = () {
    final measureSeconds = widget.beatsPerMeasure * 60 / widget.bpm;
    final windowSeconds = measureSeconds * widget.measuresPerWindow;
    return (_leftPadding + windowSeconds * _pixelsPerSecond + _rightPadding)
        .round();
  }();

  double _progress = 0;
  String _status = 'Preparing…';
  String? _error;
  bool? _usingFastPath;
  String? _fastPathUnavailableReason;

  late web.HTMLCanvasElement _canvas;
  late web.CanvasRenderingContext2D _ctx;
  late web.MediaRecorder _recorder;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  int get _totalFrames => (widget.totalDuration.inMilliseconds * _fps / 1000)
      .ceil()
      .clamp(1, 1 << 30);

  Future<void> _run() async {
    try {
      _canvas = web.document.createElement('canvas') as web.HTMLCanvasElement;
      _canvas.width = _width;
      _canvas.height = _height;
      _ctx = _canvas.getContext('2d')! as web.CanvasRenderingContext2D;

      final fast = await _tryPrepareFastPath();
      setState(() => _usingFastPath = fast != null);

      final blob = fast != null
          ? await _runFastExport(fast.encoder, fast.muxer)
          : await _runRealtimeExport();

      _downloadBlob(blob);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  // --- Fast path: WebCodecs VideoEncoder, no real-time pacing ---

  web.VideoEncoderConfig _buildConfig({required bool preferHardware}) {
    return web.VideoEncoderConfig(
      codec: 'vp8',
      width: _width,
      height: _height,
      bitrate: 3000000,
      framerate: _fps,
      // Faster/cheaper encoder preset over max compression efficiency —
      // export speed matters far more than bitrate here.
      hardwareAcceleration: preferHardware ? 'prefer-hardware' : 'no-preference',
      latencyMode: 'realtime',
    );
  }

  Future<_FastPathHandles?> _tryPrepareFastPath() async {
    try {
      // Try a hardware encoder first (much faster if the GPU has one); if
      // the browser doesn't report that combo as supported, fall back to
      // an unconstrained config rather than giving up on the fast path.
      var config = _buildConfig(preferHardware: true);
      var support = await web.VideoEncoder.isConfigSupported(config).toDart;
      if (!support.supported) {
        config = _buildConfig(preferHardware: false);
        support = await web.VideoEncoder.isConfigSupported(config).toDart;
      }
      if (!support.supported) {
        _fastPathUnavailableReason =
            'VideoEncoder.isConfigSupported reported codec "vp8" as unsupported';
        return null;
      }

      final muxer = WebmMuxer(width: _width, height: _height, codecId: 'V_VP8');

      final encoder = web.VideoEncoder(
        web.VideoEncoderInit(
          output: ((web.EncodedVideoChunk chunk) {
            final bytes = Uint8List(chunk.byteLength);
            chunk.copyTo(bytes.toJS);
            muxer.addFrame(
              bytes: bytes,
              timestampMs: (chunk.timestamp / 1000).round(),
              isKeyFrame: chunk.type == 'key',
            );
          }).toJS,
          error: ((JSAny error) {
            debugPrint('VideoEncoder error: $error');
          }).toJS,
        ),
      );
      encoder.configure(config);
      return (encoder: encoder, muxer: muxer);
    } catch (e, st) {
      _fastPathUnavailableReason = e.toString();
      debugPrint('Fast export path unavailable: $e\n$st');
      return null;
    }
  }

  Future<web.Blob> _runFastExport(
    web.VideoEncoder encoder,
    WebmMuxer muxer,
  ) async {
    final totalFrames = _totalFrames;
    for (var frame = 0; frame < totalFrames; frame++) {
      final targetTime =
          Duration(microseconds: (frame * 1000000 / _fps).round());
      _drawFrameToCanvas(targetTime);

      final videoFrame = web.VideoFrame(
        _canvas,
        web.VideoFrameInit(timestamp: targetTime.inMicroseconds),
      );
      final isKey = frame % _keyFrameIntervalFrames == 0;
      encoder.encode(videoFrame, web.VideoEncoderEncodeOptions(keyFrame: isKey));
      videoFrame.close();

      while (encoder.encodeQueueSize > 8) {
        await Future<void>.delayed(const Duration(milliseconds: 4));
      }

      if (!mounted) break;
      _reportProgress(frame + 1, totalFrames);
    }

    await encoder.flush().toDart;
    encoder.close();

    if (mounted) setState(() => _status = 'Finalizing…');
    final bytes = muxer.finish();
    return web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: 'video/webm'),
    );
  }

  // --- Fallback path: MediaRecorder, real-time capture ---

  String _pickMimeType() {
    const candidates = [
      'video/webm;codecs=vp9',
      'video/webm;codecs=vp8',
      'video/webm',
    ];
    for (final candidate in candidates) {
      if (web.MediaRecorder.isTypeSupported(candidate)) return candidate;
    }
    return 'video/webm';
  }

  Future<web.Blob> _runRealtimeExport() async {
    final stream = _canvas.captureStream(_fps);
    final dataAvailable = Completer<web.Blob>();
    _recorder = web.MediaRecorder(
      stream,
      web.MediaRecorderOptions(mimeType: _pickMimeType()),
    );
    _recorder.ondataavailable = ((web.Event event) {
      final blobEvent = event as web.BlobEvent;
      if (!dataAvailable.isCompleted) {
        dataAvailable.complete(blobEvent.data);
      }
    }).toJS;
    _recorder.start();

    final totalFrames = _totalFrames;
    final stopwatch = Stopwatch()..start();

    for (var frame = 0; frame < totalFrames; frame++) {
      final targetTime =
          Duration(microseconds: (frame * 1000000 / _fps).round());
      final waitFor = targetTime - stopwatch.elapsed;
      if (waitFor > Duration.zero) {
        await Future<void>.delayed(waitFor);
      }
      _drawFrameToCanvas(targetTime);
      if (!mounted) break;
      _reportProgress(frame + 1, totalFrames);
    }

    if (mounted) setState(() => _status = 'Finalizing…');
    _recorder.stop();
    return dataAvailable.future;
  }

  // --- Shared progress reporting ---

  int _lastReportedPercent = -1;

  /// Only calls [setState] when the displayed percentage actually changes,
  /// instead of on every single frame — at 24fps a multi-minute export is
  /// thousands of unnecessary widget rebuilds competing with the encoder
  /// for the same JS thread.
  void _reportProgress(int framesDone, int totalFrames) {
    final percent = (framesDone * 100 / totalFrames).floor();
    if (percent == _lastReportedPercent) return;
    _lastReportedPercent = percent;
    setState(() {
      _progress = framesDone / totalFrames;
      _status = 'Rendering… $percent%';
    });
  }

  // --- Shared frame drawing / download ---

  late final _renderer = CanvasTabRenderer(
    ctx: _ctx,
    width: _width,
    height: _height,
    pixelsPerSecond: _pixelsPerSecond,
    stringSpacing: 44,
    topPadding: 40,
    leftPadding: _leftPadding,
    bpm: widget.bpm,
    totalDuration: widget.totalDuration,
    backgroundColor: widget.backgroundColor,
    measuresPerWindow: widget.measuresPerWindow,
    beatsPerMeasure: widget.beatsPerMeasure,
    highlightBeats: widget.highlightBeats,
    showPlayhead: widget.showPlayhead,
  );

  /// Draws straight onto the native `<canvas>` via [CanvasTabRenderer] — no
  /// Flutter widget tree, no GPU readback. `VideoFrame` reads the canvas
  /// directly afterward, so this is synchronous and cheap.
  void _drawFrameToCanvas(Duration time) {
    _renderer.drawFrame(widget.notes, time);
  }

  void _downloadBlob(web.Blob blob) {
    final url = web.URL.createObjectURL(blob);
    final anchor = web.document.createElement('a') as web.HTMLAnchorElement
      ..href = url
      ..download = 'bass_tab_export.webm';
    web.document.body?.appendChild(anchor);
    anchor.click();
    anchor.remove();
    web.URL.revokeObjectURL(url);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Exporting chroma-key video'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              Text(
                'Export failed: $_error',
                style: const TextStyle(color: Colors.redAccent),
              )
            else ...[
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 8),
              Text(_status),
              if (_usingFastPath == false) ...[
                const SizedBox(height: 8),
                Text(
                  'Fast export (WebCodecs) isn\'t available in this browser — '
                  'falling back to real-time recording. Keep this tab open '
                  'and in the foreground until it finishes.'
                  '${_fastPathUnavailableReason != null ? '\nReason: $_fastPathUnavailableReason' : ''}',
                  style: const TextStyle(color: Colors.amber, fontSize: 12),
                ),
              ],
            ],
          ],
        ),
        actions: [
          if (_error != null)
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
        ],
      ),
    );
  }
}
