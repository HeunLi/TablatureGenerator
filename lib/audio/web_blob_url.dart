import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Creates a browser object URL for the given bytes so it can be handed to
/// an `<audio>`-backed player (e.g. just_audio's web implementation) without
/// ever touching disk.
String createBlobUrl(Uint8List bytes, String mimeType) {
  final blobParts = [bytes.toJS].toJS;
  final blob = web.Blob(blobParts, web.BlobPropertyBag(type: mimeType));
  return web.URL.createObjectURL(blob);
}

void revokeBlobUrl(String url) {
  web.URL.revokeObjectURL(url);
}
