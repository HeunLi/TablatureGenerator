import 'dart:typed_data';

class _MuxedFrame {
  _MuxedFrame({required this.bytes, required this.timestampMs, required this.isKeyFrame});
  final Uint8List bytes;
  final int timestampMs;
  final bool isKeyFrame;
}

/// A minimal single-video-track WebM (Matroska subset) muxer.
///
/// Buffers every encoded frame in memory and writes the whole file in
/// [finish] — fine for the short practice clips this app exports, not
/// meant for hours of footage. Only handles the small slice of the spec
/// needed for one VP8/VP9 track: EBML header, Segment > Info/Tracks, and
/// Clusters of SimpleBlocks split at each keyframe.
class WebmMuxer {
  WebmMuxer({
    required this.width,
    required this.height,
    required this.codecId,
    this.keyFrameIntervalMs = 4000,
  });

  final int width;
  final int height;
  final String codecId; // e.g. 'V_VP8' or 'V_VP9'
  final int keyFrameIntervalMs;

  final List<_MuxedFrame> _frames = [];

  void addFrame({
    required Uint8List bytes,
    required int timestampMs,
    required bool isKeyFrame,
  }) {
    _frames.add(_MuxedFrame(
      bytes: bytes,
      timestampMs: timestampMs,
      isKeyFrame: isKeyFrame,
    ));
  }

  Uint8List finish() {
    final out = BytesBuilder();
    out.add(_ebmlHeader());
    final segmentPayload = BytesBuilder();
    segmentPayload.add(_info());
    segmentPayload.add(_tracks());
    segmentPayload.add(_clusters());
    out.add(_element(_idSegment, segmentPayload.toBytes()));
    return out.toBytes();
  }

  // --- Top-level structure builders ---

  Uint8List _ebmlHeader() {
    final payload = BytesBuilder();
    payload.add(_element(_idEbmlVersion, _uint(1)));
    payload.add(_element(_idEbmlReadVersion, _uint(1)));
    payload.add(_element(_idEbmlMaxIdLength, _uint(4)));
    payload.add(_element(_idEbmlMaxSizeLength, _uint(8)));
    payload.add(_element(_idDocType, _ascii('webm')));
    payload.add(_element(_idDocTypeVersion, _uint(2)));
    payload.add(_element(_idDocTypeReadVersion, _uint(2)));
    return _element(_idEbml, payload.toBytes());
  }

  Uint8List _info() {
    final totalDurationMs =
        _frames.isEmpty ? 0 : _frames.last.timestampMs + 1;
    final payload = BytesBuilder();
    // 1,000,000 ns per tick == 1ms per tick, so Duration below is in ms.
    payload.add(_element(_idTimecodeScale, _uint(1000000)));
    payload.add(_element(_idDuration, _float64(totalDurationMs.toDouble())));
    payload.add(_element(_idMuxingApp, _ascii('BassTabStudio')));
    payload.add(_element(_idWritingApp, _ascii('BassTabStudio')));
    return _element(_idInfo, payload.toBytes());
  }

  Uint8List _tracks() {
    final video = BytesBuilder();
    video.add(_element(_idPixelWidth, _uint(width)));
    video.add(_element(_idPixelHeight, _uint(height)));

    final trackEntry = BytesBuilder();
    trackEntry.add(_element(_idTrackNumber, _uint(1)));
    trackEntry.add(_element(_idTrackUid, _uint(1)));
    trackEntry.add(_element(_idTrackType, _uint(1))); // 1 == video
    trackEntry.add(_element(_idCodecId, _ascii(codecId)));
    trackEntry.add(_element(_idVideo, video.toBytes()));

    return _element(_idTracks, _element(_idTrackEntry, trackEntry.toBytes()));
  }

  Uint8List _clusters() {
    final out = BytesBuilder();
    var i = 0;
    while (i < _frames.length) {
      final clusterStart = _frames[i].timestampMs;
      final clusterFrames = <_MuxedFrame>[_frames[i]];
      i++;
      while (i < _frames.length &&
          !_frames[i].isKeyFrame &&
          (_frames[i].timestampMs - clusterStart) < 30000) {
        clusterFrames.add(_frames[i]);
        i++;
      }

      final payload = BytesBuilder();
      payload.add(_element(_idTimecode, _uint(clusterStart)));
      for (final frame in clusterFrames) {
        payload.add(_simpleBlock(frame, clusterStart));
      }
      out.add(_element(_idCluster, payload.toBytes()));
    }
    return out.toBytes();
  }

  Uint8List _simpleBlock(_MuxedFrame frame, int clusterStartMs) {
    final relative = frame.timestampMs - clusterStartMs;
    final payload = BytesBuilder();
    payload.add(_vint(1)); // track number 1
    final timecodeBytes = ByteData(2)..setInt16(0, relative, Endian.big);
    payload.add(timecodeBytes.buffer.asUint8List());
    payload.add([frame.isKeyFrame ? 0x80 : 0x00]);
    payload.add(frame.bytes);
    return _element(_idSimpleBlock, payload.toBytes());
  }

  // --- EBML element IDs (Matroska/WebM spec) ---

  static const _idEbml = [0x1A, 0x45, 0xDF, 0xA3];
  static const _idEbmlVersion = [0x42, 0x86];
  static const _idEbmlReadVersion = [0x42, 0xF7];
  static const _idEbmlMaxIdLength = [0x42, 0xF2];
  static const _idEbmlMaxSizeLength = [0x42, 0xF3];
  static const _idDocType = [0x42, 0x82];
  static const _idDocTypeVersion = [0x42, 0x87];
  static const _idDocTypeReadVersion = [0x42, 0x85];

  static const _idSegment = [0x18, 0x53, 0x80, 0x67];
  static const _idInfo = [0x15, 0x49, 0xA9, 0x66];
  static const _idTimecodeScale = [0x2A, 0xD7, 0xB1];
  static const _idDuration = [0x44, 0x89];
  static const _idMuxingApp = [0x4D, 0x80];
  static const _idWritingApp = [0x57, 0x41];

  static const _idTracks = [0x16, 0x54, 0xAE, 0x6B];
  static const _idTrackEntry = [0xAE];
  static const _idTrackNumber = [0xD7];
  static const _idTrackUid = [0x73, 0xC5];
  static const _idTrackType = [0x83];
  static const _idCodecId = [0x86];
  static const _idVideo = [0xE0];
  static const _idPixelWidth = [0xB0];
  static const _idPixelHeight = [0xBA];

  static const _idCluster = [0x1F, 0x43, 0xB6, 0x75];
  static const _idTimecode = [0xE7];
  static const _idSimpleBlock = [0xA3];

  // --- EBML primitives ---

  static Uint8List _element(List<int> id, Uint8List payload) {
    final out = BytesBuilder();
    out.add(id);
    out.add(_vint(payload.length));
    out.add(payload);
    return out.toBytes();
  }

  static Uint8List _vint(int value) {
    var length = 1;
    while (value >= (1 << (7 * length))) {
      length++;
    }
    final bytes = Uint8List(length);
    var v = value;
    for (var i = length - 1; i >= 0; i--) {
      bytes[i] = v & 0xFF;
      v >>= 8;
    }
    bytes[0] |= 1 << (8 - length);
    return bytes;
  }

  static Uint8List _uint(int value) {
    if (value == 0) return Uint8List.fromList([0]);
    final bytes = <int>[];
    var v = value;
    while (v > 0) {
      bytes.insert(0, v & 0xFF);
      v >>= 8;
    }
    return Uint8List.fromList(bytes);
  }

  static Uint8List _float64(double value) {
    final data = ByteData(8)..setFloat64(0, value, Endian.big);
    return data.buffer.asUint8List();
  }

  static Uint8List _ascii(String value) => Uint8List.fromList(value.codeUnits);
}
