import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

import 'web_blob_url.dart';

const _mimeTypesByExtension = {
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'ogg': 'audio/ogg',
  'flac': 'audio/flac',
};

String mimeTypeForExtension(String? extension) =>
    _mimeTypesByExtension[extension?.toLowerCase()] ?? 'audio/mpeg';

/// Thin wrapper around [AudioPlayer] that loads audio from in-memory bytes
/// (as picked from a browser file input) via an object URL, and exposes the
/// streams the editor needs to drive its playhead.
class AudioController {
  AudioController() : player = AudioPlayer();

  final AudioPlayer player;
  String? _currentBlobUrl;

  Stream<Duration> get positionStream => player.positionStream;
  Stream<Duration?> get durationStream => player.durationStream;
  Stream<PlayerState> get playerStateStream => player.playerStateStream;
  Duration? get duration => player.duration;
  bool get isPlaying => player.playing;

  Future<void> loadFromBytes(Uint8List bytes, String fileExtension) async {
    final mimeType = mimeTypeForExtension(fileExtension);
    final url = createBlobUrl(bytes, mimeType);
    final previousUrl = _currentBlobUrl;
    _currentBlobUrl = url;
    await player.setUrl(url);
    if (previousUrl != null) {
      revokeBlobUrl(previousUrl);
    }
  }

  Future<void> play() => player.play();
  Future<void> pause() => player.pause();
  Future<void> seek(Duration position) => player.seek(position);

  Future<void> dispose() async {
    await player.dispose();
    if (_currentBlobUrl != null) {
      revokeBlobUrl(_currentBlobUrl!);
    }
  }
}
