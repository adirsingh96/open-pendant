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
  SpeakerSpan? best;
  var bestOverlap = 0.0;
  for (final s in spans) {
    final a = startS > s.startS ? startS : s.startS;
    final b = endS < s.endS ? endS : s.endS;
    final overlap = b - a;
    if (overlap > bestOverlap) {
      bestOverlap = overlap;
      best = s;
    }
  }
  if (bestOverlap > 0.05) {
    return best?.name;
  }
  SpeakerSpan? near;
  var dist = 1e9;
  for (final s in spans) {
    final sm = (s.startS + s.endS) / 2;
    final d = (mid - sm).abs();
    if (d < dist) {
      dist = d;
      near = s;
    }
  }
  if (near != null && dist <= 0.8) {
    return near.name;
  }
  return null;
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

/// Keep [words] text and timestamps; stamp speaker names from [diarize]
/// by overlapping time (Saaras words + OpenAI diarize, or Hindi rewrite).
TranscriptResult overlayDiarization({
  required TranscriptResult words,
  required TranscriptResult diarize,
  String? model,
}) {
  final phrases = words.segments;
  final spans = <SpeakerSpan>[
    for (final s in diarize.segments)
      if ((s.speaker ?? '').trim().isNotEmpty)
        SpeakerSpan(
          startS: s.startS,
          endS: s.endS,
          name: s.speaker!.trim(),
        ),
  ];
  var segs = [
    for (final s in phrases)
      s.copyWith(
        speaker: speakerForInterval(
              startS: s.startS,
              endS: s.endS,
              spans: spans,
            ) ??
            s.speaker,
      ),
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
