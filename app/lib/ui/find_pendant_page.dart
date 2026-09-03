import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../ble/pendant_ble.dart';
import '../ble/pendant_proximity.dart';
import 'app_theme.dart';
import 'page_scaffold.dart';

/// Hot/cold finder. BLE RSSI is distance-ish, not a compass heading.
class FindPendantPage extends StatefulWidget {
  const FindPendantPage({super.key, required this.ble});

  final PendantBle ble;

  @override
  State<FindPendantPage> createState() => _FindPendantPageState();
}

class _FindPendantPageState extends State<FindPendantPage> {
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<bool>? _scanningSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Timer? _rssiPoll;
  Timer? _haptic;
  Timer? _scanKick;
  double? _smoothRssi;
  DateTime? _heardAt;
  bool _leds = false;
  bool _scanning = false;
  Duration _hapticGap = const Duration(milliseconds: 900);

  bool get _linked => widget.ble.isConnected;

  bool get _hasSignal {
    final t = _heardAt;
    if (t == null || _smoothRssi == null) {
      return false;
    }
    return DateTime.now().difference(t) < const Duration(milliseconds: 2800);
  }

  double get _proximity {
    final rssi = _smoothRssi;
    if (rssi == null || !_hasSignal) {
      return 0;
    }
    return pendantProximity(rssi.round());
  }

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _haptic?.cancel();
    _rssiPoll?.cancel();
    _scanKick?.cancel();
    unawaited(_scanSub?.cancel());
    unawaited(_scanningSub?.cancel());
    unawaited(_connSub?.cancel());
    unawaited(widget.ble.setLocate(false));
    unawaited(widget.ble.stopScan());
    super.dispose();
  }

  Future<void> _start() async {
    if (Platform.isAndroid) {
      final scan = await Permission.bluetoothScan.request();
      final connect = await Permission.bluetoothConnect.request();
      final loc = await Permission.locationWhenInUse.request();
      if (!scan.isGranted || !connect.isGranted || !loc.isGranted) {
        if (mounted) {
          setState(() {});
        }
        return;
      }
    }
    _watchLink();
    _haptic = Timer.periodic(const Duration(milliseconds: 120), _onHapticTick);
    await _applyMode();
  }

  void _watchLink() {
    unawaited(_connSub?.cancel());
    final d = widget.ble.device;
    if (d == null) {
      return;
    }
    _connSub = d.connectionState.listen((_) {
      if (!mounted) {
        return;
      }
      unawaited(_applyMode());
    });
  }

  Future<void> _applyMode() async {
    if (!mounted) {
      return;
    }
    if (_linked) {
      _scanKick?.cancel();
      _scanKick = null;
      await _scanningSub?.cancel();
      _scanningSub = null;
      await _scanSub?.cancel();
      _scanSub = null;
      await widget.ble.stopScan();
      _rssiPoll?.cancel();
      _rssiPoll = Timer.periodic(const Duration(milliseconds: 380), (_) {
        unawaited(_pollConnected());
      });
      unawaited(_pollConnected());
      final leds = await widget.ble.setLocate(true);
      if (mounted) {
        setState(() {
          _scanning = false;
          _leds = leds;
        });
      }
      return;
    }
    _rssiPoll?.cancel();
    _rssiPoll = null;
    unawaited(widget.ble.setLocate(false));
    await _beginScan();
  }

  Future<void> _pollConnected() async {
    final rssi = await widget.ble.readRssi();
    if (!mounted || rssi == null) {
      return;
    }
    _pushRssi(rssi);
  }

  Future<void> _beginScan() async {
    await _scanSub?.cancel();
    await _scanningSub?.cancel();
    if (!mounted) {
      return;
    }
    setState(() {
      _scanning = true;
      _leds = false;
    });
    try {
      _scanSub = await widget.ble.listenScanRssi(_pushRssi);
    } catch (_) {
      if (mounted) {
        setState(() => _scanning = false);
      }
      return;
    }
    _scanningSub = FlutterBluePlus.isScanning.listen((on) {
      if (!mounted) {
        return;
      }
      setState(() => _scanning = on || !_linked);
      if (!on && mounted && !_linked) {
        _scanKick?.cancel();
        _scanKick = Timer(const Duration(milliseconds: 600), () {
          if (mounted && !_linked) {
            unawaited(_beginScan());
          }
        });
      }
    });
  }

  void _pushRssi(int rssi) {
    if (!mounted) {
      return;
    }
    final prev = _smoothRssi;
    final next = prev == null ? rssi.toDouble() : prev * 0.62 + rssi * 0.38;
    setState(() {
      _smoothRssi = next;
      _heardAt = DateTime.now();
    });
  }

  DateTime _lastHaptic = DateTime.fromMillisecondsSinceEpoch(0);

  void _onHapticTick(Timer _) {
    if (!mounted || !_hasSignal) {
      return;
    }
    final gap = pendantProximityHaptic(_proximity, hasSignal: true);
    if (gap != _hapticGap) {
      _hapticGap = gap;
    }
    final now = DateTime.now();
    if (now.difference(_lastHaptic) < gap) {
      return;
    }
    _lastHaptic = now;
    HapticFeedback.mediumImpact();
  }

  @override
  Widget build(BuildContext context) {
    final p = _proximity;
    final has = _hasSignal;
    final rssi = _smoothRssi?.round();
    final label = pendantProximityLabel(p, hasSignal: has);
    String hint;
    if (has && p >= 0.82) {
      hint = 'You are on top of it.';
    } else if (has) {
      hint = 'Walk, pause, watch the ring. Stronger means closer.';
    } else if (_scanning) {
      hint = 'Listening for advertisements. Wake the pendant if it is asleep.';
    } else if (_linked) {
      hint = 'Waiting for a Bluetooth reading.';
    } else {
      hint = 'Turn Bluetooth on and keep the app open.';
    }
    return PageScaffold(
      title: 'Find pendant',
      caption:
          'Bluetooth can tell closer vs farther, not which way to walk. This is not GPS.',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
        children: [
          const SizedBox(height: 12),
          Center(
            child: _ProximityDial(proximity: p, hasSignal: has),
          ),
          const SizedBox(height: 28),
          Text(
            label,
            textAlign: TextAlign.center,
            style: AppText.headline,
          ),
          const SizedBox(height: 8),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: AppText.sub.copyWith(fontSize: 13.5, height: 1.4),
          ),
          const SizedBox(height: 22),
          Text(
            [
              if (_linked) 'Connected',
              if (_scanning && !_linked) 'Scanning',
              if (rssi != null && has) '$rssi dBm',
              if (_leds) 'LEDs flashing',
            ].join('  ·  '),
            textAlign: TextAlign.center,
            style: AppText.micro.copyWith(letterSpacing: 0.6),
          ),
          if (_linked && !_leds) ...[
            const SizedBox(height: 10),
            Text(
              'Flash firmware with locate support to blink the board LEDs.',
              textAlign: TextAlign.center,
              style: AppText.sub.copyWith(fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProximityDial extends StatefulWidget {
  const _ProximityDial({required this.proximity, required this.hasSignal});

  final double proximity;
  final bool hasSignal;

  @override
  State<_ProximityDial> createState() => _ProximityDialState();
}

class _ProximityDialState extends State<_ProximityDial>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void didUpdateWidget(covariant _ProximityDial oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ms = widget.hasSignal
        ? (1600 - 1100 * widget.proximity).round().clamp(420, 1600)
        : 2200;
    final next = Duration(milliseconds: ms);
    if (_c.duration != next) {
      _c.duration = next;
      if (!_c.isAnimating) {
        _c.repeat();
      }
    }
  }

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
        return CustomPaint(
          size: const Size.square(260),
          painter: _DialPainter(
            t: _c.value,
            proximity: widget.proximity,
            hasSignal: widget.hasSignal,
          ),
        );
      },
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.t,
    required this.proximity,
    required this.hasSignal,
  });

  final double t;
  final double proximity;
  final bool hasSignal;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final maxR = size.shortestSide / 2;
    for (var i = 3; i >= 1; i--) {
      final r = maxR * (0.34 + 0.22 * i);
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = AppColors.lineStrong.withValues(alpha: 0.9),
      );
    }
    if (hasSignal) {
      final wave = maxR * (0.28 + 0.72 * ((t + 0.15) % 1.0));
      canvas.drawCircle(
        c,
        wave,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = AppColors.accent.withValues(alpha: 0.22 * (1 - t)),
      );
      final fillR = maxR * (0.22 + 0.62 * proximity);
      canvas.drawCircle(
        c,
        fillR,
        Paint()
          ..shader = ui.Gradient.radial(
            c,
            fillR,
            [
              AppColors.accent.withValues(alpha: 0.55),
              AppColors.accent.withValues(alpha: 0.08),
              const Color(0x00FF4D00),
            ],
            const [0.0, 0.62, 1.0],
          ),
      );
    }
    canvas.drawCircle(
      c,
      7,
      Paint()..color = hasSignal ? AppColors.accent : AppColors.faint,
    );
  }

  @override
  bool shouldRepaint(covariant _DialPainter old) {
    return old.t != t ||
        old.proximity != proximity ||
        old.hasSignal != hasSignal;
  }
}
