import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../audio/speech_vad.dart';
import '../db/models.dart';
import 'speaker_spans.dart';
import 'voice_store.dart';

/// Local WeSpeaker/3D-Speaker embedding model. Saaras still does the words;
/// this only labels who spoke when from People WAV samples.
class LocalSpeaker {
  static const _modelFile = 'eres2net_sv_en_voxceleb_16k.onnx';
  static const _modelUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_sv_en_voxceleb_16k.onnx';
  static const _threshold = 0.28;
  static const _winS = 1.6;
  static const _hopS = 0.5;
  static const _sampleRate = 16000;
  static const _minRms = 0.012;

  static bool _bindings = false;
  static sherpa.SpeakerEmbeddingExtractor? _extractor;

  static Future<File> modelFile() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File(p.join(dir.path, _modelFile));
  }

  static Future<File> ensureModel() async {
    final f = await modelFile();
    if (await f.exists() && await f.length() > 1000000) {
      return f;
    }
    debugPrint('Downloading local speaker model…');
    final res = await http.get(Uri.parse(_modelUrl)).timeout(
          const Duration(minutes: 5),
        );
    if (res.statusCode >= 400) {
      throw Exception('Speaker model download ${res.statusCode}');
    }
    await f.writeAsBytes(res.bodyBytes, flush: true);
    return f;
  }

  static Future<void> _init() async {
    if (!_bindings) {
      sherpa.initBindings();
      _bindings = true;
    }
    if (_extractor != null) {
      return;
    }
    final model = await ensureModel();
    _extractor = sherpa.SpeakerEmbeddingExtractor(
      config: sherpa.SpeakerEmbeddingExtractorConfig(
        model: model.path,
        numThreads: 1,
        debug: false,
        provider: 'cpu',
      ),
    );
  }

  static Float32List _wavToFloat(List<int> bytes) {
    var raw = Uint8List.fromList(bytes);
    if (raw.length > 44 && String.fromCharCodes(raw.sublist(0, 4)) == 'RIFF') {
      raw = raw.sublist(44);
    }
    final n = raw.length ~/ 2;
    final out = Float32List(n);
    final bd = ByteData.sublistView(raw);
    for (var i = 0; i < n; i++) {
      out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  static double _rms(Float32List samples) {
    if (samples.isEmpty) {
      return 0;
    }
    var s = 0.0;
    for (final v in samples) {
      s += v * v;
    }
    return math.sqrt(s / samples.length);
  }

  static Float32List _embed(Float32List samples) {
    final ex = _extractor!;
    final stream = ex.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: _sampleRate);
      stream.inputFinished();
      if (!ex.isReady(stream)) {
        return Float32List(0);
      }
      return ex.compute(stream);
    } finally {
      stream.free();
    }
  }

  static List<Float32List> _embedChunks(Float32List samples) {
    final win = (_winS * _sampleRate).round();
    final hop = (_sampleRate * 0.8).round();
    final out = <Float32List>[];
    if (samples.length <= win) {
      if (_rms(samples) >= _minRms) {
        final emb = _embed(samples);
        if (emb.isNotEmpty) {
          out.add(emb);
        }
      }
      return out;
    }
    for (var i = 0; i + win ~/ 2 < samples.length; i += hop) {
      final end = i + win > samples.length ? samples.length : i + win;
      final slice = Float32List.fromList(samples.sublist(i, end));
      if (_rms(slice) < _minRms) {
        continue;
      }
      final emb = _embed(slice);
      if (emb.isNotEmpty) {
        out.add(emb);
      }
    }
    return out;
  }

  static Future<List<SpeakerSpan>> spansForWav(
    File wav, {
    SpeechExtract? speech,
  }) async {
    final voices = await VoiceStore.list();
    if (voices.isEmpty) {
      return const [];
    }
    await _init();
    final ex = _extractor!;
    final manager = sherpa.SpeakerEmbeddingManager(ex.dim);
    try {
      for (final v in voices) {
        final samples = _wavToFloat(await File(v.wavPath).readAsBytes());
        if (samples.length < _sampleRate ~/ 4) {
          continue;
        }
        final chunks = _embedChunks(samples);
        if (chunks.isEmpty) {
          continue;
        }
        if (chunks.length == 1) {
          manager.add(name: v.name, embedding: chunks.first);
        } else {
          manager.addMulti(name: v.name, embeddingList: chunks);
        }
      }
      if (manager.numSpeakers < 1) {
        return const [];
      }
      final clip = _wavToFloat(await wav.readAsBytes());
      final win = (_winS * _sampleRate).round();
      final hop = (_hopS * _sampleRate).round();
      final raw = <SpeakerSpan>[];
      if (clip.length < win ~/ 2) {
        if (_rms(clip) >= _minRms) {
          final emb = _embed(clip);
          final name = emb.isEmpty
              ? ''
              : manager.search(embedding: emb, threshold: _threshold);
          if (name.isNotEmpty) {
            raw.add(
              SpeakerSpan(
                startS: 0,
                endS: clip.length / _sampleRate,
                name: name,
              ),
            );
          }
        }
      } else {
        for (var i = 0; i + win ~/ 3 < clip.length; i += hop) {
          final end = i + win > clip.length ? clip.length : i + win;
          final slice = Float32List.fromList(clip.sublist(i, end));
          if (_rms(slice) < _minRms) {
            continue;
          }
          final emb = _embed(slice);
          if (emb.isEmpty) {
            continue;
          }
          final name = manager.search(embedding: emb, threshold: _threshold);
          if (name.isEmpty) {
            continue;
          }
          raw.add(
            SpeakerSpan(
              startS: i / _sampleRate,
              endS: end / _sampleRate,
              name: name,
            ),
          );
        }
      }
      if (speech == null) {
        return raw;
      }
      return [
        for (final s in raw)
          SpeakerSpan(
            startS: speech.originalSeconds(s.startS),
            endS: speech.originalSeconds(s.endS),
            name: s.name,
          ),
      ];
    } finally {
      manager.free();
    }
  }

  static Future<TranscriptResult> tagTranscript({
    required File wav,
    required TranscriptResult transcript,
    SpeechExtract? speech,
  }) async {
    final phrases = mergeCloseSegments(transcript.segments);
    final spans = await spansForWav(wav, speech: speech);
    if (spans.isEmpty) {
      return TranscriptResult(
        text: joinLabeled(phrases),
        model: transcript.model,
        segments: phrases,
        inputTokens: transcript.inputTokens,
        outputTokens: transcript.outputTokens,
        costUsd: transcript.costUsd,
      );
    }
    final segs = [
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
    final merged = mergeCloseSegments(segs);
    return TranscriptResult(
      text: joinLabeled(merged),
      model: '${transcript.model}+local-sid',
      segments: merged,
      inputTokens: transcript.inputTokens,
      outputTokens: transcript.outputTokens,
      costUsd: transcript.costUsd,
    );
  }
}

String joinLabeled(List<TranscriptSegment> segs) {
  return segs
      .map((s) => s.labeledText)
      .where((t) => t.isNotEmpty)
      .join(' ')
      .trim();
}
