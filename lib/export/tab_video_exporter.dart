import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:web/web.dart' as web;

import '../models/tab_note.dart';
import 'scrolling_tab_painter.dart';

/// Renders the tab to a chroma-key (solid background) WebM video, timed to
/// match [totalDuration], and triggers a browser download.
///
/// Real transparency isn't achievable via MediaRecorder in browsers, so we
/// render on a solid, distinct green background instead — the resulting
/// clip drops into any video editor and gets keyed out like a green screen.
class TabVideoExporter {
  static Future<void> exportChromaKey(
    BuildContext context, {
    required List<TabNote> notes,
    required double bpm,
    required Duration totalDuration,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ExportDialog(
        notes: notes,
        bpm: bpm,
        totalDuration: totalDuration,
      ),
    );
  }
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({
    required this.notes,
    required this.bpm,
    required this.totalDuration,
  });

  final List<TabNote> notes;
  final double bpm;
  final Duration totalDuration;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  static const _fps = 24;
  static const _width = 960;
  static const _height = 220;
  static const _playheadX = 160.0;
  static const _pixelsPerSecond = 140.0;
  static const _chromaGreen = Color(0xFF00B140);

  final _boundaryKey = GlobalKey();
  final _currentTime = ValueNotifier<Duration>(Duration.zero);

  double _progress = 0;
  String _status = 'Preparing…';
  String? _error;

  late web.CanvasRenderingContext2D _ctx;
  late web.MediaRecorder _recorder;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _currentTime.dispose();
    super.dispose();
  }

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

  Future<void> _run() async {
    try {
      final canvas =
          web.document.createElement('canvas') as web.HTMLCanvasElement;
      canvas.width = _width;
      canvas.height = _height;
      _ctx = canvas.getContext('2d')! as web.CanvasRenderingContext2D;
      final stream = canvas.captureStream(_fps);

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

      final totalFrames = (widget.totalDuration.inMilliseconds * _fps / 1000)
          .ceil()
          .clamp(1, 1 << 30);
      final stopwatch = Stopwatch()..start();

      for (var frame = 0; frame < totalFrames; frame++) {
        final targetTime =
            Duration(microseconds: (frame * 1000000 / _fps).round());
        final waitFor = targetTime - stopwatch.elapsed;
        if (waitFor > Duration.zero) {
          await Future<void>.delayed(waitFor);
        }
        _currentTime.value = targetTime;
        await WidgetsBinding.instance.endOfFrame;
        await _captureFrame();
        if (!mounted) return;
        setState(() {
          _progress = (frame + 1) / totalFrames;
          _status = 'Rendering… ${(_progress * 100).toStringAsFixed(0)}%';
        });
      }

      if (mounted) setState(() => _status = 'Finalizing…');
      _recorder.stop();
      final blob = await dataAvailable.future;
      _downloadBlob(blob);

      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _captureFrame() async {
    final boundary =
        _boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final byteData =
        await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    image.dispose();
    if (byteData == null) return;
    final clamped = Uint8ClampedList.view(byteData.buffer);
    final imageData = web.ImageData(clamped.toJS, _width, _height.toJS);
    _ctx.putImageData(imageData, 0, 0);
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
              RepaintBoundary(
                key: _boundaryKey,
                child: SizedBox(
                  width: _width.toDouble(),
                  height: _height.toDouble(),
                  child: ValueListenableBuilder<Duration>(
                    valueListenable: _currentTime,
                    builder: (context, time, _) => CustomPaint(
                      painter: ScrollingTabPainter(
                        notes: widget.notes,
                        currentTime: time,
                        pixelsPerSecond: _pixelsPerSecond,
                        stringSpacing: 44,
                        topPadding: 40,
                        playheadX: _playheadX,
                        backgroundColor: _chromaGreen,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 8),
              Text(_status),
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
