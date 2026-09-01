import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/calendar/note_command.dart';
import 'package:openpendant/db/models.dart';

void main() {
  test('wake phrase strips take a note', () {
    expect(
      calendarNoteFromText('Take a note, call the dentist tomorrow'),
      'call the dentist tomorrow',
    );
    expect(
      calendarNoteFromText('take a note buy milk'),
      'buy milk',
    );
    expect(
      calendarNoteFromText('hey take a note of the WiFi password'),
      'the WiFi password',
    );
    expect(
      calendarNoteFromText(
        'After lunch. Take a note: ship the UF2 tonight',
      ),
      'ship the UF2 tonight',
    );
    expect(calendarNoteFromText('take a note'), isNull);
    expect(calendarNoteFromText('we should ship tomorrow'), isNull);
  });

  test('calendarNoteFromClip uses wearer text', () {
    final segs = [
      TranscriptSegment(
        startS: 0,
        endS: 1,
        spokenAt: DateTime.utc(2026, 8, 22),
        text: 'noise',
        speaker: 'B',
      ),
      TranscriptSegment(
        startS: 1,
        endS: 2,
        spokenAt: DateTime.utc(2026, 8, 22, 0, 0, 1),
        text: 'Take a note, park the car',
        speaker: 'Aditya',
      ),
    ];
    expect(
      calendarNoteFromClip(segs: segs, fallback: 'all', wearer: 'Aditya'),
      'park the car',
    );
  });

  test('note commands are dropped from journal text', () {
    expect(leftoverAfterNoteCommand('Take a note, buy milk'), isEmpty);
    expect(
      leftoverAfterNoteCommand('After lunch. Take a note: ship tonight'),
      'After lunch.',
    );
    expect(
      leftoverAfterNoteCommand('we should ship tomorrow'),
      'we should ship tomorrow',
    );
    final segs = [
      TranscriptSegment(
        startS: 0,
        endS: 1,
        spokenAt: DateTime.utc(2026, 8, 22),
        text: 'hello there',
        speaker: 'Aditya',
      ),
      TranscriptSegment(
        startS: 1,
        endS: 2,
        spokenAt: DateTime.utc(2026, 8, 22, 0, 0, 1),
        text: 'Take a note, park the car',
        speaker: 'Aditya',
      ),
    ];
    final kept = segsWithoutNoteCommands(segs);
    expect(kept, hasLength(1));
    expect(kept.single.text, 'hello there');
    expect(joinSegmentText(kept), 'Aditya: hello there');
    expect(joinUnlabeledSegmentText(kept), 'hello there');
  });

  test('note text drops speaker prefixes', () {
    expect(
      noteTextWithoutSpeakers('Aditya: Work on the firmware'),
      'Work on the firmware',
    );
    expect(noteTextWithoutSpeakers('FYI: ship tonight'), 'FYI: ship tonight');
    expect(noteTextWithoutSpeakers('buy milk'), 'buy milk');
  });

  test('event title is truncated', () {
    expect(calendarEventTitle('buy milk'), 'buy milk');
    expect(calendarEventTitle('x' * 90).endsWith('…'), isTrue);
    expect(calendarEventTitle('x' * 90).length, 78);
  });
}
