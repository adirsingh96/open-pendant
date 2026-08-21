import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/db/models.dart';
import 'package:openpendant/stt/transcript_refine.dart';

TranscriptSegment _seg(String text) {
  return TranscriptSegment(
    startS: 0,
    endS: 1,
    spokenAt: DateTime.utc(2026, 8, 19),
    text: text,
    rawText: text,
    speaker: 'A',
  );
}

void main() {
  test('flags whisper junk and repeat loops', () {
    expect(looksLikeJunkPhrase('Thanks for watching'), isTrue);
    expect(looksLikeJunkPhrase('you'), isTrue);
    expect(hasRepeatLoop('the the the the cat'), isTrue);
    expect(clipNeedsRefine([_seg('Hello, this is a real sentence.')]), isFalse);
    expect(clipNeedsRefine([_seg('the the the the')]), isTrue);
  });

  test('applyRefineTurns keeps missing indexes and drops empty text', () {
    final orig = [_seg('keep me'), _seg('drop me')];
    final out = applyRefineTurns(
      original: orig,
      turns: [
        {'i': 1, 'text': '', 'speaker': 'A'},
      ],
    );
    expect(out[0].text, 'keep me');
    expect(out[1].text, isEmpty);
    expect(out[0].rawText, 'keep me');
  });
}
