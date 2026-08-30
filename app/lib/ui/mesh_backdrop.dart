import 'dart:math' as math;

import 'package:flutter/material.dart';

class MeshBackdrop extends StatefulWidget {
  const MeshBackdrop({super.key});

  @override
  State<MeshBackdrop> createState() => _MeshBackdropState();
}

class _MeshBackdropState extends State<MeshBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  )..repeat();

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
        final t = _c.value * math.pi * 2;
        return DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFE7F0FF),
                Color(0xFFF3EAFF),
                Color(0xFFD9ECFF),
              ],
            ),
          ),
          child: Stack(
            children: [
              _blob(
                Alignment(
                    -0.85 + 0.12 * math.sin(t), -0.9 + 0.08 * math.cos(t)),
                const Color(0x88A8C8FF),
                1.35,
              ),
              _blob(
                Alignment(
                    0.95 + 0.08 * math.cos(t * 0.8), -0.2 + 0.1 * math.sin(t)),
                const Color(0x77D4B8FF),
                1.15,
              ),
              _blob(
                Alignment(
                    -0.2 + 0.1 * math.sin(t * 1.1), 1.05 + 0.06 * math.cos(t)),
                const Color(0x66B8F0FF),
                1.4,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _blob(Alignment a, Color color, double radius) {
    return Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: a,
            radius: radius,
            colors: [color, color.withValues(alpha: 0)],
          ),
        ),
      ),
    );
  }
}
