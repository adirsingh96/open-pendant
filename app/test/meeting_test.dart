import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/db/meeting.dart';
import 'package:openpendant/db/models.dart';

void main() {
  test('meeting duration and live range label', () {
    final start = DateTime.utc(2026, 8, 29, 10);
    final live = MeetingRecord(id: 'm1', startedAt: start);
    expect(live.live, isTrue);
    expect(
      live.durationAt(start.add(const Duration(minutes: 12, seconds: 5))),
      const Duration(minutes: 12, seconds: 5),
    );
    expect(live.timeRangeLabel().contains('now'), isTrue);

    final done = MeetingRecord(
      id: 'm2',
      startedAt: start,
      endedAt: start.add(const Duration(minutes: 45)),
    );
    expect(done.live, isFalse);
    expect(done.timeRangeLabel().contains('–'), isTrue);
  });

  test('meeting preview prefers recap headline', () {
    final segs = [
      TranscriptSegment(
        startS: 0,
        endS: 1,
        spokenAt: DateTime.utc(2026, 8, 29, 10),
        text: 'hello there',
      ),
    ];
    final plain = MeetingRecord(
      id: 'm',
      startedAt: DateTime.utc(2026, 8, 29, 10),
      segments: segs,
    );
    expect(plain.preview, contains('hello'));
  });
}
