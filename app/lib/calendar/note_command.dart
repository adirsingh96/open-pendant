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

/// Journal leftover after removing a “take a note” command, or empty to drop.
String leftoverAfterNoteCommand(String text) {
  var t = text.trim();
  if (t.isEmpty) {
    return '';
  }
  t = t.replaceAll(RegExp(r'\s+'), ' ');
  if (_start.hasMatch(t)) {
    return '';
  }
  final mid = _mid.firstMatch(t);
  if (mid == null) {
    return t;
  }
  return t.substring(0, mid.start).trim();
}

List<TranscriptSegment> segsWithoutNoteCommands(List<TranscriptSegment> segs) {
  final out = <TranscriptSegment>[];
  for (final s in segs) {
    final left = leftoverAfterNoteCommand(s.text);
    if (left.isEmpty) {
      continue;
    }
    out.add(s.copyWith(text: left, rawText: left));
  }
  return out;
}

String joinSegmentText(List<TranscriptSegment> segs) {
  return segs
      .map((s) => s.labeledText)
      .where((t) => t.trim().isNotEmpty)
      .join(' ')
      .trim();
}

String joinUnlabeledSegmentText(List<TranscriptSegment> segs) {
  return segs
      .map((s) => s.text.trim())
      .where((t) => t.isNotEmpty)
      .join(' ')
      .trim();
}

/// Drop diarization prefixes like "Aditya: " from a saved note.
String noteTextWithoutSpeakers(String text) {
  var t = text.trim();
  if (t.isEmpty) {
    return t;
  }
  final prefix = RegExp(
    r'^(?:Speaker(?:\s+\d+)?|[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?):\s+',
  );
  while (true) {
    final m = prefix.firstMatch(t);
    if (m == null) {
      break;
    }
    final rest = t.substring(m.end).trim();
    if (rest.isEmpty) {
      break;
    }
    t = rest;
  }
  return t;
}

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
