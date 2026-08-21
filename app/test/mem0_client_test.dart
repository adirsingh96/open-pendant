import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/db/day_recap.dart';
import 'package:openpendant/mem0/mem0_client.dart';

void main() {
  test('mem0 pack includes day_key and follow-ups', () {
    final recap = DayRecap(
      dayKey: '2026-08-20',
      headline: 'Dinner and plans',
      arc: 'Caught up then decided to ship.',
      people: const ['Aditya'],
      languages: const ['en', 'hi'],
      chapters: const [],
      decisions: const ['Ship the journal UI'],
      followUps: [
        DayFollowUp(owner: 'Aditya', action: 'call back', when: 'Friday'),
      ],
      openLoops: const ['Need a mic sample'],
      noise: '',
    );
    final pack = recap.mem0Pack('Thursday, August 20, 2026');
    expect(pack, contains('day_key=2026-08-20'));
    expect(pack, contains('Aditya'));
    expect(pack, contains('call back'));
    expect(pack, contains('Need a mic sample'));
    expect(pack.indexOf('Decisions:'), lessThan(pack.indexOf('Arc:')));
  });

  test('parses nested Mem0 search hits', () {
    final hits = parseMem0Hits({
      'results': [
        {
          'id': '1',
          'data': {'memory': 'Ship the journal UI'},
          'metadata': {'day_key': '2026-08-20'},
        },
      ],
    });
    expect(hits, hasLength(1));
    expect(hits.first.memory, 'Ship the journal UI');
    expect(hits.first.dayKey, '2026-08-20');
  });

  test('local recap wins over stale Mem0 hit for the same day', () {
    final recap = DayRecap(
      dayKey: '2026-08-20',
      headline: 'Fresh recap',
      arc: 'New evening work.',
      people: const ['Aditya'],
      languages: const ['en'],
      chapters: const [],
      decisions: const ['Newest decision'],
      followUps: const [],
      openLoops: const [],
      noise: '',
      updatedAt: DateTime.utc(2026, 8, 20, 13),
    );
    final merged = mergeMemoryHits(
      recaps: [recap],
      remote: [
        Mem0Hit(
          id: 'old',
          memory: 'Stale morning recap',
          dayKey: '2026-08-20',
        ),
        Mem0Hit(
          id: 'other',
          memory: 'Tuesday note',
          dayKey: '2026-08-18',
        ),
      ],
    );
    expect(merged.first.memory, contains('Fresh recap'));
    expect(merged.where((h) => h.dayKey == '2026-08-20'), hasLength(1));
    expect(merged.any((h) => h.memory == 'Tuesday note'), isTrue);
  });

  test('day_key from metadata or recap text', () {
    expect(
      dayKeyFromHit({
        'memory': 'Aditya has a follow-up',
        'metadata': {'day_key': '2026-08-20'},
      }),
      '2026-08-20',
    );
    expect(
      dayKeyFromHit({
        'memory': 'OpenPendant day recap (day_key=2026-08-19). Headline: x',
      }),
      '2026-08-19',
    );
    expect(parseDayKey('2026-08-20'), DateTime(2026, 8, 20));
    expect(parseDayKey('nope'), isNull);
  });
}
