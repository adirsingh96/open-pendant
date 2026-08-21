import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../audio/speech_vad.dart';
import '../db/models.dart';
import 'stt_pricing.dart';
import 'voice_store.dart';

class OpenAiStt {
  OpenAiStt({http.Client? client}) : _client = client ?? http.Client();

  static const _url = 'https://api.openai.com/v1/audio/transcriptions';
  static const _scriptPrompt =
      'Speakers mix Hindi and English. Write Hindi in Devanagari script. '
      'Write English in Latin letters. Never use Urdu or Arabic script.';

  final http.Client _client;

  Future<TranscriptResult> transcribe({
    required File wav,
    required String apiKey,
    required DateTime startedAt,
    SpeechExtract? speech,
    bool fast = false,
  }) async {
    if (fast) {
      try {
        return await _once(
          wav: wav,
          apiKey: apiKey,
          startedAt: startedAt,
          model: 'gpt-4o-mini-transcribe',
          speech: speech,
        );
      } catch (e) {
        debugPrint('STT fast gpt-4o-mini-transcribe failed: $e');
        return await _once(
          wav: wav,
          apiKey: apiKey,
          startedAt: startedAt,
          model: 'gpt-transcribe',
          speech: speech,
        );
      }
    }
    final voices = await VoiceStore.list();
    if (voices.isNotEmpty) {
      try {
        return await _once(
          wav: wav,
          apiKey: apiKey,
          startedAt: startedAt,
          model: 'gpt-4o-transcribe-diarize',
          speech: speech,
          voices: voices,
        );
      } catch (e) {
        debugPrint('STT gpt-4o-transcribe-diarize failed: $e');
      }
    }
    const models = ['gpt-transcribe', 'gpt-4o-mini-transcribe'];
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
        debugPrint('STT $model failed: $e');
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
    List<VoiceProfile> voices = const [],
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse(_url));
    req.headers['Authorization'] = 'Bearer $apiKey';
    req.fields['model'] = model;
    final diarize = model.contains('diarize');
    if (diarize) {
      req.fields['response_format'] = 'diarized_json';
      req.fields['chunking_strategy'] = 'auto';
      for (final v in voices) {
        req.files.add(http.MultipartFile.fromString('known_speaker_names[]', v.name));
        req.files.add(
          http.MultipartFile.fromString(
            'known_speaker_references[]',
            await VoiceStore.dataUrl(v),
          ),
        );
      }
    } else if (model == 'whisper-1') {
      req.fields['language'] = 'hi';
      req.fields['response_format'] = 'verbose_json';
      req.fields['timestamp_granularities[]'] = 'segment';
    } else {
      req.fields['response_format'] = 'json';
      req.fields['prompt'] = _scriptPrompt;
      if (model == 'gpt-transcribe') {
        req.files.add(http.MultipartFile.fromString('languages[]', 'hi'));
        req.files.add(http.MultipartFile.fromString('languages[]', 'en'));
      }
    }
    req.files.add(await http.MultipartFile.fromPath('file', wav.path));
    final streamed = await _client.send(req).timeout(const Duration(seconds: 120));
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode >= 400) {
      throw Exception('$model ${streamed.statusCode}: $body');
    }
    final json = jsonDecode(body) as Map<String, dynamic>;
    var result = _parseResult(
      json: json,
      model: model,
      startedAt: startedAt,
      speech: speech,
    );
    // Hindi/Urdu sound the same; auto-detect often writes Nastaliq. Re-run
    // gpt-transcribe with hi+en hints so Hindi lands in Devanagari.
    if (!model.startsWith('gpt-transcribe') && _hasPersoArabic(result)) {
      try {
        final fixed = await _once(
          wav: wav,
          apiKey: apiKey,
          startedAt: startedAt,
          model: 'gpt-transcribe',
          speech: speech,
        );
        result = _mergeSpeakers(from: result, text: fixed);
      } catch (e) {
        debugPrint('Hindi script rewrite failed: $e');
      }
    }
    return result;
  }

  TranscriptResult _parseResult({
    required Map<String, dynamic> json,
    required String model,
    required DateTime startedAt,
    SpeechExtract? speech,
  }) {
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
          rawText: (m['text'] as String? ?? '').trim(),
          speaker: (m['speaker'] as String?)?.trim(),
        ),
      );
    }
    if (segs.isEmpty && text.isNotEmpty) {
      final duration = speech?.speechDurationS ??
          (json['duration'] as num?)?.toDouble() ??
          _usageSeconds(json) ??
          0;
      segs.add(
        TranscriptSegment(
          startS: 0,
          endS: duration,
          spokenAt: startedAt,
          text: text,
          rawText: text,
        ),
      );
    }
    final billedSeconds = speech?.speechDurationS ??
        (json['duration'] as num?)?.toDouble() ??
        _usageSeconds(json) ??
        0;
    final usage = _parseUsage(json);
    final labeled = segs
        .map((s) => s.labeledText)
        .where((t) => t.isNotEmpty)
        .join(' ');
    return TranscriptResult(
      text: labeled.isNotEmpty ? labeled : text,
      model: model,
      segments: segs,
      inputTokens: usage.$1,
      outputTokens: usage.$2,
      costUsd: SttPricing.usd(
        model: model,
        billedSeconds: billedSeconds,
        inputTokens: usage.$1,
        outputTokens: usage.$2,
      ),
    );
  }

  static double? _usageSeconds(Map<String, dynamic> json) {
    final usage = json['usage'];
    if (usage is! Map) {
      return null;
    }
    return (usage['seconds'] as num?)?.toDouble();
  }

  static (int, int) _parseUsage(Map<String, dynamic> json) {
    final usage = json['usage'];
    if (usage is! Map) {
      return (0, 0);
    }
    final map = Map<String, dynamic>.from(usage);
    final inn = (map['input_tokens'] as num?)?.toInt() ?? 0;
    final out = (map['output_tokens'] as num?)?.toInt() ?? 0;
    return (inn, out);
  }

  static bool _hasPersoArabic(TranscriptResult r) {
    return _isPersoArabic(r.text) ||
        r.segments.any((s) => _isPersoArabic(s.text));
  }

  static bool _isPersoArabic(String s) {
    for (final r in s.runes) {
      if ((r >= 0x0600 && r <= 0x06FF) ||
          (r >= 0x0750 && r <= 0x077F) ||
          (r >= 0x08A0 && r <= 0x08FF) ||
          (r >= 0xFB50 && r <= 0xFDFF) ||
          (r >= 0xFE70 && r <= 0xFEFF)) {
        return true;
      }
    }
    return false;
  }

  static TranscriptResult _mergeSpeakers({
    required TranscriptResult from,
    required TranscriptResult text,
  }) {
    final segs = text.segments.map((s) {
      String? speaker;
      var best = 0.0;
      for (final d in from.segments) {
        final overlap = math.min(s.endS, d.endS) - math.max(s.startS, d.startS);
        if (overlap > best) {
          best = overlap;
          speaker = d.speaker;
        }
      }
      return TranscriptSegment(
        startS: s.startS,
        endS: s.endS,
        spokenAt: s.spokenAt,
        text: s.text,
        rawText: s.text,
        speaker: speaker ?? s.speaker,
      );
    }).toList();
    final labeled = segs
        .map((s) => s.labeledText)
        .where((t) => t.isNotEmpty)
        .join(' ');
    return TranscriptResult(
      text: labeled.isNotEmpty ? labeled : text.text,
      model: '${from.model}+gpt-transcribe',
      segments: segs.isNotEmpty ? segs : text.segments,
      inputTokens: from.inputTokens + text.inputTokens,
      outputTokens: from.outputTokens + text.outputTokens,
      costUsd: from.costUsd + text.costUsd,
    );
  }
}
