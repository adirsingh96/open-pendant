import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../audio/speech_vad.dart';
import '../audio/wav_writer.dart';
import '../db/models.dart';
import 'stt_pricing.dart';
import 'voice_store.dart';

/// Sarvam Saaras v4 REST. Speaker diarization is Batch-only and too slow
/// for live ≤30s pendant clips, so live capture uses REST timestamps.
///
/// REST rejects audio longer than 30s; we stay under that with ~28s chunks.
class SaarasStt {
  SaarasStt({http.Client? client}) : _client = client ?? http.Client();

  static const modelId = 'saaras:v4';
  static const _rest = 'https://api.sarvam.ai/speech-to-text';

  /// Exclusive 30s API cap — use a margin so boundary clips still succeed.
  static const maxRestSeconds = 28.0;
  static const sampleRate = 16000;
  static const bytesPerSample = 2;

  final http.Client _client;

  Future<TranscriptResult> transcribe({
    required File wav,
    required String apiKey,
    required DateTime startedAt,
    SpeechExtract? speech,
  }) async {
    final bytes = await wav.readAsBytes();
    final pcm = wavPcmBytes(bytes);
    final durationS = pcmDurationSeconds(pcm);
    final billedTotal = speech?.speechDurationS ?? durationS;
    if (durationS <= maxRestSeconds + 1e-6) {
      return _restTranscribe(
        wav: wav,
        apiKey: apiKey,
        startedAt: startedAt,
        speech: speech,
        concatOffsetS: 0,
        billedSeconds: billedTotal,
      );
    }

    final parts = <TranscriptResult>[];
    final ranges = saarasRestPcmRanges(pcm.length);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    for (var i = 0; i < ranges.length; i++) {
      final (start, end) = ranges[i];
      final offsetS = start / (sampleRate * bytesPerSample);
      final chunkPcm = pcm.sublist(start, end);
      final chunkPath = p.join(
        Directory.systemTemp.path,
        'saaras_${stamp}_$i.wav',
      );
      final chunkFile = File(chunkPath);
      try {
        await chunkFile.writeAsBytes(
          pcmToWav(pcm: chunkPcm, sampleRate: sampleRate),
          flush: true,
        );
        final chunkBilled = chunkPcm.length / (sampleRate * bytesPerSample);
        parts.add(
          await _restTranscribe(
            wav: chunkFile,
            apiKey: apiKey,
            startedAt: startedAt,
            speech: speech,
            concatOffsetS: offsetS,
            billedSeconds: chunkBilled,
          ),
        );
      } finally {
        if (await chunkFile.exists()) {
          await chunkFile.delete();
        }
      }
    }
    return mergeSaarasChunkResults(
      parts,
      model: modelId,
      billedSeconds: billedTotal,
    );
  }

  Future<TranscriptResult> _restTranscribe({
    required File wav,
    required String apiKey,
    required DateTime startedAt,
    SpeechExtract? speech,
    required double concatOffsetS,
    required double billedSeconds,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse(_rest));
    req.persistentConnection = false;
    req.headers['api-subscription-key'] = apiKey;
    req.fields['model'] = modelId;
    req.fields['mode'] = 'transcribe';
    req.fields['with_timestamps'] = 'true';
    req.files.add(
      await http.MultipartFile.fromPath(
        'file',
        wav.path,
        filename: 'clip.wav',
      ),
    );
    final streamed =
        await _client.send(req).timeout(const Duration(seconds: 120));
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode >= 400) {
      throw Exception('saaras:v4 REST ${streamed.statusCode}: $body');
    }
    final json = jsonDecode(body) as Map<String, dynamic>;
    return parseSaarasTranscript(
      json: json,
      model: modelId,
      startedAt: startedAt,
      speech: speech,
      concatOffsetS: concatOffsetS,
      billedSeconds: billedSeconds,
    );
  }
}

/// Even byte ranges for mono 16-bit PCM, each ≤ [SaarasStt.maxRestSeconds].
List<(int start, int end)> saarasRestPcmRanges(
  int pcmLength, {
  double maxSeconds = SaarasStt.maxRestSeconds,
  int sampleRate = SaarasStt.sampleRate,
  int bytesPerSample = SaarasStt.bytesPerSample,
}) {
  if (pcmLength <= 0) {
    return const [];
  }
  var maxBytes = (maxSeconds * sampleRate * bytesPerSample).floor();
  if (maxBytes % 2 != 0) {
    maxBytes -= 1;
  }
  if (maxBytes <= 0) {
    return [(0, pcmLength - (pcmLength % 2))];
  }
  final out = <(int, int)>[];
  var start = 0;
  while (start < pcmLength) {
    var end = math.min(start + maxBytes, pcmLength);
    if ((end - start) % 2 != 0) {
      end -= 1;
    }
    if (end <= start) {
      break;
    }
    out.add((start, end));
    start = end;
  }
  return out;
}

Uint8List wavPcmBytes(List<int> wavOrPcm) {
  if (wavOrPcm.length > 44 &&
      String.fromCharCodes(wavOrPcm.sublist(0, 4)) == 'RIFF') {
    return Uint8List.fromList(wavOrPcm.sublist(44));
  }
  return Uint8List.fromList(wavOrPcm);
}

double pcmDurationSeconds(
  List<int> pcm, {
  int sampleRate = SaarasStt.sampleRate,
  int bytesPerSample = SaarasStt.bytesPerSample,
}) {
  if (pcm.isEmpty || bytesPerSample <= 0) {
    return 0;
  }
  return pcm.length / (sampleRate * bytesPerSample);
}

TranscriptResult mergeSaarasChunkResults(
  List<TranscriptResult> parts, {
  required String model,
  required double billedSeconds,
}) {
  final segs = <TranscriptSegment>[
    for (final part in parts) ...part.segments,
  ];
  final texts = parts
      .map((p) => p.text.trim())
      .where((t) => t.isNotEmpty)
      .toList();
  final labeled =
      segs.map((s) => s.labeledText).where((t) => t.isNotEmpty).join(' ');
  final full = texts.join(' ').trim();
  return TranscriptResult(
    text: full.isNotEmpty
        ? (segs.any((s) => (s.speaker ?? '').trim().isNotEmpty)
            ? (labeled.isNotEmpty ? labeled : full)
            : full)
        : labeled,
    model: model,
    segments: segs,
    costUsd: SttPricing.usd(
      model: model,
      billedSeconds: billedSeconds,
    ),
  );
}

bool isSaarasAuthError(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('no keys added') ||
      text.contains('server key') ||
      text.contains('rest 401') ||
      text.contains('rest 403');
}

bool isSaarasDurationError(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('duration') ||
      text.contains('maximum limit') ||
      text.contains('too long') ||
      text.contains('exceeds');
}

String friendlySaarasError(Object error) {
  final text = error.toString();
  if (isSaarasAuthError(error)) {
    return 'Sarvam could not read the saved key. Please retry.';
  }
  if (isSaarasDurationError(error)) {
    return 'That clip was too long for Sarvam in one piece. Try again — longer notes are split automatically.';
  }
  if (text.toLowerCase().contains('timeout')) {
    return 'Sarvam timed out. The clip can be retried.';
  }
  final status = RegExp(r'REST (\d{3})').firstMatch(text)?.group(1);
  return status == null
      ? 'Transcription failed. Please retry.'
      : 'Sarvam transcription failed ($status).';
}

/// REST has no speaker-reference upload. Map enrolled People onto Saaras
/// turns: unlabeled speech is the first voice (wearer); Speaker 1/2… follow
/// enrollment order when diarized ids are present.
TranscriptResult applySaarasVoiceTags(
  TranscriptResult from,
  List<VoiceProfile> voices,
) {
  final names =
      voices.map((v) => v.name.trim()).where((n) => n.isNotEmpty).toList();
  if (names.isEmpty || from.segments.isEmpty) {
    return from;
  }
  final segs = [
    for (final s in from.segments)
      s.copyWith(speaker: mapSaarasSpeaker(s.speaker, names)),
  ];
  final labeled =
      segs.map((s) => s.labeledText).where((t) => t.isNotEmpty).join(' ');
  return TranscriptResult(
    text: labeled.isNotEmpty ? labeled : from.text,
    model: from.model,
    segments: segs,
    inputTokens: from.inputTokens,
    outputTokens: from.outputTokens,
    costUsd: from.costUsd,
  );
}

String? mapSaarasSpeaker(String? speaker, List<String> names) {
  if (names.isEmpty) {
    return speaker;
  }
  final who = (speaker ?? '').trim();
  if (who.isEmpty) {
    return names.first;
  }
  final n = int.tryParse(RegExp(r'(\d+)$').firstMatch(who)?.group(1) ?? '');
  if (n != null && n >= 1 && n <= names.length) {
    return names[n - 1];
  }
  return who;
}

TranscriptResult parseSaarasTranscript({
  required Map<String, dynamic> json,
  required String model,
  required DateTime startedAt,
  SpeechExtract? speech,
  double concatOffsetS = 0,
  required double billedSeconds,
}) {
  final segs = <TranscriptSegment>[];
  final full = (json['transcript'] as String? ?? '').trim();
  final diar = json['diarized_transcript'];
  if (diar is Map && diar['entries'] is List) {
    for (final item in diar['entries'] as List) {
      if (item is! Map) {
        continue;
      }
      final m = Map<String, dynamic>.from(item);
      final text = '${m['transcript'] ?? m['text'] ?? ''}'.trim();
      if (text.isEmpty) {
        continue;
      }
      final start =
          ((m['start_time_seconds'] as num?)?.toDouble() ?? 0) + concatOffsetS;
      final end =
          ((m['end_time_seconds'] as num?)?.toDouble() ?? (start - concatOffsetS)) +
              concatOffsetS;
      segs.add(
        _seg(
          start: start,
          end: end,
          text: text,
          speaker: saarasSpeakerLabel(m['speaker_id']),
          startedAt: startedAt,
          speech: speech,
        ),
      );
    }
  }
  // Word timestamps are often split badly for Hindi. Prefer the API's
  // `transcript` string as-is; keep timestamps only for the time span.
  if (segs.isEmpty && full.isNotEmpty) {
    var start = concatOffsetS;
    var end = concatOffsetS + billedSeconds;
    final span = _timestampSpan(json['timestamps']);
    if (span != null) {
      start = span.$1 + concatOffsetS;
      end = span.$2 + concatOffsetS;
    }
    segs.add(
      _seg(
        start: start,
        end: end > start ? end : concatOffsetS + billedSeconds,
        text: full,
        speaker: null,
        startedAt: startedAt,
        speech: speech,
      ),
    );
  }
  if (segs.isEmpty) {
    final ts = json['timestamps'];
    if (ts is Map) {
      final chunks = ts['words'] ?? ts['chunks'];
      final starts = ts['start_time_seconds'];
      final ends = ts['end_time_seconds'];
      if (chunks is List && starts is List && ends is List) {
        final n = chunks.length;
        for (var i = 0; i < n; i++) {
          final text = '${chunks[i]}'.trim();
          if (text.isEmpty) {
            continue;
          }
          final start = concatOffsetS +
              (i < starts.length ? (starts[i] as num?)?.toDouble() ?? 0 : 0.0);
          final end = concatOffsetS +
              (i < ends.length
                  ? (ends[i] as num?)?.toDouble() ?? (start - concatOffsetS)
                  : (start - concatOffsetS));
          segs.add(
            _seg(
              start: start,
              end: end,
              text: text,
              speaker: null,
              startedAt: startedAt,
              speech: speech,
            ),
          );
        }
      }
    }
  }
  final labeled =
      segs.map((s) => s.labeledText).where((t) => t.isNotEmpty).join(' ');
  return TranscriptResult(
    text: full.isNotEmpty
        ? (segs.any((s) => (s.speaker ?? '').trim().isNotEmpty)
            ? (labeled.isNotEmpty ? labeled : full)
            : full)
        : (labeled.isNotEmpty ? labeled : full),
    model: model,
    segments: segs,
    costUsd: SttPricing.usd(
      model: model,
      billedSeconds: billedSeconds,
    ),
  );
}

(double, double)? _timestampSpan(Object? ts) {
  if (ts is! Map) {
    return null;
  }
  final starts = ts['start_time_seconds'];
  final ends = ts['end_time_seconds'];
  if (starts is! List || ends is! List || starts.isEmpty) {
    return null;
  }
  final start = (starts.first as num?)?.toDouble() ?? 0;
  final end = ends.isEmpty ? start : (ends.last as num?)?.toDouble() ?? start;
  return (start, end);
}

TranscriptSegment _seg({
  required double start,
  required double end,
  required String text,
  required String? speaker,
  required DateTime startedAt,
  SpeechExtract? speech,
}) {
  final origStart = speech?.originalSeconds(start) ?? start;
  final origEnd = speech?.originalSeconds(end) ?? end;
  return TranscriptSegment(
    startS: origStart,
    endS: origEnd,
    spokenAt: startedAt.add(Duration(milliseconds: (origStart * 1000).round())),
    text: text,
    rawText: text,
    speaker: speaker,
  );
}

String? saarasSpeakerLabel(dynamic id) {
  if (id == null) {
    return null;
  }
  final s = '$id'.trim();
  if (s.isEmpty) {
    return null;
  }
  final n = int.tryParse(s);
  if (n != null) {
    return 'Speaker ${n + 1}';
  }
  final m = RegExp(r'(\d+)$').firstMatch(s);
  if (m != null) {
    return 'Speaker ${int.parse(m.group(1)!) + 1}';
  }
  return s;
}
