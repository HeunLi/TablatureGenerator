import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../audio/waveform_extractor.dart';
import '../models/tab_note.dart';
import '../models/tempo_map.dart';
import 'tab_timeline_layout.dart';
import 'tab_timeline_painter.dart';
import 'waveform_tile_cache.dart';

/// A pan recognizer that only enters the gesture arena when the drag starts
/// somewhere it cares about. Without this, a plain `onPan*` handler on the
/// timeline claims every drag (including ones meant to scroll the
/// horizontally-scrolling timeline), starving the ancestor
/// `SingleChildScrollView`'s drag recognizer and making the timeline
/// unscrollable. Rejecting the pointer outright (instead of accepting then
/// losing) lets the scroll view's recognizer win those drags instead.
///
/// The two subclasses exist only so the timeline can register both in one
/// gesture map, which is keyed by recognizer type.
abstract class _ZonedPanGestureRecognizer extends PanGestureRecognizer {
  _ZonedPanGestureRecognizer({required this.accepts});

  final bool Function(Offset localPosition) accepts;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (!accepts(event.localPosition)) return;
    super.addAllowedPointer(event);
  }
}

/// Claims drags that start on a note (moving it).
class _NoteDragGestureRecognizer extends _ZonedPanGestureRecognizer {
  _NoteDragGestureRecognizer({required super.accepts});
}

/// Claims drags that start inside the waveform strip (setting the A/B loop).
class _LoopDragGestureRecognizer extends _ZonedPanGestureRecognizer {
  _LoopDragGestureRecognizer({required super.accepts});
}

/// The scrollable tab timeline: two painted layers plus a transparent
/// scroll/gesture surface stacked on top of them.
///
/// **The layout is the optimization.** The obvious structure — put one
/// `CustomPaint` as wide as the whole track inside the scroll view — is
/// what this replaces, and it had two costs that no amount of caching
/// inside the painter could remove:
///
/// 1. A child of a scroll view is repainted at its new offset on *every*
///    scrolled pixel, and the painted surface was as wide as the track
///    (minutes x zoom = easily tens of thousands of pixels), so both the
///    display list and the rasterized area scaled with track length rather
///    than with what's actually visible.
/// 2. Wrapping that in a `RepaintBoundary` to make scrolling a pure layer
///    translation isn't an option either — the cached layer would be a
///    track-sized texture, which is far past what's sane to hold in memory
///    and only gets worse as the track or the zoom grows.
///
/// So the painting is inverted instead: both layers are exactly
/// viewport-sized and translate their *contents* by the scroll offset,
/// while the scroll view keeps a transparent, track-width child purely to
/// own the scroll extent, the scrollbar, and hit testing. Rasterized area
/// is then constant — a 30-second sketch and a 10-minute track cost the
/// same per frame.
///
/// Scrolling and playhead ticks drive the layers through `Listenable`s
/// wired into `CustomPainter.repaint`, so neither one rebuilds any widget;
/// they mark one layer for repaint and nothing else.
class TabTimelineView extends StatefulWidget {
  const TabTimelineView({
    super.key,
    required this.controller,
    required this.layout,
    required this.notes,
    required this.selection,
    required this.playhead,
    required this.waveform,
    required this.loopRegion,
    required this.tempo,
    required this.subdivisionsPerBeat,
    required this.highlightBeats,
    required this.totalSeconds,
    required this.audioLoaded,
    required this.hitTestNote,
    required this.onTapUp,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
    required this.onLoopChanged,
    required this.onLoopCommitted,
    required this.onZoomGesture,
  });

  final ScrollController controller;
  final TabTimelineLayout layout;

  /// Live editing state, delivered as listenables rather than plain values
  /// so a note drag repaints only the note layer instead of rebuilding
  /// `StudioScreen` (and re-blurring its glass panels) on every
  /// pointer-move frame.
  final ValueListenable<List<TabNote>> notes;
  final ValueListenable<Set<int>> selection;
  final ValueListenable<Duration> playhead;
  final ValueListenable<WaveformData?> waveform;
  final ValueListenable<(double, double)?> loopRegion;

  final TempoMap tempo;
  final int subdivisionsPerBeat;
  final int highlightBeats;
  final double totalSeconds;
  final bool audioLoaded;

  final bool Function(Offset localPosition) hitTestNote;
  final GestureTapUpCallback onTapUp;
  final GestureDragStartCallback onPanStart;
  final GestureDragUpdateCallback onPanUpdate;
  final GestureDragEndCallback onPanEnd;

  /// Called continuously while dragging out a loop region on the waveform.
  final void Function(Duration start, Duration end) onLoopChanged;

  /// Called when that drag finishes, so a stray click-sized region can be
  /// discarded rather than becoming a zero-length loop.
  final VoidCallback onLoopCommitted;

  /// Ctrl/Cmd + wheel. [delta] is the raw wheel delta (positive = zoom out)
  /// and [viewportX] is where the cursor sits, so zoom can stay anchored
  /// under the pointer instead of jumping.
  final void Function(double delta, double viewportX) onZoomGesture;

  @override
  State<TabTimelineView> createState() => _TabTimelineViewState();
}

class _TabTimelineViewState extends State<TabTimelineView> {
  // Driven straight from the scroll controller with no `setState`: the
  // painters listen to it, so a scroll is a repaint of two layers and
  // nothing more. (The previous version called `setState` from its scroll
  // listener, rebuilding the timeline subtree mid-fling.)
  final _scrollOffset = ValueNotifier<double>(0);

  // The highlight block only advances once per beat block — seconds apart,
  // not once per frame — so the backdrop layer subscribes to this rather
  // than to the playhead itself and stays out of the per-frame path.
  final _highlightBounds = ValueNotifier<(double, double)>((0, 0));

  // Owned here, not by the painters: a fresh painter is constructed on
  // every rebuild, so caches living on one wouldn't survive a single frame.
  final _waveformTiles = WaveformTileCache();
  final _textCache = TimelineTextCache();

  /// Where a loop drag began, so dragging leftwards produces the same
  /// region as dragging rightwards.
  Duration? _loopAnchor;

  /// Latest pointer position over the timeline, kept so a wheel event —
  /// which is resolved a step later through the pointer-signal resolver —
  /// still knows where the cursor was for anchored zooming.
  Offset _pointerPosition = Offset.zero;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleScroll);
    widget.playhead.addListener(_handlePlayhead);
    _handlePlayhead();
  }

  @override
  void didUpdateWidget(TabTimelineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleScroll);
      widget.controller.addListener(_handleScroll);
      _handleScroll();
    }
    if (oldWidget.playhead != widget.playhead) {
      oldWidget.playhead.removeListener(_handlePlayhead);
      widget.playhead.addListener(_handlePlayhead);
    }
    // Tempo and block width both move where block boundaries fall, so the
    // currently-lit block has to be recomputed even though the playhead
    // itself hasn't moved.
    if (oldWidget.tempo != widget.tempo ||
        oldWidget.highlightBeats != widget.highlightBeats) {
      _handlePlayhead();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleScroll);
    widget.playhead.removeListener(_handlePlayhead);
    _scrollOffset.dispose();
    _highlightBounds.dispose();
    _waveformTiles.dispose();
    _textCache.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!widget.controller.hasClients) return;
    _scrollOffset.value = widget.controller.position.pixels;
  }

  void _handlePlayhead() {
    // ValueNotifier already suppresses no-op assignments, and records
    // compare structurally — so this only actually notifies at a block
    // boundary, which is the whole point of routing it through here.
    _highlightBounds.value = widget.tempo.beatBlockBounds(
      widget.playhead.value,
      widget.highlightBeats,
    );
  }

  // --- Loop region drag (waveform strip) ---

  void _handleLoopStart(DragStartDetails details) {
    final anchor = widget.layout.timeForX(details.localPosition.dx);
    _loopAnchor = anchor;
    widget.onLoopChanged(anchor, anchor);
  }

  void _handleLoopUpdate(DragUpdateDetails details) {
    final anchor = _loopAnchor;
    if (anchor == null) return;
    final current = widget.layout.timeForX(details.localPosition.dx);
    widget.onLoopChanged(
      current < anchor ? current : anchor,
      current < anchor ? anchor : current,
    );
  }

  void _handleLoopEnd(DragEndDetails details) {
    _loopAnchor = null;
    widget.onLoopCommitted();
  }

  // --- Wheel ---

  /// Flutter's `Scrollable` only maps mouse-wheel *vertical* motion
  /// (`scrollDelta.dy`) onto a scroll axis when that axis is vertical — our
  /// timeline scrolls horizontally, so the default wheel handling ignores
  /// `dy` entirely and the wheel does nothing. This routes vertical wheel
  /// deltas onto the horizontal scroll controller ourselves. Horizontal
  /// wheel/trackpad deltas (`dx`) are left alone; the built-in handling
  /// already applies those to the horizontal axis correctly.
  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && event.scrollDelta.dy != 0) {
      _pointerPosition = event.localPosition;
      GestureBinding.instance.pointerSignalResolver
          .register(event, _handleWheelScroll);
    }
  }

  void _handleWheelScroll(PointerSignalEvent event) {
    final delta = (event as PointerScrollEvent).scrollDelta.dy;
    // Ctrl/Cmd + wheel is the near-universal zoom gesture in editors, and
    // it's the only way to zoom without taking a hand off the pointer.
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed || keyboard.isMetaPressed) {
      widget.onZoomGesture(delta, _pointerPosition.dx);
      return;
    }
    if (!widget.controller.hasClients) return;
    final position = widget.controller.position;
    final target = (position.pixels + delta)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    widget.controller.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    return Listener(
      onPointerSignal: _handlePointerSignal,
      child: Stack(
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                // Complex and mostly static: exactly the profile the raster
                // cache exists for, so during playback (when only the
                // foreground layer moves) this layer's rasterization is
                // reused frame after frame instead of being redone.
                isComplex: true,
                willChange: false,
                painter: TabTimelineBackdropPainter(
                  scrollOffset: _scrollOffset,
                  layout: widget.layout,
                  textCache: _textCache,
                  highlightBounds: _highlightBounds,
                  waveform: widget.waveform,
                  waveformTiles: _waveformTiles,
                  devicePixelRatio: devicePixelRatio,
                  tempo: widget.tempo,
                  subdivisionsPerBeat: widget.subdivisionsPerBeat,
                  loopRegion: widget.loopRegion,
                  totalSeconds: widget.totalSeconds,
                  audioLoaded: widget.audioLoaded,
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                willChange: true,
                painter: TabTimelineForegroundPainter(
                  scrollOffset: _scrollOffset,
                  layout: widget.layout,
                  textCache: _textCache,
                  notes: widget.notes,
                  selection: widget.selection,
                  playhead: widget.playhead,
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Scrollbar(
              controller: widget.controller,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: widget.controller,
                scrollDirection: Axis.horizontal,
                // Transparent and unpainted — it exists to own the scroll
                // extent, the scrollbar, and hit testing in track (content)
                // coordinates, which is the same space the layers paint in
                // and the same one `TabTimelineLayout` does its time<->pixel
                // math in.
                child: SizedBox(
                  width: widget.layout.contentWidth(widget.totalSeconds),
                  child: RawGestureDetector(
                    behavior: HitTestBehavior.opaque,
                    gestures: {
                      TapGestureRecognizer:
                          GestureRecognizerFactoryWithHandlers<
                              TapGestureRecognizer>(
                        () => TapGestureRecognizer(),
                        (instance) => instance.onTapUp = widget.onTapUp,
                      ),
                      _NoteDragGestureRecognizer:
                          GestureRecognizerFactoryWithHandlers<
                              _NoteDragGestureRecognizer>(
                        () => _NoteDragGestureRecognizer(
                          accepts: (position) =>
                              !widget.layout.isWaveformY(position.dy) &&
                              widget.hitTestNote(position),
                        ),
                        (instance) {
                          instance
                            ..onStart = widget.onPanStart
                            ..onUpdate = widget.onPanUpdate
                            ..onEnd = widget.onPanEnd;
                        },
                      ),
                      _LoopDragGestureRecognizer:
                          GestureRecognizerFactoryWithHandlers<
                              _LoopDragGestureRecognizer>(
                        () => _LoopDragGestureRecognizer(
                          accepts: (position) =>
                              widget.layout.isWaveformY(position.dy),
                        ),
                        (instance) {
                          instance
                            ..onStart = _handleLoopStart
                            ..onUpdate = _handleLoopUpdate
                            ..onEnd = _handleLoopEnd;
                        },
                      ),
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
