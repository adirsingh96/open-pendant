import 'dart:async';

import 'package:flutter/material.dart';

import '../audio/speech_vad.dart';
import '../ble/pendant_ble.dart';
import '../stt/vad_cal.dart';
import 'app_page.dart';

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
    return AppPage(
      appBar: AppBar(title: const Text('Calibrate mic')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Wear the pendant on your neck the way you normally will. '
            'Speak at your usual volume. We measure how loud your voice '
            'is at the mic and set a personal speech threshold so quiet '
            'talk is not skipped.',
          ),
          const SizedBox(height: 12),
          Text(VadCal.statusLine(),
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 12),
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Read this aloud',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _script,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          height: 1.45,
                        ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
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
          const SizedBox(height: 8),
          TextButton(
            onPressed: _recording ? null : _reset,
            child: const Text('Reset to default'),
          ),
          if (_status != null) ...[
            const SizedBox(height: 8),
            Text(_status!),
          ],
        ],
      ),
    );
  }
}
