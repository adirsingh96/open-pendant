import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/audio/speech_vad.dart';

List<int> _sine({
  required int samples,
  required double hz,
  required int amp,
  int sampleRate = 16000,
}) {
  final out = <int>[];
  for (var i = 0; i < samples; i++) {
    final s = (amp * math.sin(2 * math.pi * hz * i / sampleRate)).round();
    out.add(s & 0xff);
    out.add((s >> 8) & 0xff);
  }
  return out;
}

void main() {
  test('keeps voiced 1 kHz and drops hush 7 kHz', () {
    final pcm = <int>[
      ..._sine(samples: 16000, hz: 80, amp: 2000),
      ..._sine(samples: 16000, hz: 1000, amp: 2500),
      ..._sine(samples: 16000, hz: 7000, amp: 2500),
    ];
    final speech = extractSpeech(pcm, padS: 0.05, minSpeechS: 0.25);
    expect(speech.originalDurationS, closeTo(3.0, 0.05));
    expect(speech.speechDurationS, greaterThan(0.7));
    expect(speech.speechDurationS, lessThan(1.6));
  });

  test('pcmHasVoice respects energy floor', () {
    final loud = _sine(samples: 512, hz: 1000, amp: 2500);
    expect(pcmHasVoice(loud), isTrue);
    expect(pcmHasVoice(loud, energyFloor: 1e20), isFalse);
    expect(pcmHasVoice(_sine(samples: 512, hz: 7000, amp: 2500)), isFalse);
  });

  test('suggestEnergyFloor follows soft speech', () {
    final soft = _sine(samples: 16000 * 5, hz: 1000, amp: 400);
    final floor = suggestEnergyFloor(soft);
    expect(pcmHasVoice(soft.sublist(0, 1024), energyFloor: floor), isTrue);
    expect(
      pcmHasVoice(_sine(samples: 512, hz: 1000, amp: 40), energyFloor: floor),
      isFalse,
    );
  });
}
