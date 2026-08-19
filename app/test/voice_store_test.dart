import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/stt/stt_pricing.dart';
import 'package:openpendant/stt/voice_store.dart';

void main() {
  test('diarize uses 0.006 per minute', () {
    expect(
      SttPricing.usd(model: 'gpt-4o-transcribe-diarize', billedSeconds: 60),
      closeTo(0.006, 1e-9),
    );
  });

  test('voice names drop angle brackets and newlines', () {
    expect(VoiceStore.sanitizeName('  Ada\n<bot>  '), 'Adabot');
  });
}
