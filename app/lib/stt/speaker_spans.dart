import 'dart:math' as math;

import '../db/models.dart';

class SpeakerSpan {
  SpeakerSpan({
    required this.startS,
    required this.endS,
    required this.name,
  });

  final double startS;
  final double endS;
  final String name;
}

String? speakerForInterval({
  required double startS,
  required double endS,
  required List<SpeakerSpan> spans,
}) {
  if (spans.isEmpty) {
    return null;
  }
  final mid = (startS + endS) / 2;
  return speakerAtTime(mid, spans) ?? _nearestSpeaker(mid, spans, maxDist: 0.8);
}

String? speakerAtTime(double t, List<SpeakerSpan> spans) {
  for (final s in spans) {
    if (t >= s.startS && t <= s.endS) {
      return s.name;
    }
  }
  return null;
}

String? _nearestSpeaker(double t, List<SpeakerSpan> spans,
    {required double maxDist}) {
  SpeakerSpan? near;
  var dist = 1e9;
  for (final s in spans) {
    final sm = (s.startS + s.endS) / 2;
    final d = (t - sm).abs();
    if (d < dist) {
      dist = d;
      near = s;
    }
  }
  if (near != null && dist <= maxDist) {
    return near.name;
  }
  return null;
}

double _overlap(double a0, double a1, double b0, double b1) {
  return math.max(0.0, math.min(a1, b1) - math.max(a0, b0));
}

/// Glue Saaras word timestamps into phrases so one speaker decision covers
/// a whole turn instead of flipping every syllable.
List<TranscriptSegment> mergeCloseSegments(
  List<TranscriptSegment> segs, {
  double maxGapS = 0.45,
}) {
  if (segs.length < 2) {
    return segs;
  }
  final out = <TranscriptSegment>[];
  var cur = segs.first;
  var buf = cur.text.trim();
  for (var i = 1; i < segs.length; i++) {
    final n = segs[i];
    final sameSpeaker = (cur.speaker ?? '') == (n.speaker ?? '');
    if (sameSpeaker && n.startS - cur.endS <= maxGapS) {
      buf = '$buf ${n.text.trim()}'.trim();
      cur = TranscriptSegment(
        id: cur.id,
        clipId: cur.clipId,
        startS: cur.startS,
        endS: n.endS,
        spokenAt: cur.spokenAt,
        text: buf,
        rawText: buf,
        speaker: cur.speaker,
      );
    } else {
      out.add(cur.copyWith(text: buf, rawText: buf));
      cur = n;
      buf = n.text.trim();
    }
  }
  out.add(cur.copyWith(text: buf, rawText: buf));
  return out;
}

/// Keep [words] text; stamp or split by [diarize] speaker turns.
/// A single long Saaras phrase must be cut at OpenAI speaker changes,
/// otherwise the longer talker wins the whole clip.
TranscriptResult overlayDiarization({
  required TranscriptResult words,
  required TranscriptResult diarize,
  String? model,
}) {
  final spans = <SpeakerSpan>[
    for (final s in diarize.segments)
      if ((s.speaker ?? '').trim().isNotEmpty)
        SpeakerSpan(
          startS: s.startS,
          endS: s.endS,
          name: s.speaker!.trim(),
        ),
  ];
  var segs = <TranscriptSegment>[
    for (final s in words.segments) ...sliceBySpeakerTurns(s, spans),
  ];
  segs = mergeCloseSegments(segs);
  final labeled =
      segs.map((s) => s.labeledText).where((t) => t.isNotEmpty).join(' ');
  return TranscriptResult(
    text: labeled.isNotEmpty ? labeled : words.text,
    model: model ?? '${words.model}+${diarize.model}',
    segments: segs.isNotEmpty ? segs : words.segments,
    inputTokens: words.inputTokens + diarize.inputTokens,
    outputTokens: words.outputTokens + diarize.outputTokens,
    costUsd: words.costUsd + diarize.costUsd,
  );
}

List<TranscriptSegment> sliceBySpeakerTurns(
  TranscriptSegment phrase,
  List<SpeakerSpan> spans,
) {
  if (spans.isEmpty) {
    return [phrase];
  }
  final hits = spans.where((p) {
    return _overlap(phrase.startS, phrase.endS, p.startS, p.endS) > 0.08;
  }).toList()
    ..sort((a, b) => a.startS.compareTo(b.startS));
  if (hits.isEmpty) {
    final mid = (phrase.startS + phrase.endS) / 2;
    return [
      phrase.copyWith(
        speaker: speakerAtTime(mid, spans) ??
            _nearestSpeaker(mid, spans, maxDist: 0.8) ??
            phrase.speaker,
      ),
    ];
  }
  if (hits.length == 1) {
    return [phrase.copyWith(speaker: hits.first.name)];
  }
  final tokens =
      phrase.text.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  if (tokens.length <= 1) {
    final mid = (phrase.startS + phrase.endS) / 2;
    return [
      phrase.copyWith(
        speaker: speakerAtTime(mid, spans) ?? hits.first.name,
      ),
    ];
  }
  final weights = [
    for (final p in hits)
      _overlap(phrase.startS, phrase.endS, p.startS, p.endS),
  ];
  final totalW = weights.fold(0.0, (a, b) => a + b);
  final counts = List<int>.filled(hits.length, 0);
  var assigned = 0;
  for (var i = 0; i < hits.length; i++) {
    if (i == hits.length - 1) {
      counts[i] = tokens.length - assigned;
      break;
    }
    final remainingSpeakers = hits.length - i;
    final remainingTokens = tokens.length - assigned;
    var n = (tokens.length * (weights[i] / totalW)).round();
    if (n < 1) {
      n = 1;
    }
    if (n > remainingTokens - (remainingSpeakers - 1)) {
      n = remainingTokens - (remainingSpeakers - 1);
    }
    counts[i] = n;
    assigned += n;
  }
  final out = <TranscriptSegment>[];
  var tokenAt = 0;
  for (var i = 0; i < hits.length; i++) {
    final n = counts[i];
    if (n <= 0) {
      continue;
    }
    final chunk = tokens.sublist(tokenAt, tokenAt + n).join(' ');
    tokenAt += n;
    final p = hits[i];
    final start = math.max(phrase.startS, p.startS);
    final end = math.min(phrase.endS, p.endS);
    out.add(
      TranscriptSegment(
        id: phrase.id,
        clipId: phrase.clipId,
        startS: start,
        endS: end,
        spokenAt: phrase.spokenAt.add(
          Duration(milliseconds: ((start - phrase.startS) * 1000).round()),
        ),
        text: chunk,
        rawText: chunk,
        speaker: p.name,
      ),
    );
  }
  if (tokenAt < tokens.length && out.isNotEmpty) {
    final extra = tokens.sublist(tokenAt).join(' ');
    final last = out.last;
    final text = '${last.text} $extra'.trim();
    out[out.length - 1] = last.copyWith(text: text, rawText: text);
  }
  return out.isEmpty ? [phrase] : out;
}
