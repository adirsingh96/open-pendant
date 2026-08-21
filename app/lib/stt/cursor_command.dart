import '../db/models.dart';

/// Journal stays in SQLite. Only text that starts with a Cursor wake
/// (or the one-shot Command chip) is offered to Composer.
String? cursorPromptFromText(String text, {required bool forceNext}) {
  var t = text.trim();
  if (t.isEmpty) {
    return null;
  }
  t = t.replaceAll(RegExp(r'\s+'), ' ');
  if (forceNext) {
    return t;
  }
  final start = RegExp(
    r'^(?:(?:hi|hey)\s+)?cursor\b[,:\s-]*(.*)$',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(t);
  if (start != null) {
    final rest = (start.group(1) ?? '').trim();
    return rest.isEmpty ? null : rest;
  }
  final mid = RegExp(
    r'(?:(?:hi|hey)\s+)?cursor\s*[,:]\s*(.+)$',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(t);
  if (mid == null) {
    return null;
  }
  final rest = (mid.group(1) ?? '').trim();
  return rest.isEmpty ? null : rest;
}

/// Prefer a wake phrase on a single turn, then the joined wearer text.
String? cursorPromptFromClip({
  required List<TranscriptSegment> segs,
  required String fallback,
  required bool forceNext,
  String? wearer,
}) {
  if (forceNext) {
    final spoken = cursorSpokenText(
      segs: segs,
      fallback: fallback,
      wearer: wearer,
    );
    return spoken.isEmpty ? null : spoken;
  }
  for (final s in segs.reversed) {
    final p = cursorPromptFromText(s.text, forceNext: false);
    if (p != null) {
      return p;
    }
  }
  return cursorPromptFromText(
    cursorSpokenText(segs: segs, fallback: fallback, wearer: wearer),
    forceNext: false,
  );
}

String cursorSpokenText({
  required List<TranscriptSegment> segs,
  required String fallback,
  String? wearer,
}) {
  final name = wearer?.trim() ?? '';
  if (name.isNotEmpty) {
    final w = name.toLowerCase();
    final mine = segs
        .where((s) => (s.speaker ?? '').trim().toLowerCase() == w)
        .map((s) => s.text.trim())
        .where((t) => t.isNotEmpty)
        .join(' ');
    if (mine.isNotEmpty) {
      return mine;
    }
  }
  return fallback.trim();
}
