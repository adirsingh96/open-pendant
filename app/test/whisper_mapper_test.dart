import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/stt/stt_pricing.dart';
import 'package:openpendant/stt/whisper_mapper.dart';

void main() {
  test('whisper mapper uses token timestamps and skips specials', () {
    final t0 = DateTime.utc(2026, 9, 2);
    final out = whisperToTranscript(
      text: '<|startoftranscript|> hello there later',
      tokens: [
        '<|startoftranscript|>',
        ' hello',
        ' there',
        ' later',
      ],
      timestamps: [0, 0.1, 0.25, 1.2],
      startedAt: t0,
    );
    expect(out.model, whisperTurboModelId);
    expect(out.costUsd, 0);
    expect(out.segments, hasLength(2));
    expect(out.segments[0].text, 'hello there');
    expect(out.segments[1].text, 'later');
    expect(out.segments[0].startS, closeTo(0.1, 0.01));
    expect(out.segments[1].startS, closeTo(1.2, 0.01));
  });

  test('whisper mapper falls back to one segment', () {
    final out = whisperToTranscript(
      text: '  one clip  ',
      tokens: const [],
      timestamps: const [],
      startedAt: DateTime.utc(2026, 9, 2),
    );
    expect(out.segments, hasLength(1));
    expect(out.segments.single.text, 'one clip');
    expect(out.text, 'one clip');
  });

  test('on-device whisper is free', () {
    expect(
      SttPricing.usd(
        model: whisperTurboModelId,
        billedSeconds: 30,
        inputTokens: 1000,
      ),
      0,
    );
    expect(
      SttPricing.usd(
        model: qwen3AsrModelId,
        billedSeconds: 30,
        inputTokens: 1000,
      ),
      0,
    );
  });

  test('Urdu script is detected, Devanagari is not', () {
    expect(textLooksLikeUrdu('آپ کیسے ہیں'), isTrue);
    expect(textLooksLikeUrdu('आप कैसे हैं'), isFalse);
    expect(textLooksLikeUrdu('hello there'), isFalse);
    expect(whisperLangIsUrdu('<|ur|>'), isTrue);
    expect(whisperLangIsUrdu('hi'), isFalse);
    expect(whisperLangIsHindi('<|hi|>'), isTrue);
    expect(textLooksLikeDevanagari('आप कैसे हैं'), isTrue);
    expect(clipLooksLikeHindi(lang: 'hi', text: 'hmm'), isTrue);
    expect(clipLooksLikeHindi(lang: 'en', text: 'hello'), isFalse);
  });

  test('prefers Indic when Whisper wrote English for Hindi speech', () {
    expect(
      preferIndicTranscript(
        whisperLang: 'en',
        whisperText: 'how are you what is the meeting',
        indicText: 'आप कैसे हैं बैठक क्या है',
      ),
      isTrue,
    );
    expect(
      preferIndicTranscript(
        whisperLang: 'en',
        whisperText: 'let us start the meeting',
        indicText: 'abc',
      ),
      isFalse,
    );
  });

  test('code-switch probes fire when start and end disagree', () {
    expect(
      probesSuggestCodeSwitch(['hello meeting notes', 'hello meeting notes']),
      isFalse,
    );
    expect(
      probesSuggestCodeSwitch(['hello meeting notes', 'मेरा नाम क्या है']),
      isTrue,
    );
    expect(guessScript('language English<asr_text>hello there'), 'latin');
    expect(stripQwenAsrPrefix('language Hindi<asr_text>नमस्ते'), 'नमस्ते');
  });

  test('whisper mapper offset shifts fallback segment', () {
    final out = whisperToTranscript(
      text: 'hi',
      tokens: const [],
      timestamps: const [],
      startedAt: DateTime.utc(2026, 9, 2),
      offsetS: 4,
      spanS: 2,
    );
    expect(out.segments.single.startS, closeTo(4, 0.01));
    expect(out.segments.single.endS, closeTo(6, 0.01));
  });

  test('picks Hindi vs English per window, bilingual when mixed', () {
    expect(
      pickCodeSwitchWindow(
        hindi: 'मेरा नाम क्या है',
        english: 'what is my name',
      ),
      contains('मेरा'),
    );
    expect(
      pickCodeSwitchWindow(
        hindi: 'लेट अस स्टार्ट',
        english: 'let us start the meeting',
      ),
      'let us start the meeting',
    );
    expect(
      pickCodeSwitchWindow(
        hindi: 'मेरा नाम',
        english: 'my meeting is at nine',
        bilingual: 'मेरा meeting है',
      ),
      'मेरा meeting है',
    );
  });
}
