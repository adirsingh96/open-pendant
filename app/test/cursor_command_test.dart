import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/db/models.dart';
import 'package:openpendant/stt/cursor_command.dart';

void main() {
  test('wake phrase strips Cursor prefix', () {
    expect(
      cursorPromptFromText('Cursor, add a status hint', forceNext: false),
      'add a status hint',
    );
    expect(
      cursorPromptFromText('hey cursor fix the recap', forceNext: false),
      'fix the recap',
    );
    expect(
      cursorPromptFromText('Hi cursor, which model are you using currently?', forceNext: false),
      'which model are you using currently?',
    );
    expect(
      cursorPromptFromText(
        'Now this is a test. Cursor, which model are you using?',
        forceNext: false,
      ),
      'which model are you using?',
    );
    expect(cursorPromptFromText('hey cursor', forceNext: false), isNull);
    expect(cursorPromptFromText('we should ship tomorrow', forceNext: false), isNull);
  });

  test('forceNext uses the whole clip', () {
    expect(
      cursorPromptFromText('add a status hint', forceNext: true),
      'add a status hint',
    );
  });

  test('cursorSpokenText prefers the wearer', () {
    final segs = [
      TranscriptSegment(
        startS: 0,
        endS: 1,
        spokenAt: DateTime.utc(2026, 8, 21),
        text: 'noise',
        speaker: 'B',
      ),
      TranscriptSegment(
        startS: 1,
        endS: 2,
        spokenAt: DateTime.utc(2026, 8, 21, 0, 0, 1),
        text: 'Cursor ship it',
        speaker: 'Aditya',
      ),
    ];
    expect(
      cursorSpokenText(segs: segs, fallback: 'all', wearer: 'Aditya'),
      'Cursor ship it',
    );
  });
}
