import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.radius = 28,
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
    final panel = ClipRRect(
      borderRadius: r,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: r,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: prominent
                      ? [
                          const Color(0xCCFFFFFF),
                          const Color(0x66B8D4FF),
                          const Color(0x55FFFFFF),
                        ]
                      : [
                          const Color(0xB8FFFFFF),
                          const Color(0x66FFFFFF),
                          const Color(0x4DB4C8E8),
                        ],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(painter: _DropletSheen(radius: radius)),
          ),
          child,
        ],
      ),
    );
    if (!blur) {
      return panel;
    }
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
        child: panel,
      ),
    );
  }
}

class _DropletSheen extends CustomPainter {
  const _DropletSheen({required this.radius});

  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.62, -0.92),
          radius: 1.05,
          colors: [
            Colors.white.withValues(alpha: 0.72),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );

    final bead = Rect.fromCenter(
      center: Offset(size.width * 0.2, size.height * 0.16),
      width: size.width * 0.38,
      height: math.max(18, size.height * 0.28),
    );
    canvas.drawOval(
      bead,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.55),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(bead),
    );

    final rim = RRect.fromRectAndRadius(
      rect.deflate(0.7),
      Radius.circular(radius - 0.7),
    );
    canvas.drawRRect(
      rim,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.35
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.85),
            Colors.white.withValues(alpha: 0.12),
            Colors.white.withValues(alpha: 0.4),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant _DropletSheen oldDelegate) =>
      oldDelegate.radius != radius;
}
