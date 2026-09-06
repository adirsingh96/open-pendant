import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/notes/note_kind.dart';

void main() {
  test('plain ideas are thoughts', () {
    expect(classifyNoteKind('what if the pendant had a light sensor'),
        NoteKind.thought);
    expect(classifyNoteKind('idea for the shell material'), NoteKind.thought);
  });

  test('remind me and clocks become to-dos', () {
    expect(
      classifyNoteKind(
        'remind me to call mom at 10 AM',
        now: DateTime(2026, 9, 4, 8),
      ),
      NoteKind.todo,
    );
    expect(
      classifyNoteKind('buy milk at 3 pm', now: DateTime(2026, 9, 4, 8)),
      NoteKind.todo,
    );
  });

  test('explicit action prefixes become to-dos', () {
    expect(classifyNoteKind('todo ship the UF2'), NoteKind.todo);
    expect(classifyNoteKind('follow up with Aditya'), NoteKind.todo);
  });

  test('recap ids are to-dos', () {
    expect(
      classifyNoteKind('Call Sam', id: 'task:day:abc'),
      NoteKind.todo,
    );
    expect(
      classifyNoteKind('Choose launch', id: 'loop:day:abc'),
      NoteKind.todo,
    );
  });

  test('marked moment stays a thought', () {
    expect(classifyNoteKind('Marked moment'), NoteKind.thought);
  });
}
