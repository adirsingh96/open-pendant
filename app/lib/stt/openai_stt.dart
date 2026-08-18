import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../audio/speech_vad.dart';
import '../db/models.dart';

class OpenAiStt {
  OpenAiStt({http.Client? client}) : _client = client ?? http.Client();

  static const _url = 'https://api.openai.com/v1/audio/transcriptions';
  final http.Client _client;

  Future<TranscriptResult> transcribe({
    required File wav,
    required String apiKey,
    required DateTime startedAt,
    SpeechExtract? speech,
  }) async {
    final models = ['gpt-4o-mini-transcribe', 'whisper-1'];
    Object? lastError;
    for (final model in models) {
      try {
        return await _once(
          wav: wav,
          apiKey: apiKey,
          startedAt: startedAt,
          model: model,
          speech: speech,
        );
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('OpenAI transcription failed: $lastError');
  }

  Future<TranscriptResult> _once({
    required File wav,
    required String apiKey,
    required DateTime startedAt,
    required String model,
    SpeechExtract? speech,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse(_url));
    req.headers['Authorization'] = 'Bearer $apiKey';
    req.fields['model'] = model;
    req.fields['language'] = 'en';
    req.fields['response_format'] = 'verbose_json';
    if (model == 'whisper-1') {
      req.fields['timestamp_granularities[]'] = 'segment';
    }
    req.files.add(await http.MultipartFile.fromPath('file', wav.path));
    final streamed = await _client.send(req).timeout(const Duration(seconds: 120));
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode >= 400) {
      throw Exception('$model ${streamed.statusCode}: $body');
    }
    final json = jsonDecode(body) as Map<String, dynamic>;
    final text = (json['text'] as String? ?? '').trim();
    final rawSegs = json['segments'] as List<dynamic>? ?? [];
    final segs = <TranscriptSegment>[];
    for (final item in rawSegs) {
      final m = item as Map<String, dynamic>;
      final start = (m['start'] as num?)?.toDouble() ?? 0;
      final end = (m['end'] as num?)?.toDouble() ?? start;
      final origStart = speech?.originalSeconds(start) ?? start;
      final origEnd = speech?.originalSeconds(end) ?? end;
      segs.add(
        TranscriptSegment(
          startS: origStart,
          endS: origEnd,
          spokenAt: startedAt.add(Duration(milliseconds: (origStart * 1000).round())),
          text: (m['text'] as String? ?? '').trim(),
        ),
      );
    }
    if (segs.isEmpty && text.isNotEmpty) {
      final duration = (json['duration'] as num?)?.toDouble() ?? 0;
      segs.add(
        TranscriptSegment(
          startS: 0,
          endS: duration,
          spokenAt: startedAt,
          text: text,
        ),
      );
    }
    return TranscriptResult(text: text, model: model, segments: segs);
  }
}
