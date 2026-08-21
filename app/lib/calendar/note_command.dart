import '../db/models.dart';
import '../stt/cursor_command.dart';

final _start = RegExp(
  r'^(?:(?:hey|hi|okay|ok)\s+)?(?:please\s+)?(?:take|make|add)\s+(?:down\s+)?(?:a\s+)?note(?:\s+of|\s+about)?\b[,:\s-]*(.*)$',
  caseSensitive: false,
  dotAll: true,
);

final _mid = RegExp(
  r'(?:(?:hey|hi|okay|ok)\s+)?(?:please\s+)?(?:take|make|add)\s+(?:down\s+)?(?:a\s+)?note(?:\s+of|\s+about)?\s*[,:]\s*(.+)$',
  caseSensitive: false,
  dotAll: true,
);

/// Spoken text after “take a note …”. Journal is unchanged.
String? calendarNoteFromText(String text) {
  var t = text.trim();
  if (t.isEmpty) {
    return null;
  }
  t = t.replaceAll(RegExp(r'\s+'), ' ');
  final start = _start.firstMatch(t);
  if (start != null) {
    final rest = (start.group(1) ?? '').trim();
    return rest.isEmpty ? null : rest;
  }
  final mid = _mid.firstMatch(t);
  if (mid == null) {
    return null;
  }
  final rest = (mid.group(1) ?? '').trim();
  return rest.isEmpty ? null : rest;
}

String? calendarNoteFromClip({
  required List<TranscriptSegment> segs,
  required String fallback,
  String? wearer,
}) {
  for (final s in segs.reversed) {
    final n = calendarNoteFromText(s.text);
    if (n != null) {
      return n;
    }
  }
  return calendarNoteFromText(
    cursorSpokenText(segs: segs, fallback: fallback, wearer: wearer),
  );
}

String calendarEventTitle(String note) {
  final t = note.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (t.length <= 80) {
    return t;
  }
  return '${t.substring(0, 77)}…';
}
