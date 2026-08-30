import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../db/day_recap.dart';
import '../db/models.dart';
import 'day_clean_prompt.dart';
import 'stt_pricing.dart';
import 'transcript_refine.dart';

class RefineResult {
  RefineResult({
    required this.segments,
    required this.inputTokens,
    required this.outputTokens,
    required this.costUsd,
  });

  final List<TranscriptSegment> segments;
  final int inputTokens;
  final int outputTokens;
  final double costUsd;
}

class DayCleanResult {
  DayCleanResult({
    required this.segments,
    required this.recap,
    required this.inputTokens,
    required this.outputTokens,
    required this.costUsd,
  });

  final List<TranscriptSegment> segments;
  final DayRecap recap;
  final int inputTokens;
  final int outputTokens;
  final double costUsd;
}

class OpenAiRefine {
  OpenAiRefine({http.Client? client}) : _client = client ?? http.Client();

  static const _url = 'https://api.openai.com/v1/chat/completions';

  final http.Client _client;

  Future<RefineResult> refine({
    required String apiKey,
    required List<TranscriptSegment> segments,
    List<TranscriptSegment> prior = const [],
  }) async {
    final priorBlock = prior.isEmpty
        ? ''
        : 'Previous cleaned turns (context only, do not repeat):\n'
            '${prior.map((s) => s.labeledText).where((t) => t.isNotEmpty).join('\n')}\n\n';
    final turns = <Map<String, Object?>>[];
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      turns.add({
        'i': i,
        'speaker': s.speaker,
        'text': s.rawText.trim().isEmpty ? s.text : s.rawText,
      });
    }
    final user = StringBuffer()
      ..write(priorBlock)
      ..write(
          'Clean these STT turns. Return JSON {"turns":[{"i":0,"speaker":"A","text":"..."}]}.\n')
      ..write(
          'Rules: drop noise, music, filler, and nonsense. Light-edit punctuation and ')
      ..write(
          'Hindi in Devanagari / English in Latin. Never Urdu/Arabic script. ')
      ..write(
          'Do not translate. Do not invent. Keep speakers. Empty text means drop.\n')
      ..write(jsonEncode({'turns': turns}));

    final req = await _client
        .post(
          Uri.parse(_url),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': refineModel,
            'temperature': 0,
            'response_format': {'type': 'json_object'},
            'messages': [
              {
                'role': 'system',
                'content':
                    'You clean wearable-mic transcripts. You never add facts.',
              },
              {'role': 'user', 'content': user.toString()},
            ],
          }),
        )
        .timeout(const Duration(seconds: 60));
    if (req.statusCode >= 400) {
      throw Exception('refine ${req.statusCode}: ${req.body}');
    }
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final usage = body['usage'] as Map<String, dynamic>? ?? {};
    final inn = (usage['prompt_tokens'] as num?)?.toInt() ??
        (usage['input_tokens'] as num?)?.toInt() ??
        0;
    final out = (usage['completion_tokens'] as num?)?.toInt() ??
        (usage['output_tokens'] as num?)?.toInt() ??
        0;
    final content = (body['choices'] as List).first as Map<String, dynamic>;
    final msg = content['message'] as Map<String, dynamic>;
    final raw = msg['content'] as String? ?? '{}';
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('refine JSON parse failed: $e');
      return RefineResult(
        segments: segments,
        inputTokens: inn,
        outputTokens: out,
        costUsd: SttPricing.usd(
          model: refineModel,
          billedSeconds: 0,
          inputTokens: inn,
          outputTokens: out,
        ),
      );
    }
    final list = parsed['turns'];
    final maps = <Map<String, dynamic>>[];
    if (list is List) {
      for (final item in list) {
        if (item is Map) {
          maps.add(Map<String, dynamic>.from(item));
        }
      }
    }
    return RefineResult(
      segments: applyRefineTurns(original: segments, turns: maps),
      inputTokens: inn,
      outputTokens: out,
      costUsd: SttPricing.usd(
        model: refineModel,
        billedSeconds: 0,
        inputTokens: inn,
        outputTokens: out,
      ),
    );
  }

  Future<DayCleanResult> cleanAndRecapDay({
    required String apiKey,
    required String dayKey,
    required String dateLabel,
    required String rangeLabel,
    required List<TranscriptSegment> segments,
  }) async {
    var inn = 0;
    var out = 0;
    var cleaned = segments;
    Map<String, dynamic> summaryJson;

    if (segments.length <= 120) {
      final parsed = await _chat(
        apiKey: apiKey,
        system: DayCleanPrompt.system,
        user: DayCleanPrompt.user(
          dateLabel: dateLabel,
          rangeLabel: rangeLabel,
          turns: _turnRows(segments),
        ),
        timeout: const Duration(seconds: 180),
      );
      inn += parsed.inputTokens;
      out += parsed.outputTokens;
      cleaned = applyRefineTurns(
        original: segments,
        turns: _turnMaps(parsed.json),
      );
      summaryJson = parsed.json;
    } else {
      const batch = 80;
      final maps = <Map<String, dynamic>>[];
      for (var start = 0; start < segments.length; start += batch) {
        final end =
            start + batch > segments.length ? segments.length : start + batch;
        final slice = segments.sublist(start, end);
        final rows = <Map<String, Object?>>[];
        for (var i = 0; i < slice.length; i++) {
          final s = slice[i];
          rows.add({
            'i': start + i,
            'at': s.spokenAt.toLocal().toIso8601String(),
            'speaker': s.speaker,
            'text': s.rawText.trim().isEmpty ? s.text : s.rawText,
          });
        }
        final parsed = await _chat(
          apiKey: apiKey,
          system: DayCleanPrompt.system,
          user: DayCleanPrompt.batchClean(turns: rows),
          timeout: const Duration(seconds: 120),
        );
        inn += parsed.inputTokens;
        out += parsed.outputTokens;
        maps.addAll(_turnMaps(parsed.json));
      }
      cleaned = applyRefineTurns(original: segments, turns: maps);
      var transcript = cleaned
          .map((s) => s.labeledText)
          .where((t) => t.isNotEmpty)
          .join('\n');
      if (transcript.length > 40000) {
        transcript = transcript.substring(0, 40000);
      }
      final parsed = await _chat(
        apiKey: apiKey,
        system: DayCleanPrompt.system,
        user: DayCleanPrompt.summaryOnly(
          dateLabel: dateLabel,
          rangeLabel: rangeLabel,
          cleanedTranscript: transcript,
        ),
        timeout: const Duration(seconds: 120),
      );
      inn += parsed.inputTokens;
      out += parsed.outputTokens;
      summaryJson = parsed.json;
    }

    final cost = SttPricing.usd(
      model: refineModel,
      billedSeconds: 0,
      inputTokens: inn,
      outputTokens: out,
    );
    return DayCleanResult(
      segments: cleaned,
      recap: clipRecapToSpeech(
        recap: DayRecap.fromJson(
          dayKey: dayKey,
          json: summaryJson,
          model: refineModel,
          costUsd: cost,
          updatedAt: DateTime.now().toUtc(),
        ),
        firstSpoken: segments
            .map((s) => s.spokenAt)
            .reduce((a, b) => a.isBefore(b) ? a : b),
        lastSpoken: segments
            .map((s) => s.spokenAt)
            .reduce((a, b) => a.isAfter(b) ? a : b),
      ),
      inputTokens: inn,
      outputTokens: out,
      costUsd: cost,
    );
  }

  List<Map<String, Object?>> _turnRows(List<TranscriptSegment> segments) {
    final rows = <Map<String, Object?>>[];
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      rows.add({
        'i': i,
        'at': s.spokenAt.toLocal().toIso8601String(),
        'speaker': s.speaker,
        'text': s.rawText.trim().isEmpty ? s.text : s.rawText,
      });
    }
    return rows;
  }

  List<Map<String, dynamic>> _turnMaps(Map<String, dynamic> json) {
    final list = json['turns'];
    final maps = <Map<String, dynamic>>[];
    if (list is List) {
      for (final item in list) {
        if (item is Map) {
          maps.add(Map<String, dynamic>.from(item));
        }
      }
    }
    return maps;
  }

  Future<({Map<String, dynamic> json, int inputTokens, int outputTokens})>
      _chat({
    required String apiKey,
    required String system,
    required String user,
    required Duration timeout,
  }) async {
    final req = await _client
        .post(
          Uri.parse(_url),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': refineModel,
            'temperature': 0.2,
            'response_format': {'type': 'json_object'},
            'messages': [
              {'role': 'system', 'content': system},
              {'role': 'user', 'content': user},
            ],
          }),
        )
        .timeout(timeout);
    if (req.statusCode >= 400) {
      throw Exception('day clean ${req.statusCode}: ${req.body}');
    }
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final usage = body['usage'] as Map<String, dynamic>? ?? {};
    final inn = (usage['prompt_tokens'] as num?)?.toInt() ??
        (usage['input_tokens'] as num?)?.toInt() ??
        0;
    final out = (usage['completion_tokens'] as num?)?.toInt() ??
        (usage['output_tokens'] as num?)?.toInt() ??
        0;
    final content = (body['choices'] as List).first as Map<String, dynamic>;
    final msg = content['message'] as Map<String, dynamic>;
    final raw = msg['content'] as String? ?? '{}';
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('day clean JSON parse failed: $e');
      parsed = {};
    }
    return (json: parsed, inputTokens: inn, outputTokens: out);
  }

  /// Answer from recaps plus recent journal speech. Recaps can lag the last turns.
  Future<String> answerFromMemories({
    required String apiKey,
    required String question,
    required List<({String memory, String? dayKey})> memories,
    String recentSpeech = '',
  }) async {
    final buf = StringBuffer();
    for (var i = 0; i < memories.length; i++) {
      final m = memories[i];
      buf.writeln('${i + 1}. ${m.memory}');
      if (m.dayKey != null && m.dayKey!.isNotEmpty) {
        buf.writeln('   day_key=${m.dayKey}');
      }
    }
    final recent = recentSpeech.trim();
    final req = await _client
        .post(
          Uri.parse(_url),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': refineModel,
            'temperature': 0.2,
            'messages': [
              {
                'role': 'system',
                'content': 'You answer questions from the wearer\'s journal recaps. '
                    'Stay on the question\'s topic. Same-day follow-ups about a '
                    'different project or tool must be omitted. If one line mixes '
                    'two workstreams, keep only the part that matches the question. '
                    'Day recaps cover speech up to that Clean. Speech since last '
                    'Clean is extra fact — use it, especially for gym, body, '
                    'health, sleep, or how the wearer felt. Do not say "not in '
                    'the recaps" if recent speech answers the question. '
                    'STT may drop letters (n for neck, m for my). Infer only when '
                    'the surrounding words make that obvious. '
                    'If the question is about plans, next steps, or "future", prefer '
                    'matching decisions, follow-ups, and open loops. Do not dump the '
                    'whole day. Mention calendar dates. Do not invent.',
              },
              {
                'role': 'user',
                'content': 'Question: $question\n'
                    'Use only facts about that subject. Ignore other projects '
                    'that happen to share the same calendar day.\n\n'
                    'Day recaps:\n${buf.toString()}'
                    '${recent.isEmpty ? '' : '\n\nSpeech since last Clean (newest last):\n$recent'}',
              },
            ],
          }),
        )
        .timeout(const Duration(seconds: 45));
    if (req.statusCode >= 400) {
      throw Exception('memory answer ${req.statusCode}: ${req.body}');
    }
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final content = (body['choices'] as List).first as Map<String, dynamic>;
    final msg = content['message'] as Map<String, dynamic>;
    return (msg['content'] as String? ?? '').trim();
  }

  Future<String> answerAboutMeeting({
    required String apiKey,
    required String question,
    required String recap,
    required String transcript,
  }) async {
    final req = await _client
        .post(
          Uri.parse(_url),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': refineModel,
            'temperature': 0.2,
            'messages': [
              {
                'role': 'system',
                'content':
                    'You answer questions about one meeting. Use only the recap '
                        'and transcript. Mention speakers and clock times when they '
                        'are in the source. Do not invent.',
              },
              {
                'role': 'user',
                'content':
                    'Question: $question\n\nRecap:\n${recap.trim().isEmpty ? '(none)' : recap}\n\n'
                        'Transcript:\n${transcript.trim().isEmpty ? '(none)' : transcript}',
              },
            ],
          }),
        )
        .timeout(const Duration(seconds: 45));
    if (req.statusCode >= 400) {
      throw Exception('meeting answer ${req.statusCode}: ${req.body}');
    }
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final content = (body['choices'] as List).first as Map<String, dynamic>;
    final msg = content['message'] as Map<String, dynamic>;
    return (msg['content'] as String? ?? '').trim();
  }
}
