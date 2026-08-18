import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/audio/speech_vad.dart';

List<int> _tone({required int samples, required int amp}) {
  final out = <int>[];
  for (var i = 0; i < samples; i++) {
    final s = amp;
    out.add(s & 0xff);
    out.add((s >> 8) & 0xff);
  }
  return out;
}

void main() {
  test('drops quiet frames and keeps loud speech', () {
    final pcm = <int>[
      ..._tone(samples: 16000, amp: 20),
      ..._tone(samples: 16000, amp: 3000),
      ..._tone(samples: 16000, amp: 20),
    ];
    final speech = extractSpeech(pcm, rmsThreshold: 450, padS: 0.05);
    expect(speech.speechDurationS, greaterThan(0.8));
    expect(speech.speechDurationS, lessThan(2.2));
    expect(speech.originalDurationS, closeTo(3.0, 0.05));
    final orig = speech.originalSeconds(0.1);
    expect(orig, greaterThan(0.8));
    expect(orig, lessThan(2.2));
  });
}
