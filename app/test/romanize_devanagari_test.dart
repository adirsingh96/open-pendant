import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/db/models.dart';
import 'package:openpendant/stt/romanize_devanagari.dart';

void main() {
  test('romanizes मेरा नाम क्या है', () {
    final out = romanizeDevanagari('मेरा नाम क्या है');
    expect(out.toLowerCase(), contains('mera'));
    expect(out.toLowerCase(), contains('naam'));
    expect(out.toLowerCase(), contains('kya'));
    expect(out.toLowerCase(), contains('hai'));
    expect(RegExp(r'[\u0900-\u097F]').hasMatch(out), isFalse);
  });

  test('leaves English alone', () {
    expect(romanizeDevanagari('hello meeting'), 'hello meeting');
  });

  test('romanizeTranscript only rewrites Devanagari', () {
    final latin = TranscriptResult(
      text: 'hello',
      model: 'whisper:large-v3-turbo',
      segments: const [],
    );
    expect(identical(romanizeTranscript(latin), latin), isTrue);
    final hi = TranscriptResult(
      text: 'मेरा नाम',
      model: 'indicconformer:hi',
      segments: const [],
    );
    expect(romanizeTranscript(hi).text.toLowerCase(), contains('mera'));
  });
}
