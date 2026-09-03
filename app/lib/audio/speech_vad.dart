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

/// Local speech gate (no cloud): speech-band energy + spectral centroid.
/// Closer to a Librosa-style check than RMS. Hiss/rumble usually fail;
/// voiced speech (formants ~0.3–3.4 kHz, centroid ~0.2–2.8 kHz) passes.
SpeechExtract extractSpeech(
  List<int> pcm, {
  int sampleRate = 16000,
  double padS = 0.25,
  double minSpeechS = 0.25,
  double? energyFloor,
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
  final floor = energyFloor ?? VadGate.energyFloor;
  final speech = List<bool>.filled((samples + frame - 1) ~/ frame, false);
  for (var f = 0; f < speech.length; f++) {
    final start = f * frame;
    final end = (start + frame) > samples ? samples : start + frame;
    speech[f] = _frameIsVoice(pcm, start, end - start, sampleRate, floor);
  }

  final padFrames = (padS * sampleRate / frame).ceil();
  final padded = List<bool>.from(speech);
  for (var i = 0; i < speech.length; i++) {
    if (!speech[i]) {
      continue;
    }
    final a = i - padFrames < 0 ? 0 : i - padFrames;
    final b =
        i + padFrames >= speech.length ? speech.length - 1 : i + padFrames;
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

/// True if this PCM snippet looks like human speech (for live quiet/rotate).
bool pcmHasVoice(List<int> pcm, {int sampleRate = 16000, double? energyFloor}) {
  final n = pcm.length ~/ 2;
  if (n < 64) {
    return false;
  }
  final start = n > 512 ? n - 512 : 0;
  return _frameIsVoice(
    pcm,
    start,
    n - start,
    sampleRate,
    energyFloor ?? VadGate.energyFloor,
  );
}

double pcmRms(List<int> pcm) {
  final n = pcm.length ~/ 2;
  if (n == 0) {
    return 0;
  }
  var acc = 0.0;
  for (var i = 0; i < n; i++) {
    acc += math.pow(_sample(pcm, i), 2);
  }
  return math.sqrt(acc / n);
}

/// Raise quiet necklace PCM toward phone-mic loudness. Phone clips already
/// near [targetRms] are left alone.
List<int> boostPcmToTargetRms(
  List<int> pcm, {
  double targetRms = 2800,
  double maxGain = 2.5,
}) {
  final rms = pcmRms(pcm);
  if (rms < 8 || rms >= targetRms) {
    return pcm;
  }
  final g = math.min(maxGain, targetRms / rms);
  final out = List<int>.from(pcm);
  for (var i = 0; i + 1 < out.length; i += 2) {
    var s = out[i] | (out[i + 1] << 8);
    if (s >= 32768) {
      s -= 65536;
    }
    var v = (s * g).round();
    if (v > 32767) {
      v = 32767;
    } else if (v < -32768) {
      v = -32768;
    }
    out[i] = v & 0xff;
    out[i + 1] = (v >> 8) & 0xff;
  }
  return out;
}

SpeechExtract fullClipExtract(List<int> pcm, {int sampleRate = 16000}) {
  final d = pcm.length / 2 / sampleRate;
  return SpeechExtract(
    speechPcm: pcm,
    originalDurationS: d,
    speechDurationS: d,
    regions: [
      SpeechRegion(
        origStartS: 0,
        origEndS: d,
        concatStartS: 0,
        concatEndS: d,
      ),
    ],
  );
}

int _sample(List<int> pcm, int i) {
  final lo = pcm[i * 2];
  final hi = pcm[i * 2 + 1];
  var s = lo | (hi << 8);
  if (s >= 32768) {
    s -= 65536;
  }
  return s;
}

bool _frameIsVoice(
  List<int> pcm,
  int startSample,
  int nSamples,
  int sampleRate,
  double energyFloor,
) {
  final spec = analyzeFrame(pcm, startSample, nSamples, sampleRate);
  if (spec == null || spec.totalPow < energyFloor) {
    return false;
  }
  return spec.ratio >= 0.45 &&
      spec.centroidHz >= 200 &&
      spec.centroidHz <= 2800;
}

class FrameSpectrum {
  FrameSpectrum({
    required this.totalPow,
    required this.speechPow,
    required this.ratio,
    required this.centroidHz,
  });

  final double totalPow;
  final double speechPow;
  final double ratio;
  final double centroidHz;
}

/// In-memory VAD loudness floor. Loaded/saved by [VadCal] for notes.
/// Meetings use a fixed floor so distant talkers are not gated by wearer
/// calibrate (Knowles SPU0410 on the chest, ~1–2 m others).
class VadGate {
  static const defaultEnergyFloor = 1e10;
  static const meetingEnergyFloor = 1e9;
  static const meetingMinSpeechS = 0.5;
  static double energyFloor = defaultEnergyFloor;
  static DateTime? calibratedAt;

  static double get minSpeechS => calibratedAt == null ? 1.5 : 1.0;
}

FrameSpectrum? analyzeFrame(
  List<int> pcm,
  int startSample,
  int nSamples,
  int sampleRate,
) {
  const nfft = 512;
  if (nSamples <= 0) {
    return null;
  }
  final re = List<double>.filled(nfft, 0);
  final im = List<double>.filled(nfft, 0);
  var prev = 0.0;
  var hp = 0.0;
  final take = nSamples < nfft ? nSamples : nfft;
  for (var i = 0; i < take; i++) {
    final x = _sample(pcm, startSample + i).toDouble();
    hp = 0.97 * (hp + x - prev);
    prev = x;
    re[i] = hp;
  }
  _fft(re, im);

  final binHz = sampleRate / nfft;
  final lo = math.max(1, (300 / binHz).floor());
  final hi = math.min(nfft ~/ 2 - 1, (3400 / binHz).ceil());
  var speechPow = 0.0;
  var totalPow = 0.0;
  var centNum = 0.0;
  for (var k = 1; k < nfft ~/ 2; k++) {
    final p = re[k] * re[k] + im[k] * im[k];
    totalPow += p;
    centNum += p * k * binHz;
    if (k >= lo && k <= hi) {
      speechPow += p;
    }
  }
  if (totalPow <= 0) {
    return null;
  }
  return FrameSpectrum(
    totalPow: totalPow,
    speechPow: speechPow,
    ratio: speechPow / totalPow,
    centroidHz: centNum / totalPow,
  );
}

/// Wear the pendant as you will all day, read the script, then call this.
/// Floor is ~6 dB below the median speech-shaped frame so a bit of extra
/// distance still counts.
double suggestEnergyFloor(List<int> pcm, {int sampleRate = 16000}) {
  const frame = 512;
  final samples = pcm.length ~/ 2;
  final vals = <double>[];
  for (var start = 0; start + 64 <= samples; start += frame) {
    final n = start + frame > samples ? samples - start : frame;
    final spec = analyzeFrame(pcm, start, n, sampleRate);
    if (spec == null) {
      continue;
    }
    if (spec.ratio >= 0.4 &&
        spec.centroidHz >= 200 &&
        spec.centroidHz <= 2800) {
      vals.add(spec.totalPow);
    }
  }
  if (vals.length < 6) {
    throw Exception(
      'Not enough clear speech in the sample. Wear the pendant as usual and read the whole script.',
    );
  }
  vals.sort();
  final median = vals[vals.length ~/ 2];
  final floor = median * 0.25;
  if (floor < 1e7) {
    return 1e7;
  }
  if (floor > 5e11) {
    return 5e11;
  }
  return floor;
}

void _fft(List<double> re, List<double> im) {
  final n = re.length;
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j >= bit; bit >>= 1) {
      j -= bit;
    }
    j += bit;
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      final ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final ang = -2 * math.pi / len;
    final wlenRe = math.cos(ang);
    final wlenIm = math.sin(ang);
    final half = len >> 1;
    for (var i = 0; i < n; i += len) {
      var wRe = 1.0;
      var wIm = 0.0;
      for (var j = 0; j < half; j++) {
        final i0 = i + j;
        final i1 = i0 + half;
        final vRe = re[i1] * wRe - im[i1] * wIm;
        final vIm = re[i1] * wIm + im[i1] * wRe;
        re[i1] = re[i0] - vRe;
        im[i1] = im[i0] - vIm;
        re[i0] += vRe;
        im[i0] += vIm;
        final nwRe = wRe * wlenRe - wIm * wlenIm;
        wIm = wRe * wlenIm + wIm * wlenRe;
        wRe = nwRe;
      }
    }
  }
}
