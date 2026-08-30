import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/db/models.dart';
import 'package:openpendant/stt/speaker_spans.dart';

void main() {
  test('speakerForInterval uses overlap', () {
    final spans = [
      SpeakerSpan(startS: 0, endS: 1.2, name: 'Aditya'),
      SpeakerSpan(startS: 1.0, endS: 2.5, name: 'Sushma'),
    ];
    expect(
      speakerForInterval(startS: 0.1, endS: 0.4, spans: spans),
      'Aditya',
    );
    expect(
      speakerForInterval(startS: 1.4, endS: 2.0, spans: spans),
      'Sushma',
    );
    expect(speakerForInterval(startS: 0, endS: 1, spans: const []), isNull);
  });

  test('mergeCloseSegments joins word timestamps', () {
    final t0 = DateTime.utc(2026, 8, 25);
    final segs = [
      TranscriptSegment(
        startS: 0,
        endS: 0.2,
        spokenAt: t0,
        text: 'hi',
      ),
      TranscriptSegment(
        startS: 0.25,
        endS: 0.5,
        spokenAt: t0,
        text: 'there',
      ),
      TranscriptSegment(
        startS: 2.0,
        endS: 2.4,
        spokenAt: t0,
        text: 'later',
      ),
    ];
    final m = mergeCloseSegments(segs);
    expect(m, hasLength(2));
    expect(m.first.text, 'hi there');
    expect(m.last.text, 'later');
  });
}
