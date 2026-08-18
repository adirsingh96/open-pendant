import 'dart:math' as math;

class SpeechRegion {
  SpeechRegion({
    required this.origStartS,
    required this.origEndS,
    required this.concatStartS,
    required this.concatEndS,
  });

  final double origStartS;
  final double origEndS;
  final double concatStartS;
  final double concatEndS;
}

class SpeechExtract {
  SpeechExtract({
    required this.speechPcm,
    required this.originalDurationS,
    required this.speechDurationS,
    required this.regions,
  });

  final List<int> speechPcm;
  final double originalDurationS;
  final double speechDurationS;
  final List<SpeechRegion> regions;

  double originalSeconds(double concatS) {
    if (regions.isEmpty) {
      return concatS;
    }
    for (final r in regions) {
      if (concatS >= r.concatStartS && concatS <= r.concatEndS + 1e-6) {
        final frac = r.concatEndS == r.concatStartS
            ? 0.0
            : (concatS - r.concatStartS) / (r.concatEndS - r.concatStartS);
        return r.origStartS + frac * (r.origEndS - r.origStartS);
      }
    }
    return regions.last.origEndS;
  }
}

/// Energy VAD on 16-bit LE mono PCM. Speech if frame RMS >= [rmsThreshold].
SpeechExtract extractSpeech(
  List<int> pcm, {
  int sampleRate = 16000,
  double rmsThreshold = 450,
  double padS = 0.25,
  double minSpeechS = 0.25,
}) {
  final samples = pcm.length ~/ 2;
  final durationS = samples / sampleRate;
  if (samples == 0) {
    return SpeechExtract(
      speechPcm: const [],
      originalDurationS: 0,
      speechDurationS: 0,
      regions: const [],
    );
  }

  const frame = 512;
  final speech = List<bool>.filled((samples + frame - 1) ~/ frame, false);
  for (var f = 0; f < speech.length; f++) {
    final start = f * frame;
    final end = (start + frame) > samples ? samples : start + frame;
    var acc = 0.0;
    var n = 0;
    for (var i = start; i < end; i++) {
      final lo = pcm[i * 2];
      final hi = pcm[i * 2 + 1];
      var s = lo | (hi << 8);
      if (s >= 32768) {
        s -= 65536;
      }
      acc += s * s;
      n++;
    }
    final rms = n == 0 ? 0.0 : math.sqrt(acc / n);
    speech[f] = rms >= rmsThreshold;
  }

  final padFrames = (padS * sampleRate / frame).ceil();
  final padded = List<bool>.from(speech);
  for (var i = 0; i < speech.length; i++) {
    if (!speech[i]) {
      continue;
    }
    final a = i - padFrames < 0 ? 0 : i - padFrames;
    final b = i + padFrames >= speech.length ? speech.length - 1 : i + padFrames;
    for (var j = a; j <= b; j++) {
      padded[j] = true;
    }
  }

  final regions = <SpeechRegion>[];
  final out = <int>[];
  var concatSamples = 0;
  var i = 0;
  while (i < padded.length) {
    if (!padded[i]) {
      i++;
      continue;
    }
    var j = i;
    while (j < padded.length && padded[j]) {
      j++;
    }
    final origStart = i * frame;
    final origEnd = (j * frame > samples) ? samples : j * frame;
    if (origEnd <= origStart) {
      i = j;
      continue;
    }
    final origStartS = origStart / sampleRate;
    final origEndS = origEnd / sampleRate;
    final concatStartS = concatSamples / sampleRate;
    out.addAll(pcm.sublist(origStart * 2, origEnd * 2));
    concatSamples += origEnd - origStart;
    regions.add(
      SpeechRegion(
        origStartS: origStartS,
        origEndS: origEndS,
        concatStartS: concatStartS,
        concatEndS: concatSamples / sampleRate,
      ),
    );
    i = j;
  }

  final speechDurationS = concatSamples / sampleRate;
  if (speechDurationS < minSpeechS) {
    return SpeechExtract(
      speechPcm: const [],
      originalDurationS: durationS,
      speechDurationS: 0,
      regions: const [],
    );
  }

  return SpeechExtract(
    speechPcm: out,
    originalDurationS: durationS,
    speechDurationS: speechDurationS,
    regions: regions,
  );
}

double pcmRms(List<int> pcm) {
  final n = pcm.length ~/ 2;
  if (n == 0) {
    return 0;
  }
  var acc = 0.0;
  for (var i = 0; i < n; i++) {
    final lo = pcm[i * 2];
    final hi = pcm[i * 2 + 1];
    var s = lo | (hi << 8);
    if (s >= 32768) {
      s -= 65536;
    }
    acc += s * s;
  }
  return math.sqrt(acc / n);
}
