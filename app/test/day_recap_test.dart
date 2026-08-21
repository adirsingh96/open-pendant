import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/db/day_recap.dart';
import 'package:openpendant/stt/day_clean_prompt.dart';

void main() {
  test('day recap parses nested summary JSON', () {
    final recap = DayRecap.fromJson(
      dayKey: '2026-08-19',
      json: {
        'turns': [
          {'i': 0, 'text': 'ok'},
        ],
        'summary': {
          'headline': 'Testing the pendant',
          'people': ['Aditya', 'B'],
          'languages': ['Hindi', 'English'],
          'arc': 'A short device test.',
          'chapters': [
            {'when': 'Afternoon', 'title': 'Kitchen', 'what': 'Voice tags.'},
          ],
          'decisions': [],
          'follow_ups': [
            {'owner': 'Aditya', 'action': 'Enroll Hindi sample', 'when': ''},
          ],
          'open_loops': ['Urdu vs Hindi script'],
          'noise': '',
        },
      },
    );
    expect(recap.headline, 'Testing the pendant');
    expect(recap.people, ['Aditya', 'B']);
    expect(recap.chapters, hasLength(1));
    expect(recap.followUps.single.action, 'Enroll Hindi sample');
    expect(recap.openLoops, hasLength(1));
  });

  test('day clean prompt asks for chapters and follow_ups', () {
    final u = DayCleanPrompt.user(
      dateLabel: 'Wednesday, August 19, 2026',
      rangeLabel: 'all day',
      turns: [
        {'i': 0, 'at': 't', 'speaker': 'A', 'text': 'hello'},
      ],
    );
    expect(u, contains('"chapters"'));
    expect(u, contains('"follow_ups"'));
    expect(DayCleanPrompt.system, contains('Never Urdu'));
    expect(DayCleanPrompt.system, contains('Do not translate'));
  });

  test('clipRecapToSpeech drops evening after last 3pm turn', () {
    final recap = DayRecap(
      dayKey: '2026-08-21',
      headline: 'h',
      arc: 'a',
      people: const [],
      languages: const [],
      chapters: [
        DayChapter(
          when: '00:00–12:00',
          title: 'Morning',
          what: 'Invented morning.',
        ),
        DayChapter(
          when: '12:00–18:00',
          title: 'Afternoon',
          what: 'Real afternoon talk.',
        ),
        DayChapter(
          when: '18:00–23:59',
          title: 'Evening Wrap-Up',
          what: 'The day concluded with testing.',
        ),
      ],
      decisions: const [],
      followUps: const [],
      openLoops: const [],
      noise: '',
    );
    final clipped = clipRecapToSpeech(
      recap: recap,
      firstSpoken: DateTime(2026, 8, 21, 15, 2),
      lastSpoken: DateTime(2026, 8, 21, 15, 6),
    );
    expect(clipped.chapters, hasLength(1));
    expect(clipped.chapters.single.title, 'Afternoon');
  });
}
