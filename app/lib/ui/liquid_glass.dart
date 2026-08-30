import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Quiet dark surface: a breath lighter than the canvas, hairline edge.
/// `prominent` warms it with the accent (active states).
/// Kept as `LiquidGlass` so existing call sites convert without edits;
/// the `blur` flag is accepted and ignored.
class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.radius = 18,
    this.prominent = false,
    this.blur = true,
  });

  final Widget child;
  final double radius;
  final bool prominent;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: prominent ? AppColors.accentFaint : AppColors.card,
        borderRadius: r,
        border: Border.all(
          color: prominent ? const Color(0x59FF4D00) : AppColors.line,
        ),
      ),
      child: ClipRRect(borderRadius: r, child: child),
    );
  }
}

/// Preferred name going forward.
typedef Surface = LiquidGlass;
