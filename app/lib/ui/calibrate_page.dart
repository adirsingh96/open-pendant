import 'dart:async';

import 'package:flutter/material.dart';

import '../audio/speech_vad.dart';
import '../ble/pendant_ble.dart';
import '../stt/vad_cal.dart';
import 'app_theme.dart';
import 'liquid_glass.dart';
import 'page_scaffold.dart';

class CalibratePage extends StatefulWidget {
  const CalibratePage({
    super.key,
    required this.ble,
    required this.connected,
    required this.armed,
  });

  final PendantBle ble;
  final bool connected;
  final bool armed;

  @override
  State<CalibratePage> createState() => _CalibratePageState();
}

class _CalibratePageState extends State<CalibratePage> {
  static const _script =
      'Hello. I am wearing OpenPendant the way I will all day. '
      'This is my normal speaking voice at my usual distance from the mic. '
      'Please use this sample so soft speech is still detected. Thank you.';

  bool _recording = false;
  int _seconds = 0;
  Timer? _tick;
  String? _status;

  @override
  void dispose() {
    _tick?.cancel();
    if (_recording) {
      widget.ble.stopRecording();
    }
    super.dispose();
  }

  Future<void> _start() async {
    if (widget.armed) {
      setState(() => _status = 'Stop Record on the home screen first.');
      return;
    }
    if (!widget.connected) {
      setState(() => _status = 'Connect the pendant first.');
      return;
    }
    setState(() {
      _recording = true;
      _seconds = 0;
      _status = 'Wear the pendant as usual and read the script…';
    });
    try {
      await widget.ble.startRecording(() {
        if (mounted) {
          setState(() {});
        }
      });
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          return;
        }
        setState(() => _seconds = t.tick);
        if (t.tick >= 12) {
          _stop();
        }
      });
    } catch (e) {
      setState(() {
        _recording = false;
        _status = '$e';
      });
    }
  }

  Future<void> _stop() async {
    _tick?.cancel();
    _tick = null;
    if (!_recording) {
      return;
    }
    setState(() => _recording = false);
    try {
      await widget.ble.stopRecording();
      final pcm = widget.ble.reassembler.pcmBytes();
      widget.ble.reassembler.reset();
      final dur = pcm.length / 2 / 16000;
      if (dur < 4) {
        setState(
          () => _status =
              'Need at least ~4 seconds of speech (got ${dur.toStringAsFixed(1)}s).',
        );
        return;
      }
      final floor = suggestEnergyFloor(pcm);
      await VadCal.save(floor);
      setState(
        () => _status = 'Saved. Soft speech at this wear distance should pass. '
            '${VadCal.statusLine()}',
      );
    } catch (e) {
      setState(() => _status = '$e');
    }
  }

  Future<void> _reset() async {
    await VadCal.clear();
    setState(() => _status = 'Back to default VAD.');
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: 'Calibrate mic',
      caption:
          'Wear the pendant the way you normally will and speak at your '
          'usual volume. This sets a personal threshold so quiet talk is '
          'not skipped.',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(28, 12, 28, 28),
        children: [
          Text(VadCal.statusLine().toUpperCase(), style: AppText.micro),
          const SizedBox(height: 14),
          Text('READ THIS ALOUD', style: AppText.micro),
          const SizedBox(height: 10),
          Surface(
            radius: 16,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _script,
                style: AppText.body.copyWith(fontSize: 14.5, height: 1.55),
              ),
            ),
          ),
          const SizedBox(height: 18),
          if (_recording)
            FilledButton(
              onPressed: _stop,
              child: Text('Stop (${_seconds}s)'),
            )
          else
            FilledButton(
              onPressed: _start,
              child: const Text('Start calibration'),
            ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: _recording ? null : _reset,
            child: const Text('Reset to default'),
          ),
          if (_status != null) ...[
            const SizedBox(height: 8),
            Text(_status!, style: AppText.sub.copyWith(fontSize: 12.5)),
          ],
        ],
      ),
    );
  }
}
