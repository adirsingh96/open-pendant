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

  test('overlayDiarization keeps Saaras words and OpenAI speakers', () {
    final t0 = DateTime.utc(2026, 8, 25);
    final words = TranscriptResult(
      text: 'hello there later',
      model: 'saaras:v4',
      segments: [
        TranscriptSegment(
          startS: 0,
          endS: 1.0,
          spokenAt: t0,
          text: 'hello there',
        ),
        TranscriptSegment(
          startS: 1.2,
          endS: 2.0,
          spokenAt: t0,
          text: 'later',
        ),
      ],
    );
    final diarize = TranscriptResult(
      text: 'Aditya: hi Sushma: bye',
      model: 'gpt-4o-transcribe-diarize',
      segments: [
        TranscriptSegment(
          startS: 0,
          endS: 1.05,
          spokenAt: t0,
          text: 'hi',
          speaker: 'Aditya',
        ),
        TranscriptSegment(
          startS: 1.1,
          endS: 2.1,
          spokenAt: t0,
          text: 'bye',
          speaker: 'Sushma',
        ),
      ],
    );
    final out = overlayDiarization(words: words, diarize: diarize);
    expect(out.segments, hasLength(2));
    expect(out.segments[0].text, 'hello there');
    expect(out.segments[0].speaker, 'Aditya');
    expect(out.segments[1].text, 'later');
    expect(out.segments[1].speaker, 'Sushma');
  });

  test('overlayDiarization splits one Saaras phrase across two speakers', () {
    final t0 = DateTime.utc(2026, 8, 25);
    final words = TranscriptResult(
      text: 'hello there later on',
      model: 'saaras:v4',
      segments: [
        TranscriptSegment(
          startS: 0,
          endS: 4.0,
          spokenAt: t0,
          text: 'hello there later on',
        ),
      ],
    );
    final diarize = TranscriptResult(
      text: 'Aditya: hello Sushma: later',
      model: 'gpt-4o-transcribe-diarize',
      segments: [
        TranscriptSegment(
          startS: 0,
          endS: 2.0,
          spokenAt: t0,
          text: 'hello',
          speaker: 'Aditya',
        ),
        TranscriptSegment(
          startS: 2.0,
          endS: 4.0,
          spokenAt: t0,
          text: 'later',
          speaker: 'Sushma',
        ),
      ],
    );
    final out = overlayDiarization(words: words, diarize: diarize);
    expect(out.segments, hasLength(2));
    expect(out.segments[0].speaker, 'Aditya');
    expect(out.segments[1].speaker, 'Sushma');
    expect(out.segments[0].text, 'hello there');
    expect(out.segments[1].text, 'later on');
  });
}
