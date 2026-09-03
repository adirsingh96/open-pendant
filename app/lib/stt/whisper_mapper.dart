import 'dart:math' as math;

import '../audio/speech_vad.dart';
import '../db/models.dart';

const whisperTurboModelId = 'whisper:large-v3-turbo';
const qwen3AsrModelId = 'qwen3-asr:0.6b';

final _specialTok = RegExp(r'^<\|[^>]+\|>$');

/// Whisper auto-detect often labels Hindi as Urdu (Arabic script).
bool textLooksLikeUrdu(String text) {
  var arabic = 0;
  var devanagari = 0;
  for (final u in text.runes) {
    if (u >= 0x0600 && u <= 0x06FF) {
      arabic++;
    } else if (u >= 0x0900 && u <= 0x097F) {
      devanagari++;
    }
  }
  return arabic >= 4 && arabic > devanagari;
}

bool whisperLangIsUrdu(String? lang) {
  var s = (lang ?? '').toLowerCase().trim();
  s = s.replaceAll(RegExp(r'[^a-z]'), '');
  return s == 'ur' || s == 'urd';
}

bool whisperLangIsHindi(String? lang) {
  var s = (lang ?? '').toLowerCase().trim();
  s = s.replaceAll(RegExp(r'[^a-z]'), '');
  return s == 'hi' || s == 'hin';
}

bool textLooksLikeDevanagari(String text) {
  var n = 0;
  for (final u in text.runes) {
    if (u >= 0x0900 && u <= 0x097F) {
      n++;
      if (n >= 4) {
        return true;
      }
    }
  }
  return false;
}

bool clipLooksLikeHindi({required String? lang, required String text}) {
  return whisperLangIsHindi(lang) ||
      whisperLangIsUrdu(lang) ||
      textLooksLikeUrdu(text) ||
      textLooksLikeDevanagari(text);
}

({int latin, int devanagari, int arabic}) countScripts(String text) {
  var latin = 0;
  var devanagari = 0;
  var arabic = 0;
  for (final u in text.runes) {
    if ((u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A)) {
      latin++;
    } else if (u >= 0x0900 && u <= 0x097F) {
      devanagari++;
    } else if (u >= 0x0600 && u <= 0x06FF) {
      arabic++;
    }
  }
  return (latin: latin, devanagari: devanagari, arabic: arabic);
}

/// Dominant writing system. Qwen3 often collapses mixed speech onto one.
String guessScript(String text) {
  final c = countScripts(stripQwenAsrPrefix(text));
  final lat = c.latin >= 4;
  final hi = c.devanagari >= 4;
  if (lat && hi) {
    return 'mixed';
  }
  if (lat) {
    return 'latin';
  }
  if (hi) {
    return 'indic';
  }
  return 'empty';
}

bool probesSuggestCodeSwitch(Iterable<String> probeTexts) {
  final g = [
    for (final t in probeTexts) guessScript(t),
  ].where((s) => s != 'empty').toList();
  if (g.contains('mixed')) {
    return true;
  }
  return g.toSet().length >= 2;
}

List<({double start, double end})> codeSwitchProbes(double durationS) {
  const w = 2.0;
  if (durationS < 4.0) {
    return [];
  }
  final last = math.max(0.0, durationS - w);
  final mid = math.max(0.0, (durationS - w) / 2);
  return [
    (start: 0, end: math.min(w, durationS)),
    (start: mid, end: math.min(mid + w, durationS)),
    (start: last, end: durationS),
  ];
}

List<({double start, double end})> codeSwitchWindows(double durationS) {
  const win = 1.05;
  const hop = 0.85;
  if (durationS <= 0) {
    return [];
  }
  if (durationS <= 1.4) {
    return [(start: 0, end: durationS)];
  }
  final out = <({double start, double end})>[];
  var t = 0.0;
  while (t + win < durationS - 0.35) {
    out.add((start: t, end: t + win));
    t += hop;
  }
  final lastStart = t <= durationS - 0.55 ? t : math.max(0.0, durationS - win);
  if (out.isEmpty) {
    out.add((start: 0, end: durationS));
  } else if ((out.last.end - durationS).abs() < 0.15) {
    out[out.length - 1] = (start: out.last.start, end: durationS);
  } else {
    out.add((start: lastStart, end: durationS));
  }
  return out;
}

const _enLex = {
  'the',
  'is',
  'are',
  'was',
  'were',
  'and',
  'you',
  'that',
  'this',
  'have',
  'for',
  'not',
  'with',
  'what',
  'can',
  'will',
  'just',
  'like',
  'know',
  'yeah',
  'okay',
  'ok',
  'we',
  'to',
  'of',
  'in',
  'it',
  'on',
  'be',
  'my',
  'me',
  'meeting',
  'call',
  'email',
  'project',
  'today',
  'tomorrow',
  'please',
  'because',
  'actually',
  'morning',
  'evening',
  'deadline',
  'update',
  'let',
  'us',
  'start',
};

const _hiDev = [
  'क्या',
  'मेरा',
  'मेरी',
  'मेरे',
  'नहीं',
  'नही',
  'चाहिए',
  'लेकिन',
  'बहुत',
  'कैसे',
  'हैं',
  'हम',
  'आप',
  'मैं',
];

int englishMarkerHits(String text) {
  final words =
      text.toLowerCase().split(RegExp(r'[^a-z]+')).where((w) => w.length >= 2);
  var n = 0;
  for (final w in words) {
    if (_enLex.contains(w)) {
      n++;
    }
  }
  return n;
}

int hindiMarkerHits(String text) {
  var n = 0;
  for (final m in _hiDev) {
    if (text.contains(m)) {
      n++;
    }
  }
  if (text.contains('है')) {
    n++;
  }
  return n;
}

bool shouldTryBilingual(String hindi, String english) {
  final h = stripQwenAsrPrefix(hindi);
  final e = stripQwenAsrPrefix(english);
  return hindiMarkerHits(h) >= 1 && englishMarkerHits(e) >= 1;
}

/// Pick Hindi-forced vs English-forced vs bilingual for one short window.
String pickCodeSwitchWindow({
  required String hindi,
  required String english,
  String? bilingual,
}) {
  final h = stripQwenAsrPrefix(hindi);
  final e = stripQwenAsrPrefix(english);
  final b = bilingual == null ? '' : stripQwenAsrPrefix(bilingual);
  if (b.isNotEmpty &&
      (guessScript(b) == 'mixed' ||
          (hindiMarkerHits(b) >= 1 && englishMarkerHits(b) >= 1))) {
    return b;
  }
  final hm = hindiMarkerHits(h) + (countScripts(h).devanagari >= 4 ? 1 : 0);
  final em = englishMarkerHits(e);
  if (hm >= 2 && em < 2 && h.isNotEmpty) {
    return h;
  }
  if (em >= 2 && hm < 2 && e.isNotEmpty) {
    return e;
  }
  if (hm >= 1 && em >= 1 && h.isNotEmpty && e.isNotEmpty) {
    if (b.isNotEmpty && guessScript(b) != 'empty') {
      return b;
    }
    return h;
  }
  if (countScripts(h).devanagari >= 4 && em < 2 && h.isNotEmpty) {
    return h;
  }
  if (e.trim().isNotEmpty &&
      (e.trim().length >= h.trim().length || countScripts(e).latin >= 4)) {
    return e;
  }
  return h.isNotEmpty ? h : e;
}

String stripQwenAsrPrefix(String text) {
  final i = text.indexOf('<asr_text>');
  if (i >= 0) {
    return text.substring(i + '<asr_text>'.length).trim();
  }
  return text.trim();
}

/// Whisper turbo often "transcribes" Hindi as English (lang=en). Prefer
/// IndicConformer when it actually wrote Devanagari.
bool preferIndicTranscript({
  required String? whisperLang,
  required String whisperText,
  required String indicText,
}) {
  final indic = countScripts(indicText);
  if (indic.devanagari < 6) {
    return false;
  }
  if (clipLooksLikeHindi(lang: whisperLang, text: whisperText)) {
    return true;
  }
  return indic.devanagari >= indic.latin;
}

/// Map sherpa-onnx Whisper text/tokens/timestamps onto [TranscriptResult].
TranscriptResult whisperToTranscript({
  required String text,
  required List<String> tokens,
  required List<double> timestamps,
  required DateTime startedAt,
  SpeechExtract? speech,
  String model = whisperTurboModelId,
  double offsetS = 0,
  double? spanS,
}) {
  text = stripQwenAsrPrefix(text);
  final durationS = spanS ?? speech?.speechDurationS ?? 0;
  final segs = <TranscriptSegment>[];
  if (tokens.isNotEmpty && timestamps.length == tokens.length) {
    var buf = StringBuffer();
    var segStart = -1.0;
    var lastT = 0.0;
    void flush(double end) {
      final t = _clean(buf.toString());
      buf.clear();
      if (t.isEmpty || segStart < 0) {
        return;
      }
      segs.add(
        _seg(
          start: offsetS + segStart,
          end: offsetS + (end < segStart ? segStart + 0.2 : end),
          text: t,
          startedAt: startedAt,
          speech: speech,
        ),
      );
      segStart = -1;
    }

    for (var i = 0; i < tokens.length; i++) {
      final raw = tokens[i];
      final t = timestamps[i];
      if (_specialTok.hasMatch(raw.trim())) {
        continue;
      }
      final piece = _tokenText(raw);
      if (piece.trim().isEmpty && piece.isEmpty) {
        continue;
      }
      if (segStart < 0) {
        segStart = t;
      } else if (t - lastT > 0.55 && buf.toString().trim().isNotEmpty) {
        flush(lastT + 0.15);
        segStart = t;
      }
      buf.write(piece);
      lastT = t;
    }
    flush(durationS > lastT ? durationS : lastT + 0.25);
  }
  if (segs.isEmpty) {
    final t = _clean(text);
    if (t.isNotEmpty) {
      segs.add(
        _seg(
          start: offsetS,
          end: offsetS + (durationS > 0 ? durationS : 0.5),
          text: t,
          startedAt: startedAt,
          speech: speech,
        ),
      );
    }
  }
  final joined = segs.map((s) => s.text).where((s) => s.isNotEmpty).join(' ');
  return TranscriptResult(
    text: joined.isNotEmpty ? joined : _clean(text),
    model: model,
    segments: segs,
    costUsd: 0,
  );
}

String _tokenText(String t) {
  return t.replaceAll('▁', ' ').replaceAll('Ġ', ' ');
}

String _clean(String t) {
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}

TranscriptSegment _seg({
  required double start,
  required double end,
  required String text,
  required DateTime startedAt,
  SpeechExtract? speech,
}) {
  final orig = speech?.originalSeconds(start) ?? start;
  return TranscriptSegment(
    startS: orig,
    endS: speech?.originalSeconds(end) ?? end,
    spokenAt: startedAt.add(Duration(milliseconds: (orig * 1000).round())),
    text: text,
    rawText: text,
  );
}
