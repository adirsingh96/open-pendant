import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ble/pendant_ble.dart';
import 'app_theme.dart';
import 'page_scaffold.dart';

/// Visual pendant pairing flow. Opens scanning immediately: sonar rings
/// pulse around the pendant mark while we look for it, then the sheet
/// settles into a success or failure state with a clear next step.
class PendantConnectSheet extends StatefulWidget {
  const PendantConnectSheet({
    super.key,
    required this.connect,
    required this.lastStatus,
    required this.name,
  });

  /// Runs the scan+connect. Returns null on success, a friendly
  /// error message on failure.
  final Future<String?> Function() connect;
  final PendantStatus? Function() lastStatus;
  final String name;

  @override
  State<PendantConnectSheet> createState() => _PendantConnectSheetState();
}

enum _Phase { scanning, success, failure }

class _PendantConnectSheetState extends State<PendantConnectSheet> {
  _Phase _phase = _Phase.scanning;
  String _error = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    setState(() => _phase = _Phase.scanning);
    final err = await widget.connect();
    if (!mounted) {
      return;
    }
    setState(() {
      if (err == null) {
        _phase = _Phase.success;
      } else {
        _phase = _Phase.failure;
        _error = err;
      }
    });
  }

  String _successCaption() {
    final s = widget.lastStatus();
    if (s == null) {
      return '${widget.name} is ready.';
    }
    if (s.usbPowered) {
      return '${widget.name} is ready, charging on USB.';
    }
    final pct = s.batteryPct;
    if (pct == null) {
      return '${widget.name} is ready.';
    }
    return '${widget.name} is ready. Battery at $pct%.';
  }

  @override
  Widget build(BuildContext context) {
    final scanning = _phase == _Phase.scanning;
    final success = _phase == _Phase.success;

    String title;
    String caption;
    switch (_phase) {
      case _Phase.scanning:
        title = 'Looking for your pendant';
        caption =
            'Keep it nearby. The pendant links to one device at a time, so '
            'close nRF Connect or other Bluetooth apps.';
      case _Phase.success:
        title = 'Connected';
        caption = _successCaption();
      case _Phase.failure:
        title = 'No pendant found';
        caption = _error;
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 2, 28, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            const SizedBox(height: 12),
            SizedBox(
              height: 170,
              child: Center(
                child: _SonarMark(phase: _phase),
              ),
            ),
            const SizedBox(height: 18),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Column(
                key: ValueKey(_phase),
                children: [
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: AppText.headline.copyWith(fontSize: 21),
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 300),
                    child: Text(
                      caption,
                      textAlign: TextAlign.center,
                      style: AppText.sub,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            if (scanning)
              Center(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              )
            else if (success)
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              )
            else ...[
              FilledButton(
                onPressed: _run,
                child: const Text('Try again'),
              ),
              const SizedBox(height: 6),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'Not now',
                    style: TextStyle(color: AppColors.muted),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The pendant mark with sonar rings while scanning, a steady accent ring
/// on success, and a quiet ring on failure.
class _SonarMark extends StatefulWidget {
  const _SonarMark({required this.phase});

  final _Phase phase;

  @override
  State<_SonarMark> createState() => _SonarMarkState();
}

class _SonarMarkState extends State<_SonarMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();

  @override
  void didUpdateWidget(_SonarMark old) {
    super.didUpdateWidget(old);
    if (widget.phase == _Phase.scanning && !_c.isAnimating) {
      _c.repeat();
    } else if (widget.phase != _Phase.scanning && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final success = widget.phase == _Phase.success;
    final failure = widget.phase == _Phase.failure;
    return SizedBox(
      width: 170,
      height: 170,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.phase == _Phase.scanning)
            AnimatedBuilder(
              animation: _c,
              builder: (context, _) => CustomPaint(
                size: const Size.square(170),
                painter: _SonarPainter(t: _c.value),
              ),
            ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 350),
            width: 92,
            height: 92,
            decoration: BoxDecoration(
              color: success ? AppColors.accentSoft : AppColors.card,
              shape: BoxShape.circle,
              border: Border.all(
                color: success
                    ? AppColors.accent
                    : failure
                        ? AppColors.lineStrong
                        : AppColors.lineStrong,
                width: success ? 1.6 : 1,
              ),
              boxShadow: success
                  ? const [
                      BoxShadow(
                        color: Color(0x40FF4D00),
                        blurRadius: 30,
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              success
                  ? LucideIcons.check
                  : failure
                      ? LucideIcons.bluetoothOff
                      : LucideIcons.bluetooth,
              size: 30,
              color: success
                  ? AppColors.accentDeep
                  : failure
                      ? AppColors.muted
                      : AppColors.ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _SonarPainter extends CustomPainter {
  _SonarPainter({required this.t});

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    const base = 46.0;
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1.0;
      final r = base + p * 42;
      final alpha = (1 - Curves.easeOut.transform(p)) * 0.45;
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = const Color(0xFFFF4D00)
              .withValues(alpha: alpha.clamp(0, 1) * (0.6 + 0.4 * math.sin(p))),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SonarPainter old) => old.t != t;
}
