import '../db/models.dart';

/// Informal Indian romanization (not academic IAST).
/// मेरा नाम क्या है → mera naam kya hai
String romanizeDevanagari(String input) {
  if (input.isEmpty) {
    return input;
  }
  final out = StringBuffer();
  final codes = input.runes.toList();
  var i = 0;
  while (i < codes.length) {
    final u = codes[i];
    if (u < 0x0900 || u > 0x097F) {
      out.writeCharCode(u);
      i++;
      continue;
    }
    if (_independentVowels.containsKey(u)) {
      out.write(_independentVowels[u]);
      i++;
      continue;
    }
    if (u == 0x0901 || u == 0x0902) {
      out.write('n');
      i++;
      continue;
    }
    if (u == 0x0903) {
      out.write('h');
      i++;
      continue;
    }
    if (u == 0x0964 || u == 0x0965) {
      out.write('.');
      i++;
      continue;
    }
    if (u >= 0x0966 && u <= 0x096F) {
      out.write('${u - 0x0966}');
      i++;
      continue;
    }
    var cons = _consonants[u];
    var j = i + 1;
    if (j < codes.length && codes[j] == 0x093C) {
      cons = _nukta[u] ?? cons;
      j++;
    }
    if (cons == null) {
      i++;
      continue;
    }
    if (j < codes.length && codes[j] == 0x094D) {
      out.write(cons);
      i = j + 1;
      continue;
    }
    if (j < codes.length && _matras.containsKey(codes[j])) {
      out.write(cons);
      out.write(_matras[codes[j]]);
      i = j + 1;
      continue;
    }
    out.write(cons);
    out.write('a');
    i = j;
  }
  return _dropWordFinalSchwa(out.toString());
}

String _dropWordFinalSchwa(String s) {
  return s.split(RegExp(r'\s+')).map((p) {
    if (p.endsWith('a') && p.length >= 2) {
      final stem = p.substring(0, p.length - 1);
      if (!_vowelEnd.hasMatch(stem)) {
        return stem;
      }
    }
    return p;
  }).join(' ');
}

TranscriptResult romanizeTranscript(TranscriptResult r) {
  final hasHi = textHasDevanagari(r.text) ||
      r.segments.any((s) => textHasDevanagari(s.text));
  if (!hasHi) {
    return r;
  }
  return TranscriptResult(
    text: romanizeDevanagari(r.text),
    model: r.model,
    segments: [
      for (final s in r.segments)
        s.copyWith(
          text: romanizeDevanagari(s.text),
          rawText: romanizeDevanagari(
            s.rawText.trim().isEmpty ? s.text : s.rawText,
          ),
        ),
    ],
    inputTokens: r.inputTokens,
    outputTokens: r.outputTokens,
    costUsd: r.costUsd,
  );
}

bool textHasDevanagari(String text) {
  for (final u in text.runes) {
    if (u >= 0x0900 && u <= 0x097F) {
      return true;
    }
  }
  return false;
}

final _vowelEnd = RegExp(r'(aa|ee|ii|oo|uu|ai|au|[aeiou])$');

const _independentVowels = <int, String>{
  0x0905: 'a',
  0x0906: 'aa',
  0x0907: 'i',
  0x0908: 'ee',
  0x0909: 'u',
  0x090A: 'oo',
  0x090B: 'ri',
  0x090F: 'e',
  0x0910: 'ai',
  0x0913: 'o',
  0x0914: 'au',
};

const _matras = <int, String>{
  0x093E: 'aa',
  0x093F: 'i',
  0x0940: 'ee',
  0x0941: 'u',
  0x0942: 'oo',
  0x0943: 'ri',
  0x0947: 'e',
  0x0948: 'ai',
  0x094B: 'o',
  0x094C: 'au',
};

const _consonants = <int, String>{
  0x0915: 'k',
  0x0916: 'kh',
  0x0917: 'g',
  0x0918: 'gh',
  0x0919: 'ng',
  0x091A: 'ch',
  0x091B: 'chh',
  0x091C: 'j',
  0x091D: 'jh',
  0x091E: 'ny',
  0x091F: 't',
  0x0920: 'th',
  0x0921: 'd',
  0x0922: 'dh',
  0x0923: 'n',
  0x0924: 't',
  0x0925: 'th',
  0x0926: 'd',
  0x0927: 'dh',
  0x0928: 'n',
  0x092A: 'p',
  0x092B: 'ph',
  0x092C: 'b',
  0x092D: 'bh',
  0x092E: 'm',
  0x092F: 'y',
  0x0930: 'r',
  0x0932: 'l',
  0x0935: 'v',
  0x0936: 'sh',
  0x0937: 'sh',
  0x0938: 's',
  0x0939: 'h',
};

const _nukta = <int, String>{
  0x0915: 'q',
  0x0916: 'kh',
  0x0917: 'g',
  0x091C: 'z',
  0x0921: 'd',
  0x0922: 'rh',
  0x092B: 'f',
};
