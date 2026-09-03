import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Soft-blurred multicolor orb — peach, coral, rose, and lavender drifting
/// inside a breathing sphere, with a warm ambient glow behind it.
/// Swells gently with [level] (0..1 mic energy).
class AuroraOrb extends StatefulWidget {
  const AuroraOrb({super.key, this.size = 220, this.level = 0});

  final double size;
  final double level;

  @override
  State<AuroraOrb> createState() => _AuroraOrbState();
}

class _AuroraOrbState extends State<AuroraOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  )..repeat();
  double _smooth = 0;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        _smooth += (widget.level.clamp(0.0, 1.0) - _smooth) * 0.1;
        return CustomPaint(
          size: Size.square(widget.size),
          painter: _OrbPainter(t: _c.value, level: _smooth),
        );
      },
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.t, required this.level});

  final double t;
  final double level;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final base = size.shortestSide / 2;
    final breath = 0.5 + 0.5 * math.sin(t * math.pi * 2 * 2.5);
    final r = base * (0.74 + 0.035 * breath + 0.1 * level);

    // Ambient glow spilling past the orb.
    canvas.drawCircle(
      center,
      r * 1.55,
      Paint()
        ..shader = ui.Gradient.radial(
          center,
          r * 1.55,
          [
            const Color(0x59FF8A50),
            const Color(0x26FF6B7C),
            const Color(0x00FF6B7C),
          ],
          const [0.0, 0.55, 1.0],
        ),
    );

    // The orb: drifting blurred color fields inside a circular clip.
    canvas.save();
    canvas
        .clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: r)));
    canvas.drawRect(
      Rect.fromCircle(center: center, radius: r),
      Paint()..color = const Color(0xFFF3A87C),
    );

    void field(Color color, double phase, double orbit, double blob) {
      final a = t * math.pi * 2 + phase;
      final o = Offset(
        center.dx + math.cos(a) * r * orbit,
        center.dy + math.sin(a * 1.3 + phase) * r * orbit,
      );
      canvas.drawCircle(
        o,
        r * blob,
        Paint()
          ..color = color
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, r * 0.28),
      );
    }

    field(const Color(0xFFFFA53E), 0.4, 0.44, 0.68); // amber
    field(const Color(0xFFFF5E3A), 2.2, 0.52, 0.62); // coral
    field(const Color(0xFFDD4470), 3.9, 0.5, 0.58); // rose
    field(const Color(0xFF9E6BE8), 5.3, 0.56, 0.5); // violet
    field(const Color(0xFFFFD9A6), 1.4, 0.26, 0.42); // warm core

    // Top-light so the sphere reads dimensional.
    canvas.drawCircle(
      center.translate(-r * 0.28, -r * 0.4),
      r * 0.8,
      Paint()
        ..shader = ui.Gradient.radial(
          center.translate(-r * 0.28, -r * 0.4),
          r * 0.8,
          [const Color(0x33FFFFFF), const Color(0x00FFFFFF)],
        ),
    );
    // Deep edge shading at the lower rim.
    canvas.drawCircle(
      center.translate(r * 0.2, r * 0.45),
      r * 1.05,
      Paint()
        ..shader = ui.Gradient.radial(
          center.translate(r * 0.2, r * 0.45),
          r * 1.05,
          [const Color(0x00301008), const Color(0x40301008)],
          const [0.6, 1.0],
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _OrbPainter old) =>
      old.t != t || old.level != level;
}
