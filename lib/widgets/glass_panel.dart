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
