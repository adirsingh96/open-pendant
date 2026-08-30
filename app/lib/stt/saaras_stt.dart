import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../audio/speech_vad.dart';
import '../db/models.dart';
import 'stt_pricing.dart';
import 'voice_store.dart';

/// Sarvam Saaras v4 REST. Speaker diarization is Batch-only and too slow
/// for live ≤30s pendant clips, so live capture uses REST timestamps.
class SaarasStt {
  SaarasStt({http.Client? client}) : _client = client ?? http.Client();

  static const modelId = 'saaras:v4';
  static const _rest = 'https://api.sarvam.ai/speech-to-text';

  final http.Client _client;

  Future<TranscriptResult> transcribe({
    required File wav,
    required String apiKey,
    required DateTime startedAt,
    SpeechExtract? speech,
  }) async {
    return _restTranscribe(
      wav: wav,
      apiKey: apiKey,
      startedAt: startedAt,
      speech: speech,
      billedSeconds: speech?.speechDurationS ?? 0,
    );
  }

  Future<TranscriptResult> _restTranscribe({
    required File wav,
    required String apiKey,
    required DateTime startedAt,
    SpeechExtract? speech,
    required double billedSeconds,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse(_rest));
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
    final streamed = await _client.send(req).timeout(const Duration(seconds: 120));
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
      billedSeconds: billedSeconds,
    );
  }
}

/// REST has no speaker-reference upload. Map enrolled People onto Saaras
/// turns: unlabeled speech is the first voice (wearer); Speaker 1/2… follow
/// enrollment order when diarized ids are present.
TranscriptResult applySaarasVoiceTags(
  TranscriptResult from,
  List<VoiceProfile> voices,
) {
  final names = voices
      .map((v) => v.name.trim())
      .where((n) => n.isNotEmpty)
      .toList();
  if (names.isEmpty || from.segments.isEmpty) {
    return from;
  }
  final segs = [
    for (final s in from.segments)
      s.copyWith(speaker: mapSaarasSpeaker(s.speaker, names)),
  ];
  final labeled = segs
      .map((s) => s.labeledText)
      .where((t) => t.isNotEmpty)
      .join(' ');
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
  required double billedSeconds,
}) {
  final segs = <TranscriptSegment>[];
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
      final start = (m['start_time_seconds'] as num?)?.toDouble() ?? 0;
      final end = (m['end_time_seconds'] as num?)?.toDouble() ?? start;
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
          final start =
              i < starts.length ? (starts[i] as num?)?.toDouble() ?? 0 : 0.0;
          final end =
              i < ends.length ? (ends[i] as num?)?.toDouble() ?? start : start;
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
  final full = (json['transcript'] as String? ?? '').trim();
  if (segs.isEmpty && full.isNotEmpty) {
    segs.add(
      _seg(
        start: 0,
        end: billedSeconds,
        text: full,
        speaker: null,
        startedAt: startedAt,
        speech: speech,
      ),
    );
  }
  final labeled = segs
      .map((s) => s.labeledText)
      .where((t) => t.isNotEmpty)
      .join(' ');
  return TranscriptResult(
    text: labeled.isNotEmpty ? labeled : full,
    model: model,
    segments: segs,
    costUsd: SttPricing.usd(
      model: model,
      billedSeconds: billedSeconds,
    ),
  );
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
