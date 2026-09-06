import 'reminder_parse.dart';

/// How a spoken note is shown and reminded.
abstract final class NoteKind {
  static const thought = 'thought';
  static const todo = 'todo';

  static bool isTodo(String? kind) => kind == todo;
  static bool isThought(String? kind) => !isTodo(kind);
}

final _actionPrefix = RegExp(
  r'^(?:(?:hey|hi|okay|ok|please)\s+)*'
  r'(?:'
  r'remind\s+me\b|'
  r'to[\-\s]?do\b|'
  r'todo\b|'
  r'follow[\-\s]?up\b'
  r')',
  caseSensitive: false,
);

/// Reminder-shaped or explicit action speech → to-do; otherwise thought.
String classifyNoteKind(
  String text, {
  DateTime? now,
  String? id,
  DateTime? dueAt,
}) {
  final noteId = (id ?? '').trim();
  if (noteId.startsWith('task:') || noteId.startsWith('loop:')) {
    return NoteKind.todo;
  }
  if (dueAt != null) {
    return NoteKind.todo;
  }
  final raw = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (raw.toLowerCase() == 'marked moment') {
    return NoteKind.thought;
  }
  if (raw.isEmpty) {
    return NoteKind.thought;
  }
  if (_actionPrefix.hasMatch(raw)) {
    return NoteKind.todo;
  }
  final parsed = parseNoteReminder(raw, now: now);
  if (parsed.dueAt != null) {
    return NoteKind.todo;
  }
  return NoteKind.thought;
}
