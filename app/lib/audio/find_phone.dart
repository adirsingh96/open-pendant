import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/app_theme.dart';
import 'wav_writer.dart';

/// Two-note chirp used to locate the host phone. 22.05 kHz 16-bit mono WAV.
Uint8List findPhoneToneWav({int sampleRate = 22050}) {
  const maxAmp = 22000.0;
  final pcm = BytesBuilder();

  void silence(int ms) {
    final n = sampleRate * ms ~/ 1000;
    for (var i = 0; i < n; i++) {
      pcm.add(const [0, 0]);
    }
  }

  void tone(double hz, int ms) {
    final n = sampleRate * ms ~/ 1000;
    if (n <= 0) {
      return;
    }
    for (var i = 0; i < n; i++) {
      final env = math.sin(math.pi * i / n);
      final s = (math.sin(2 * math.pi * hz * i / sampleRate) * maxAmp * env)
          .round()
          .clamp(-32767, 32767);
      pcm.add([s & 0xff, (s >> 8) & 0xff]);
    }
  }

  tone(880, 160);
  silence(70);
  tone(1174.7, 180);
  silence(70);
  tone(880, 160);
  silence(400);
  return Uint8List.fromList(
    pcmToWav(pcm: pcm.toBytes(), sampleRate: sampleRate),
  );
}

/// Loops a locate tone on the phone until stopped, timed out, or toggled off.
class FindPhoneTone {
  static const ringFor = Duration(seconds: 40);

  AudioPlayer? _player;
  Timer? _deadline;
  Timer? _haptic;
  OverlayEntry? _overlay;
  bool _active = false;
  int _gen = 0;

  bool get isActive => _active;

  Future<void> toggle({
    OverlayState? overlay,
    bool skipIfPhoneMic = false,
  }) async {
    if (_active) {
      await stop();
      return;
    }
    if (skipIfPhoneMic) {
      return;
    }
    await start(overlay: overlay);
  }

  Future<void> start({OverlayState? overlay}) async {
    if (_active) {
      return;
    }
    _active = true;
    final gen = ++_gen;
    _showOverlay(overlay);
    _haptic?.cancel();
    _haptic = Timer.periodic(const Duration(milliseconds: 900), (_) {
      HapticFeedback.heavyImpact();
    });
    HapticFeedback.heavyImpact();
    _deadline?.cancel();
    _deadline = Timer(ringFor, () {
      if (gen == _gen) {
        unawaited(stop());
      }
    });
    try {
      final player = AudioPlayer();
      if (!_active || gen != _gen) {
        await player.dispose();
        return;
      }
      _player = player;
      await player.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            isSpeakerphoneOn: true,
            stayAwake: true,
            audioMode: AndroidAudioMode.normal,
            contentType: AndroidContentType.sonification,
            usageType: AndroidUsageType.alarm,
            audioFocus: AndroidAudioFocus.gain,
          ),
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.playback,
            options: const {AVAudioSessionOptions.duckOthers},
          ),
        ),
      );
      await player.setReleaseMode(ReleaseMode.loop);
      await player.setVolume(1.0);
      if (!_active || gen != _gen) {
        return;
      }
      await player.play(
        BytesSource(findPhoneToneWav(), mimeType: 'audio/wav'),
      );
    } catch (e) {
      debugPrint('FindPhoneTone.start: $e');
    }
  }

  Future<void> stop() async {
    _gen++;
    _active = false;
    _deadline?.cancel();
    _deadline = null;
    _haptic?.cancel();
    _haptic = null;
    _overlay?.remove();
    _overlay = null;
    final player = _player;
    _player = null;
    if (player != null) {
      try {
        await player.stop();
        await player.dispose();
      } catch (e) {
        debugPrint('FindPhoneTone.stop: $e');
      }
    }
  }

  void dispose() {
    unawaited(stop());
  }

  void _showOverlay(OverlayState? overlay) {
    _overlay?.remove();
    _overlay = null;
    if (overlay == null) {
      return;
    }
    _overlay = OverlayEntry(
      builder: (context) => _FindPhoneBarrier(onStop: () => unawaited(stop())),
    );
    overlay.insert(_overlay!);
  }
}

class _FindPhoneBarrier extends StatelessWidget {
  const _FindPhoneBarrier({required this.onStop});

  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.paper.withValues(alpha: 0.94),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onStop,
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 36),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    LucideIcons.smartphone,
                    size: 56,
                    color: AppColors.accent,
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'Finding this phone',
                    textAlign: TextAlign.center,
                    style: AppText.headline,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Tap anywhere to stop. Double-click the pendant again also stops.',
                    textAlign: TextAlign.center,
                    style: AppText.sub.copyWith(fontSize: 14, height: 1.35),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
