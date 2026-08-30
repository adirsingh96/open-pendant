import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../ble/pcm_reassembler.dart';

class DeviceMic {
  final _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  bool running = false;

  static const _configs = [
    RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
    ),
    RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 44100,
      numChannels: 1,
    ),
    RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 48000,
      numChannels: 1,
    ),
  ];

  Future<void> start({
    required PcmReassembler pcm,
    required void Function() onPacket,
  }) async {
    if (!await _rec.hasPermission()) {
      throw Exception(
        'Allow Microphone for OpenPendant in System Settings → Privacy & Security.',
      );
    }
    if (running) {
      await stop();
    }
    Object? lastErr;
    for (final cfg in _configs) {
      try {
        await _tryStart(cfg: cfg, pcm: pcm, onPacket: onPacket);
        debugPrint('DeviceMic started ${cfg.sampleRate} Hz');
        return;
      } catch (e) {
        lastErr = e;
        debugPrint('DeviceMic ${cfg.sampleRate} Hz failed: $e');
        await stop();
      }
    }
    throw Exception(
      'This Mac’s mic did not start. $lastErr '
      'Check System Settings → Privacy & Security → Microphone.',
    );
  }

  Future<void> _tryStart({
    required RecordConfig cfg,
    required PcmReassembler pcm,
    required void Function() onPacket,
  }) async {
    final first = Completer<void>();
    final stream = await _rec.startStream(cfg);
    running = true;
    _sub = stream.listen(
      (data) {
        if (data.isEmpty) {
          return;
        }
        pcm.addRaw(_to16k(data, cfg.sampleRate));
        if (!first.isCompleted) {
          first.complete();
        }
        onPacket();
      },
      onError: (Object e, StackTrace st) {
        if (!first.isCompleted) {
          first.completeError(e, st);
        }
      },
      onDone: () {
        if (!first.isCompleted) {
          first.completeError(Exception('Mic stream closed'));
        }
      },
    );
    await first.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => throw Exception('No audio from the Mac mic'),
    );
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    running = false;
    try {
      await _rec.stop();
    } catch (_) {}
  }
}

List<int> _to16k(List<int> pcm, int sampleRate) {
  if (sampleRate == 16000 || pcm.length < 4) {
    return pcm;
  }
  final step = sampleRate / 16000.0;
  final out = <int>[];
  var i = 0.0;
  final samples = pcm.length ~/ 2;
  while (true) {
    final src = i.floor();
    if (src >= samples) {
      break;
    }
    final b = src * 2;
    out.add(pcm[b]);
    out.add(pcm[b + 1]);
    i += step;
  }
  return out;
}
