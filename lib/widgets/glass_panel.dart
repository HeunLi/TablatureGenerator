import 'dart:ui';

import 'package:flutter/material.dart';

/// Shared translucent, blurred "glass" panel chrome — the dashboard's
/// project cards and the studio's toolbar/transport bar/floating edit
/// panel all use this so every surface in the app reads as one consistent
/// design language instead of each screen inventing its own card style.
///
/// Purely presentational (no tap/hover handling) — screens that need a
/// pressable glass surface wrap this in their own `InkWell`/`MouseRegion`
/// (see `DashboardScreen`'s `_GlassCard`) rather than this widget growing
/// interaction concerns it doesn't always need.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.padding = const EdgeInsets.all(12),
    this.opacity = 0.05,
    this.borderColor,
    this.blurSigma = 18,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry padding;
  final double opacity;
  final Color? borderColor;
  final double blurSigma;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            color: Colors.white.withValues(alpha: opacity),
            border: Border.all(
              color: (borderColor ?? Colors.white)
                  .withValues(alpha: borderColor != null ? 0.5 : 0.1),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

/// App-wide background gradient (also used by `DashboardScreen`) — kept
/// here so both screens are guaranteed to use the exact same colors rather
/// than two copies drifting apart.
const backgroundGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF12131A), Color(0xFF1B1E29)],
);

/// The dashboard's violet accent, reused here so the studio's chips/rings/
/// highlights are drawn from the same palette rather than a second one.
const accentColor = Color(0xFF7C5CFC);

/// Shared rounded shape, kept around for any spot that still wraps a plain
/// `AlertDialog` rather than [GlassAlertDialog].
const dialogShape =
    RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16)));

/// A drop-in `AlertDialog` replacement styled with the same glass chrome as
/// the rest of the app (dashboard cards, studio toolbar/transport/floating
/// panel) — used by every dialog (project rename/delete, BPM entry, export
/// settings, export progress) so none of them are left looking like a
/// stock Material dialog while everything around them is glass.
///
/// A plain `AlertDialog` with just a rounded `shape` was tried first and
/// turned out to be too subtle a change to actually read as "restyled" —
/// Material 3's default dialog already has ~28dp rounded corners, so a
/// 16dp override barely differs, and the opaque solid-gray surface is the
/// part that actually looks out of place next to the blurred glass used
/// everywhere else. This builds the dialog chrome from scratch instead of
/// theming `AlertDialog`, since `AlertDialog` doesn't expose a way to make
/// its surface a `BackdropFilter`.
class GlassAlertDialog extends StatelessWidget {
  const GlassAlertDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
    this.maxWidth = 420,
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;

  /// Widened by dialogs whose content is a table rather than a sentence —
  /// the tempo-map editor's rows don't fit the prose default.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      shape: dialogShape,
      child: GlassPanel(
        opacity: 0.09,
        blurSigma: 24,
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DefaultTextStyle(
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
                child: title,
              ),
              const SizedBox(height: 16),
              DefaultTextStyle(
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withValues(alpha: 0.75),
                ),
                child: content,
              ),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0) const SizedBox(width: 4),
                      actions[i],
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
