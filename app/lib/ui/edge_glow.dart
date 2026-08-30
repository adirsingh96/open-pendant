import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Siri-style screen edge light. A thin luminous multi-hue band hugs the
/// window edge with a soft bloom behind it. Two counter-rotating sweeps
/// make the color flow; the whole band breathes on its own and swells
/// with [level] (0..1 mic energy). Additive blending keeps it luminous
/// on the dark canvas instead of muddy.
class EdgeGlow extends StatefulWidget {
  const EdgeGlow({
    super.key,
    required this.active,
    required this.level,
    required this.child,
  });

  final bool active;
  final double level;
  final Widget child;

  @override
  State<EdgeGlow> createState() => _EdgeGlowState();
}

class _EdgeGlowState extends State<EdgeGlow> with TickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  );
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
    reverseDuration: const Duration(milliseconds: 800),
  );
  double _smooth = 0;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      _spin.repeat();
      _fade.forward();
    }
  }

  @override
  void didUpdateWidget(EdgeGlow old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      _spin.repeat();
      _fade.forward();
    } else if (!widget.active && old.active) {
      _fade.reverse().whenComplete(() {
        if (mounted && !widget.active) {
          _spin.stop();
        }
      });
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        IgnorePointer(
          child: AnimatedBuilder(
            animation: Listenable.merge([_spin, _fade]),
            builder: (context, _) {
              if (_fade.value == 0) {
                return const SizedBox.shrink();
              }
              _smooth += (widget.level.clamp(0.0, 1.0) - _smooth) * 0.22;
              return CustomPaint(
                painter: _EdgeGlowPainter(
                  t: _spin.value,
                  opacity: Curves.easeOut.transform(_fade.value),
                  level: _smooth,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _EdgeGlowPainter extends CustomPainter {
  _EdgeGlowPainter({
    required this.t,
    required this.opacity,
    required this.level,
  });

  final double t;
  final double opacity;
  final double level;

  // Vivid Apple-Intelligence hues, warm-biased for the brand.
  static const _hues = [
    Color(0xFFFF3D0C),
    Color(0xFFFF9500),
    Color(0xFFFF2E7E),
    Color(0xFF9B5CFF),
    Color(0xFFFF5E3A),
    Color(0xFFFF3D0C),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final breath = 0.5 + 0.5 * math.sin(t * math.pi * 4);
    final energy =
        (opacity * (0.62 + 0.18 * breath + 0.55 * level)).clamp(0.0, 1.2);

    Shader sweep(double rot) => SweepGradient(
          center: Alignment.center,
          transform: GradientRotation(rot),
          colors: _hues,
        ).createShader(rect);

    final s1 = sweep(t * math.pi * 2);
    final s2 = sweep(-t * math.pi * 2 * 0.6 + 2.1);

    void band(Shader s, double stroke, double sigma, double alpha) {
      // Stroke centered just outside the edge so only its inner half
      // shows: a tight band that hugs the window like Siri's.
      final rr = RRect.fromRectAndRadius(
        rect.inflate(stroke * 0.30),
        const Radius.circular(18),
      );
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..shader = s
          ..blendMode = BlendMode.plus
          ..color = Colors.white.withValues(alpha: (alpha * energy).clamp(0, 1))
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, sigma),
      );
    }

    // Wide soft bloom (counter-rotating for shimmer), mid halo, bright core.
    band(s2, 46 + 30 * level, 26, 0.30);
    band(s1, 18 + 12 * level, 9, 0.55);
    band(s1, 6 + 4 * level, 2.5, 0.95);
  }

  @override
  bool shouldRepaint(covariant _EdgeGlowPainter old) =>
      old.t != t || old.opacity != opacity || old.level != level;
}
