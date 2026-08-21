import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../db/day_recap.dart';
import 'mem0_store.dart';

const mem0AppId = 'openpendant';

const mem0ExtractInstructions =
    'Extract durable facts: people, product decisions, features shipped, '
    'commitments, and open loops. Keep a build or test day if they decided something. '
    'Skip only empty filler, music, and unintelligible STT.';

class Mem0Hit {
  Mem0Hit({
    required this.id,
    required this.memory,
    this.dayKey,
    this.score,
  });

  final String id;
  final String memory;
  final String? dayKey;
  final double? score;
}

class Mem0Client {
  Mem0Client({http.Client? client}) : _http = client ?? http.Client();

  static const _addUrl = 'https://api.mem0.ai/v3/memories/add/';
  static const _searchUrl = 'https://api.mem0.ai/v3/memories/search/';
  static const _listUrl = 'https://api.mem0.ai/v3/memories/';
  static const _v1Memories = 'https://api.mem0.ai/v1/memories/';

  final http.Client _http;

  Map<String, String> _headers(String apiKey) => {
        'Authorization': 'Token $apiKey',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };

  /// Replaces this day's recap in Mem0, then stores the current pack as-is.
  Future<String> addRecap({
    required String apiKey,
    required String userId,
    required DayRecap recap,
    required String dateLabel,
  }) async {
    await _deleteDayMemories(
      apiKey: apiKey,
      userId: userId,
      dayKey: recap.dayKey,
    );
    final body = jsonEncode({
      'user_id': userId,
      'app_id': mem0AppId,
      'run_id': recap.dayKey,
      'infer': false,
      'observation_date': recap.dayKey,
      'custom_instructions': mem0ExtractInstructions,
      'metadata': {
        'source': 'day_recap',
        'day_key': recap.dayKey,
      },
      'messages': [
        {'role': 'user', 'content': recap.mem0Pack(dateLabel)},
      ],
    });
    final res = await _http
        .post(Uri.parse(_addUrl), headers: _headers(apiKey), body: body)
        .timeout(const Duration(seconds: 30));
    if (res.statusCode >= 400) {
      throw Exception('Mem0 add ${res.statusCode}: ${res.body}');
    }
    debugPrint('Mem0 add ${res.statusCode} ${res.body}');
    try {
      final json = jsonDecode(res.body);
      if (json is Map && json['event_id'] != null) {
        return '${json['event_id']}';
      }
    } catch (_) {}
    return '';
  }

  Future<List<Mem0Hit>> search({
    required String apiKey,
    required String userId,
    required String query,
    int topK = 8,
  }) async {
    final body = jsonEncode({
      'query': query,
      'filters': {
        'AND': [
          {'user_id': userId},
          {'app_id': mem0AppId},
        ],
      },
      'top_k': topK,
      'threshold': 0.0,
      'rerank': true,
    });
    var res = await _http
        .post(Uri.parse(_searchUrl), headers: _headers(apiKey), body: body)
        .timeout(const Duration(seconds: 30));
    if (res.statusCode >= 400) {
      res = await _http
          .post(
            Uri.parse(_searchUrl),
            headers: _headers(apiKey),
            body: jsonEncode({
              'query': query,
              'filters': {'user_id': userId},
              'top_k': topK,
              'threshold': 0.0,
            }),
          )
          .timeout(const Duration(seconds: 30));
    }
    if (res.statusCode >= 400) {
      throw Exception('Mem0 search ${res.statusCode}: ${res.body}');
    }
    debugPrint('Mem0 search ${res.statusCode} ${res.body}');
    return parseMem0Hits(jsonDecode(res.body));
  }

  /// Upload recaps that have not been sent for this Clean timestamp.
  Future<int> syncRecaps({
    required String apiKey,
    required String userId,
    required List<DayRecap> recaps,
    bool force = false,
  }) async {
    var n = 0;
    for (final recap in recaps) {
      final mark = Mem0Store.recapMark(recap.dayKey, recap.updatedAt);
      if (!force && await Mem0Store.wasSynced(mark)) {
        continue;
      }
      await addRecap(
        apiKey: apiKey,
        userId: userId,
        recap: recap,
        dateLabel: dateLabelForDayKey(recap.dayKey),
      );
      await Mem0Store.markSynced(mark);
      n++;
    }
    return n;
  }

  Future<void> _deleteDayMemories({
    required String apiKey,
    required String userId,
    required String dayKey,
  }) async {
    try {
      final listed = await _list(apiKey: apiKey, userId: userId);
      for (final hit in listed) {
        final sameDay = hit.dayKey == dayKey ||
            hit.memory.contains('day_key=$dayKey');
        if (!sameDay || hit.id.isEmpty) {
          continue;
        }
        final del = await _http
            .delete(
              Uri.parse('$_v1Memories${hit.id}/'),
              headers: _headers(apiKey),
            )
            .timeout(const Duration(seconds: 20));
        debugPrint('Mem0 delete ${hit.id} ${del.statusCode}');
      }
    } catch (e) {
      debugPrint('Mem0 delete by id failed: $e');
    }
    try {
      final uri = Uri.parse(_v1Memories).replace(
        queryParameters: {
          'user_id': userId,
          'run_id': dayKey,
          'app_id': mem0AppId,
        },
      );
      final res = await _http
          .delete(uri, headers: _headers(apiKey))
          .timeout(const Duration(seconds: 20));
      debugPrint('Mem0 delete run $dayKey ${res.statusCode}');
    } catch (e) {
      debugPrint('Mem0 delete run failed: $e');
    }
  }

  Future<List<Mem0Hit>> _list({
    required String apiKey,
    required String userId,
  }) async {
    final res = await _http
        .post(
          Uri.parse('$_listUrl?page=1&page_size=100'),
          headers: _headers(apiKey),
          body: jsonEncode({
            'filters': {'user_id': userId},
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode >= 400) {
      debugPrint('Mem0 list ${res.statusCode} ${res.body}');
      return [];
    }
    return parseMem0Hits(jsonDecode(res.body));
  }
}

List<Mem0Hit> hitsFromRecaps(List<DayRecap> recaps) {
  final ordered = [...recaps]
    ..sort((a, b) {
      final au = a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bu = b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bu.compareTo(au);
    });
  return [
    for (final r in ordered)
      Mem0Hit(
        id: r.dayKey,
        memory: r.mem0Pack(dateLabelForDayKey(r.dayKey)),
        dayKey: r.dayKey,
      ),
  ];
}

/// Local cleaned recaps win over older Mem0 copies of the same day.
List<Mem0Hit> mergeMemoryHits({
  required List<DayRecap> recaps,
  required List<Mem0Hit> remote,
}) {
  final local = hitsFromRecaps(recaps);
  final localDays = {for (final h in local) if (h.dayKey != null) h.dayKey!};
  return [
    ...local,
    ...remote.where(
      (h) => h.dayKey == null || !localDays.contains(h.dayKey),
    ),
  ];
}

String dateLabelForDayKey(String dayKey) {
  final d = parseDayKey(dayKey);
  if (d == null) {
    return dayKey;
  }
  return DateFormat.yMMMMEEEEd().format(d);
}

List<Mem0Hit> parseMem0Hits(Object? raw) {
  if (raw is! Map) {
    return [];
  }
  final json = Map<String, dynamic>.from(raw);
  final results = json['results'] ?? json['memories'];
  final list = <dynamic>[];
  if (results is List) {
    list.addAll(results);
  } else if (results is Map) {
    final nested = results['results'] ?? results['memories'];
    if (nested is List) {
      list.addAll(nested);
    }
  }
  final hits = <Mem0Hit>[];
  for (final item in list) {
    if (item is! Map) {
      continue;
    }
    final m = Map<String, dynamic>.from(item);
    final data = m['data'];
    if (data is Map) {
      m.addAll(Map<String, dynamic>.from(data));
    }
    final memory = '${m['memory'] ?? m['text'] ?? m['content'] ?? ''}'.trim();
    if (memory.isEmpty) {
      continue;
    }
    hits.add(
      Mem0Hit(
        id: '${m['id'] ?? ''}',
        memory: memory,
        dayKey: dayKeyFromHit(m),
        score: (m['score'] as num?)?.toDouble(),
      ),
    );
  }
  return hits;
}

extension DayRecapMem0 on DayRecap {
  String mem0Pack(String dateLabel) {
    final buf = StringBuffer()
      ..writeln('OpenPendant day recap for $dateLabel (day_key=$dayKey).');
    if (updatedAt != null) {
      buf.writeln('Summarized: ${updatedAt!.toUtc().toIso8601String()}');
    }
    buf.writeln('Headline: ${headline.isEmpty ? '(none)' : headline}');
    if (decisions.isNotEmpty) {
      buf.writeln('Decisions:');
      for (final d in decisions) {
        buf.writeln('- $d');
      }
    }
    if (followUps.isNotEmpty) {
      buf.writeln('Follow-ups:');
      for (final f in followUps) {
        buf.writeln(
          '- ${[
            if (f.owner.isNotEmpty) f.owner,
            f.action,
            if (f.when.isNotEmpty) f.when,
          ].join(' — ')}',
        );
      }
    }
    if (openLoops.isNotEmpty) {
      buf.writeln('Open loops:');
      for (final o in openLoops) {
        buf.writeln('- $o');
      }
    }
    buf
      ..writeln('People: ${people.isEmpty ? '(none)' : people.join(', ')}')
      ..writeln(
        'Languages: ${languages.isEmpty ? '(none)' : languages.join(', ')}',
      )
      ..writeln('Arc: ${arc.isEmpty ? '(none)' : arc}');
    if (chapters.isNotEmpty) {
      buf.writeln('Chapters:');
      for (final c in chapters) {
        buf.writeln(
          '- ${[
            if (c.when.isNotEmpty) c.when,
            if (c.title.isNotEmpty) c.title,
            c.what,
          ].join(' — ')}',
        );
      }
    }
    return buf.toString();
  }
}

String? dayKeyFromHit(Map<String, dynamic> m) {
  final meta = m['metadata'];
  if (meta is Map) {
    final dk = '${meta['day_key'] ?? ''}'.trim();
    if (looksLikeDayKey(dk)) {
      return dk;
    }
  }
  final memory = '${m['memory'] ?? ''}';
  final match = RegExp(r'day_key=(\d{4}-\d{2}-\d{2})').firstMatch(memory);
  if (match != null) {
    return match.group(1);
  }
  return null;
}

bool looksLikeDayKey(String s) {
  return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s);
}

DateTime? parseDayKey(String key) {
  if (!looksLikeDayKey(key)) {
    return null;
  }
  final p = key.split('-');
  return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
}
