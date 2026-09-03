import '../db/models.dart';

const refineModel = 'gpt-4o-mini';

final _junk = RegExp(
  r'thanks for watching|subscribe to|\[music\]|\[applause\]|'
  r'please subscribe|like and subscribe',
  caseSensitive: false,
);

bool hasPersoArabic(String s) {
  for (final r in s.runes) {
    if ((r >= 0x0600 && r <= 0x06FF) ||
        (r >= 0x0750 && r <= 0x077F) ||
        (r >= 0x08A0 && r <= 0x08FF) ||
        (r >= 0xFB50 && r <= 0xFDFF) ||
        (r >= 0xFE70 && r <= 0xFEFF)) {
      return true;
    }
  }
  return false;
}

bool hasRepeatLoop(String s) {
  final toks =
      s.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  if (toks.length < 4) {
    return false;
  }
  var run = 1;
  for (var i = 1; i < toks.length; i++) {
    if (toks[i] == toks[i - 1]) {
      run++;
      if (run >= 4) {
        return true;
      }
    } else {
      run = 1;
    }
  }
  return false;
}

bool looksLikeJunkPhrase(String s) {
  final t = s.trim();
  if (t.isEmpty) {
    return true;
  }
  if (_junk.hasMatch(t)) {
    return true;
  }
  final letters = t.runes.where(_isLetter).length;
  if (letters == 0) {
    return true;
  }
  final exact = t.toLowerCase().replaceAll(RegExp(r'[.!,?]'), '');
  return const {'you', 'the', 'a', 'um', 'uh', 'hmm'}.contains(exact);
}

bool _isLetter(int r) {
  return (r >= 0x41 && r <= 0x5A) ||
      (r >= 0x61 && r <= 0x7A) ||
      (r >= 0x00C0 && r <= 0x024F) ||
      (r >= 0x0900 && r <= 0x097F) ||
      (r >= 0x0400 && r <= 0x04FF);
}

bool segmentNeedsRefine(TranscriptSegment s) {
  final t = s.rawText.trim().isEmpty ? s.text : s.rawText;
  if (t.trim().isEmpty) {
    return false;
  }
  return hasPersoArabic(t) || hasRepeatLoop(t) || looksLikeJunkPhrase(t);
}

bool clipNeedsRefine(List<TranscriptSegment> segments) {
  return segments.any(segmentNeedsRefine);
}

/// Map model JSON onto original turns. Empty/missing text drops the display line.
List<TranscriptSegment> applyRefineTurns({
  required List<TranscriptSegment> original,
  required List<Map<String, dynamic>> turns,
}) {
  final byIndex = <int, Map<String, dynamic>>{};
  for (final t in turns) {
    final i = (t['i'] as num?)?.toInt();
    if (i == null) {
      continue;
    }
    byIndex[i] = t;
  }
  final out = <TranscriptSegment>[];
  for (var i = 0; i < original.length; i++) {
    final orig = original[i];
    final raw = orig.rawText.trim().isEmpty ? orig.text : orig.rawText;
    final hit = byIndex[i];
    if (hit == null) {
      out.add(orig.copyWith(rawText: raw));
      continue;
    }
    final cleaned = (hit['text'] as String? ?? '').trim();
    final speaker = (hit['speaker'] as String?)?.trim();
    out.add(
      orig.copyWith(
        text: cleaned,
        rawText: raw,
        speaker:
            (speaker != null && speaker.isNotEmpty) ? speaker : orig.speaker,
      ),
    );
  }
  return out;
}
