import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/stt/stt_pricing.dart';

void main() {
  test('gpt-transcribe uses 0.0045 per minute', () {
    expect(
      SttPricing.usd(model: 'gpt-transcribe', billedSeconds: 60),
      closeTo(0.0045, 1e-9),
    );
  });

  test('gpt-transcribe ignores tokens and stays per-minute', () {
    expect(
      SttPricing.usd(
        model: 'gpt-transcribe',
        billedSeconds: 60,
        inputTokens: 1000000,
        outputTokens: 1000,
      ),
      closeTo(0.0045, 1e-9),
    );
  });

  test('mini transcribe uses per-minute when no tokens', () {
    expect(
      SttPricing.usd(model: 'gpt-4o-mini-transcribe', billedSeconds: 60),
      closeTo(0.003, 1e-9),
    );
  });

  test('whisper uses 0.006 per minute', () {
    expect(
      SttPricing.usd(model: 'whisper-1', billedSeconds: 30),
      closeTo(0.003, 1e-9),
    );
  });

  test('token usage preferred over minutes for mini', () {
    final usd = SttPricing.usd(
      model: 'gpt-4o-mini-transcribe',
      billedSeconds: 60,
      inputTokens: 1000000,
      outputTokens: 0,
    );
    expect(usd, closeTo(1.25, 1e-9));
  });

  test('on-device qwen asr is free', () {
    expect(
      SttPricing.usd(
        model: 'qwen3-asr:0.6b',
        billedSeconds: 600,
        inputTokens: 1000,
      ),
      0,
    );
  });
}
