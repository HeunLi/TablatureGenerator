import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../audio/waveform_extractor.dart';
import 'tab_timeline_layout.dart';

/// Rasterizes the waveform preview strip into fixed-width, cached
/// [ui.Image] tiles that the timeline then blits with `drawImageRect`.
///
/// **Why images and not a cached `ui.Picture`.** An earlier version of this
/// cached the waveform's draw commands in a `ui.Picture` and replayed it
/// with `canvas.drawPicture` (see Decisions, "Waveform preview"). That
/// removes the cost of *recording* the commands each frame — the Dart-side
/// bucket lookups and `Path` building — but `drawPicture` inlines the
/// recorded commands into the enclosing display list, so the **raster**
/// thread still re-tessellates and re-fills the entire waveform on every
/// frame that touches this layer. With one vertical bar per screen pixel
/// across a multi-thousand-pixel buffered window, that rasterization was
/// the remaining per-frame cost, and it is why scrolling stayed janky even
/// with the picture cache in place. A `ui.Image` is different in kind: once
/// rasterized, drawing it is a single textured quad, so per-frame cost
/// stops scaling with waveform complexity entirely.
///
/// **Why tiles and not one image.** Tiles are keyed on absolute content-x,
/// so scrolling reuses every tile that was already on screen and only pays
/// for the sliver of newly-exposed timeline — as opposed to a single
/// window-sized image keyed on the scroll position, which every scroll
/// event would invalidate wholesale. That was the other half of the old
/// jank: the cache key included the scroll window, so scrolling
/// systematically threw away the very thing the cache existed to preserve.
///
/// The cache is bounded ([maxTiles]) and evicts least-recently-drawn tiles,
/// so a long track can't accumulate GPU memory as the user scrolls through
/// it.
class WaveformTileCache {
  WaveformTileCache({this.maxTiles = 24});

  /// Upper bound on live tiles. A 1440px-wide viewport needs ~4 on screen;
  /// this leaves generous room for the scroll-back direction while capping
  /// memory at a few MB.
  final int maxTiles;

  /// Logical width of one tile. Small enough that a scroll only ever
  /// rasterizes a little ahead of the viewport, large enough that a screen
  /// is a handful of draw calls rather than dozens.
  static const int _tileWidthPx = 512;
  static const double _tileWidth = 512;

  /// Extra content rendered beyond each side of a tile. Bilinear sampling
  /// at a tile's edge would otherwise have no neighbouring texels to blend
  /// with (the sampler clamps to the edge instead), leaving a faint seam
  /// every [_tileWidth] pixels. Rendering a couple of pixels of overlap and
  /// then sampling only the tile's interior gives the sampler real
  /// neighbours to work with.
  static const int _bleedPx = 2;
  static const double _bleed = 2;

  /// One envelope sample per logical pixel across the tile *and* its bleed,
  /// plus a closing sample — the polygon's vertex count, fixed so the
  /// scratch buffer can be allocated once.
  static const int _sampleCount = _tileWidthPx + 2 * _bleedPx + 1;

  /// Tiles cap out at 2x. Beyond that the extra resolution is invisible on
  /// an amplitude envelope but the memory and fill cost are real — which
  /// matters most on exactly the high-DPI phones that can least afford it.
  static const _maxRenderScale = 2.0;

  /// Silence still draws a hairline rather than nothing, so the strip reads
  /// as one continuous waveform instead of breaking apart over quiet
  /// passages.
  static const _minHalfHeight = 0.5;

  // Insertion-ordered (Dart's default `Map` is a `LinkedHashMap`), which is
  // what makes `keys.first` the least-recently-drawn tile: `_tileAt` deletes
  // and re-inserts on every hit, moving that tile to the back.
  final _tiles = <int, ui.Image>{};

  final Float32List _halfHeights = Float32List(_sampleCount);

  /// Latches once if snapshotting a tile ever fails, so the fallback path
  /// in [paint] doesn't re-attempt (and re-throw) on every tile of every
  /// frame. `Picture.toImageSync` is supported by both web renderers
  /// Flutter ships, but a renderer that can't snapshot should degrade to a
  /// slower waveform, not to no waveform.
  bool _tilesUnavailable = false;

  WaveformData? _waveform;
  double _pixelsPerSecond = 0;
  double _leftPadding = 0;
  double _renderScale = 0;
  int _color = 0;

  /// Draws the waveform strip covering content-x `[fromX, toX]` onto
  /// [canvas], which is expected to already be in **content coordinates**
  /// (i.e. the caller has applied the scroll translation).
  ///
  /// Any change to the inputs the tiles were rasterized against — zoom,
  /// gutter, colour, device pixel ratio, or the waveform itself — drops the
  /// whole cache, since every tile is stale in exactly the same way.
  void paint(
    Canvas canvas, {
    required WaveformData waveform,
    required TabTimelineLayout layout,
    required double devicePixelRatio,
    required Color color,
    required double fromX,
    required double toX,
  }) {
    if (waveform.isEmpty) return;

    final renderScale = devicePixelRatio.clamp(1.0, _maxRenderScale);
    final colorValue = color.toARGB32();
    if (!identical(_waveform, waveform) ||
        _pixelsPerSecond != layout.pixelsPerSecond ||
        _leftPadding != layout.leftPadding ||
        _renderScale != renderScale ||
        _color != colorValue) {
      clear();
      _waveform = waveform;
      _pixelsPerSecond = layout.pixelsPerSecond;
      _leftPadding = layout.leftPadding;
      _renderScale = renderScale;
      _color = colorValue;
    }

    // Nothing exists left of the gutter or past the end of the audio, so
    // don't rasterize tiles for either.
    final audioStartX = layout.leftPadding;
    final audioEndX =
        layout.leftPadding + waveform.durationSeconds * layout.pixelsPerSecond;
    final firstTile = ((fromX > audioStartX ? fromX : audioStartX) / _tileWidth)
        .floor();
    final lastTile = ((toX < audioEndX ? toX : audioEndX) / _tileWidth).floor();
    if (lastTile < firstTile) return;

    final source = Rect.fromLTWH(
      _bleed * _renderScale,
      0,
      _tileWidth * _renderScale,
      TabTimelineLayout.waveformHeight * _renderScale,
    );
    final paint = Paint()
      ..filterQuality = FilterQuality.low
      ..isAntiAlias = false;

    for (var index = firstTile; index <= lastTile; index++) {
      final destination = Rect.fromLTWH(
        index * _tileWidth,
        layout.waveformTop,
        _tileWidth,
        TabTimelineLayout.waveformHeight,
      );
      final image = _tilesUnavailable ? null : _tileAt(index);
      if (image == null) {
        // Draw the same envelope straight onto the target canvas instead.
        // Costs what the pre-tiling version cost (rebuilt every frame), but
        // the strip still renders correctly rather than vanishing on a
        // browser where snapshotting isn't available. The clip keeps each
        // span to its own tile so the overlapping bleed regions of adjacent
        // spans can't double-fill and band the strip.
        canvas
          ..save()
          ..clipRect(destination)
          ..translate(0, layout.waveformTop);
        _paintEnvelope(canvas, waveform, index * _tileWidth - _bleed);
        canvas.restore();
        continue;
      }
      canvas.drawImageRect(image, source, destination, paint);
    }
  }

  ui.Image? _tileAt(int index) {
    final cached = _tiles.remove(index);
    if (cached != null) {
      _tiles[index] = cached; // Re-inserted at the back: most recently used.
      return cached;
    }
    final image = _render(index);
    if (image == null) return null;
    while (_tiles.length >= maxTiles) {
      _tiles.remove(_tiles.keys.first)?.dispose();
    }
    _tiles[index] = image;
    return image;
  }

  ui.Image? _render(int index) {
    final waveform = _waveform;
    if (waveform == null || waveform.isEmpty) return null;

    const logicalWidth = _tileWidth + 2 * _bleed;
    const logicalHeight = TabTimelineLayout.waveformHeight;
    final pixelWidth = (logicalWidth * _renderScale).round();
    final pixelHeight = (logicalHeight * _renderScale).round();
    if (pixelWidth <= 0 || pixelHeight <= 0) return null;

    final originX = index * _tileWidth - _bleed;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..scale(_renderScale)
      ..translate(-originX, 0);
    _paintEnvelope(canvas, waveform, originX);

    final picture = recorder.endRecording();
    try {
      // `toImageSync` hands back an image the raster thread fills in on
      // first use — no GPU readback and no round-trip through a Future, so
      // this is safe to call from inside a paint pass.
      return picture.toImageSync(pixelWidth, pixelHeight);
    } catch (error) {
      debugPrint('Waveform tile rasterization unavailable: $error');
      _tilesUnavailable = true;
      return null;
    } finally {
      picture.dispose();
    }
  }

  /// Draws the strip as **one filled polygon** — top envelope left to
  /// right, then the mirrored bottom envelope back again — rather than one
  /// stroked vertical bar per pixel. Same silhouette, but a single convexity
  /// pass over ~1000 vertices instead of stroking ~500 disjoint segments,
  /// which is what a stroked path costs the rasterizer. It also reads as a
  /// continuous waveform rather than a picket fence, matching how every DAW
  /// draws one.
  void _paintEnvelope(Canvas canvas, WaveformData waveform, double originX) {
    const height = TabTimelineLayout.waveformHeight;
    const midY = height / 2;
    const maxHalf = height / 2;
    final secondsPerPixel = 1 / _pixelsPerSecond;
    final durationSeconds = waveform.durationSeconds;

    for (var i = 0; i < _sampleCount; i++) {
      final seconds = (originX + i - _leftPadding) / _pixelsPerSecond;
      if (seconds < 0 || seconds > durationSeconds) {
        _halfHeights[i] = 0;
        continue;
      }
      var half =
          waveform.peakBetween(seconds, seconds + secondsPerPixel) * maxHalf;
      if (half > maxHalf) half = maxHalf;
      if (half < _minHalfHeight) half = _minHalfHeight;
      _halfHeights[i] = half;
    }

    final path = Path()..moveTo(originX, midY - _halfHeights[0]);
    for (var i = 1; i < _sampleCount; i++) {
      path.lineTo(originX + i, midY - _halfHeights[i]);
    }
    for (var i = _sampleCount - 1; i >= 0; i--) {
      path.lineTo(originX + i, midY + _halfHeights[i]);
    }
    path.close();

    canvas.drawPath(path, Paint()..color = Color(_color));
  }

  void clear() {
    for (final image in _tiles.values) {
      image.dispose();
    }
    _tiles.clear();
  }

  void dispose() {
    clear();
    _waveform = null;
  }
}
