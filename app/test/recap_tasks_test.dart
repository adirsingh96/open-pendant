import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/db/day_recap.dart';
import 'package:openpendant/notes/recap_tasks.dart';

void main() {
  test('recap task ids are stable and scoped', () {
    final a = recapTaskId(scope: 'day-a', kind: 'task', text: 'Call Sam');
    final b = recapTaskId(scope: 'day-a', kind: 'task', text: ' call sam ');
    final other = recapTaskId(scope: 'day-b', kind: 'task', text: 'Call Sam');

    expect(a, b);
    expect(a, isNot(other));
  });

  test('turns follow-ups and open loops into notes', () {
    final recap = DayRecap(
      dayKey: '2026-09-04',
      headline: 'A useful day',
      arc: '',
      people: const [],
      languages: const [],
      chapters: const [],
      decisions: const [],
      followUps: [
        DayFollowUp(owner: 'Aditi', action: 'Call Sam', when: 'tomorrow'),
      ],
      openLoops: const ['Choose the launch date'],
      noise: '',
    );

    final notes = notesFromRecap(recap: recap, scope: recap.dayKey);

    expect(notes, hasLength(2));
    expect(notes[0].id, startsWith('task:2026-09-04:'));
    expect(notes[1].id, startsWith('loop:2026-09-04:'));
  });
}
