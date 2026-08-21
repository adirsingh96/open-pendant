import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'day_recap.dart';
import 'memory_chat.dart';
import 'models.dart';

class ClipStore {
  Database? _db;

  Future<Database> _open() async {
    if (_db != null) {
      await _ensureNotesTable(_db!);
      return _db!;
    }
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'openpendant.db');
    _db = await openDatabase(
      path,
      version: 9,
      onCreate: (db, version) async {
        await db.execute('''
CREATE TABLE clips (
  id TEXT PRIMARY KEY,
  started_at TEXT NOT NULL,
  duration_s REAL NOT NULL,
  full_text TEXT NOT NULL,
  wav_path TEXT,
  stt_model TEXT,
  status TEXT NOT NULL,
  session_id TEXT,
  seq INTEGER NOT NULL DEFAULT 0,
  billed_s REAL NOT NULL DEFAULT 0,
  removed_s REAL NOT NULL DEFAULT 0,
  input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  cost_usd REAL NOT NULL DEFAULT 0,
  refine_input_tokens INTEGER NOT NULL DEFAULT 0,
  refine_output_tokens INTEGER NOT NULL DEFAULT 0,
  refine_cost_usd REAL NOT NULL DEFAULT 0,
  alt_stt_model TEXT,
  alt_full_text TEXT NOT NULL DEFAULT '',
  alt_cost_usd REAL NOT NULL DEFAULT 0,
  alt_error TEXT NOT NULL DEFAULT '',
  alt_segments_json TEXT NOT NULL DEFAULT '[]'
)''');
        await _createSegmentTable(db);
        await _createDayRecapTable(db);
        await _createMemoryChatTable(db);
        await _createNotesTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE clips ADD COLUMN session_id TEXT');
          await db.execute(
            'ALTER TABLE clips ADD COLUMN seq INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'CREATE INDEX idx_clips_session ON clips(session_id, seq)',
          );
        }
        if (oldVersion < 3) {
          await db.execute(
            'ALTER TABLE clips ADD COLUMN billed_s REAL NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE clips ADD COLUMN removed_s REAL NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE clips ADD COLUMN input_tokens INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE clips ADD COLUMN output_tokens INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE clips ADD COLUMN cost_usd REAL NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion < 4) {
          await db.execute('ALTER TABLE segments ADD COLUMN speaker TEXT');
        }
        if (oldVersion < 5) {
          await db.execute(
            'ALTER TABLE clips ADD COLUMN refine_input_tokens INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE clips ADD COLUMN refine_output_tokens INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE clips ADD COLUMN refine_cost_usd REAL NOT NULL DEFAULT 0',
          );
          await db.execute(
            "ALTER TABLE segments ADD COLUMN raw_text TEXT NOT NULL DEFAULT ''",
          );
          await db.execute(
            "UPDATE segments SET raw_text = text WHERE raw_text = ''",
          );
        }
        if (oldVersion < 6) {
          await _createDayRecapTable(db);
        }
        if (oldVersion < 7) {
          await _createMemoryChatTable(db);
        }
        if (oldVersion < 8) {
          await db.execute('ALTER TABLE clips ADD COLUMN alt_stt_model TEXT');
          await db.execute(
            "ALTER TABLE clips ADD COLUMN alt_full_text TEXT NOT NULL DEFAULT ''",
          );
          await db.execute(
            'ALTER TABLE clips ADD COLUMN alt_cost_usd REAL NOT NULL DEFAULT 0',
          );
          await db.execute(
            "ALTER TABLE clips ADD COLUMN alt_error TEXT NOT NULL DEFAULT ''",
          );
          await db.execute(
            "ALTER TABLE clips ADD COLUMN alt_segments_json TEXT NOT NULL DEFAULT '[]'",
          );
        }
        if (oldVersion < 9) {
          await _createNotesTable(db);
        }
      },
    );
    await _ensureNotesTable(_db!);
    return _db!;
  }

  Future<void> _createSegmentTable(DatabaseExecutor db) async {
    await db.execute('''
CREATE TABLE segments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  clip_id TEXT NOT NULL,
  start_s REAL NOT NULL,
  end_s REAL NOT NULL,
  spoken_at TEXT NOT NULL,
  text TEXT NOT NULL,
  raw_text TEXT NOT NULL DEFAULT '',
  speaker TEXT,
  FOREIGN KEY (clip_id) REFERENCES clips(id)
)''');
    await db.execute(
      'CREATE INDEX idx_segments_spoken ON segments(spoken_at)',
    );
    await db.execute('CREATE INDEX idx_segments_text ON segments(text)');
    await db.execute(
      'CREATE INDEX idx_clips_session ON clips(session_id, seq)',
    );
  }

  Future<void> upsertClip(ClipRecord clip) async {
    final db = await _open();
    await db.transaction((txn) async {
      await txn.insert('clips', {
        'id': clip.id,
        'started_at': clip.startedAt.toUtc().toIso8601String(),
        'duration_s': clip.durationS,
        'full_text': clip.fullText,
        'wav_path': clip.wavPath,
        'stt_model': clip.sttModel,
        'status': clip.status,
        'session_id': clip.sessionId,
        'seq': clip.seq,
        'billed_s': clip.billedS,
        'removed_s': clip.removedS,
        'input_tokens': clip.inputTokens,
        'output_tokens': clip.outputTokens,
        'cost_usd': clip.costUsd,
        'refine_input_tokens': clip.refineInputTokens,
        'refine_output_tokens': clip.refineOutputTokens,
        'refine_cost_usd': clip.refineCostUsd,
        'alt_stt_model': clip.altSttModel,
        'alt_full_text': clip.altFullText,
        'alt_cost_usd': clip.altCostUsd,
        'alt_error': clip.altError,
        'alt_segments_json': jsonEncode(encodeAltSegments(clip.altSegments)),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.delete('segments', where: 'clip_id = ?', whereArgs: [clip.id]);
      for (final s in clip.segments) {
        await txn.insert('segments', {
          'clip_id': clip.id,
          'start_s': s.startS,
          'end_s': s.endS,
          'spoken_at': s.spokenAt.toUtc().toIso8601String(),
          'text': s.text,
          'raw_text': s.rawText.trim().isEmpty ? s.text : s.rawText,
          'speaker': s.speaker,
        });
      }
    });
  }

  Future<List<ClipRecord>> listClips({String query = ''}) async {
    final db = await _open();
    final q = query.trim();
    final rows = q.isEmpty
        ? await db.query('clips', orderBy: 'started_at DESC')
        : await db.rawQuery(
            '''
SELECT DISTINCT c.* FROM clips c
LEFT JOIN segments s ON s.clip_id = c.id
WHERE c.full_text LIKE ? OR s.text LIKE ?
ORDER BY c.started_at DESC
''',
            ['%$q%', '%$q%'],
          );
    final clips = <ClipRecord>[];
    for (final row in rows) {
      clips.add(await _clipFromRow(db, row));
    }
    return clips;
  }

  /// Segments whose spoken_at is in [from, to] (inclusive), oldest first.
  Future<List<TranscriptSegment>> listSegmentsInRange({
    required DateTime from,
    required DateTime to,
    String query = '',
  }) async {
    final db = await _open();
    final start = from.toUtc().toIso8601String();
    final end = to.toUtc().toIso8601String();
    final q = query.trim();
    final rows = q.isEmpty
        ? await db.query(
            'segments',
            where: 'spoken_at >= ? AND spoken_at <= ?',
            whereArgs: [start, end],
            orderBy: 'spoken_at ASC',
          )
        : await db.query(
            'segments',
            where: 'spoken_at >= ? AND spoken_at <= ? AND (text LIKE ? OR raw_text LIKE ?)',
            whereArgs: [start, end, '%$q%', '%$q%'],
            orderBy: 'spoken_at ASC',
          );
    return rows.map(_segmentFromRow).toList();
  }

  /// Local calendar midnights that have at least one segment in [from, to].
  Future<List<DateTime>> listLocalDaysWithSpeech({
    required DateTime from,
    required DateTime to,
  }) async {
    final segs = await listSegmentsInRange(from: from, to: to);
    final byKey = <String, DateTime>{};
    for (final s in segs) {
      final l = s.spokenAt.toLocal();
      final day = DateTime(l.year, l.month, l.day);
      final key =
          '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
      byKey[key] = day;
    }
    final days = byKey.values.toList()
      ..sort((a, b) => b.compareTo(a));
    return days;
  }

  TranscriptSegment _segmentFromRow(Map<String, Object?> s) {
    final text = s['text'] as String? ?? '';
    final raw = s['raw_text'] as String? ?? '';
    return TranscriptSegment(
      id: s['id'] as int?,
      clipId: s['clip_id'] as String?,
      startS: (s['start_s'] as num).toDouble(),
      endS: (s['end_s'] as num).toDouble(),
      spokenAt: DateTime.parse(s['spoken_at'] as String),
      text: text,
      rawText: raw.trim().isEmpty ? text : raw,
      speaker: s['speaker'] as String?,
    );
  }

  Future<List<TranscriptSegment>> listRecentSegments({
    required DateTime before,
    int limit = 4,
  }) async {
    final db = await _open();
    final rows = await db.query(
      'segments',
      where: 'spoken_at < ? AND trim(text) != ?',
      whereArgs: [before.toUtc().toIso8601String(), ''],
      orderBy: 'spoken_at DESC',
      limit: limit,
    );
    return rows.map(_segmentFromRow).toList().reversed.toList();
  }

  /// Turns after each day's last Clean. Empty recaps → a short recent tail.
  Future<List<TranscriptSegment>> listSpeechSinceRecaps(
    List<DayRecap> recaps, {
    int noRecapTail = 12,
    int maxTotal = 24,
  }) async {
    if (recaps.isEmpty) {
      return listRecentSegments(
        before: DateTime.now().toUtc().add(const Duration(days: 1)),
        limit: noRecapTail,
      );
    }
    final out = <TranscriptSegment>[];
    for (final recap in recaps) {
      final updated = recap.updatedAt;
      final day = _parseDayKey(recap.dayKey);
      if (updated == null || day == null) {
        continue;
      }
      final end = DateTime(day.year, day.month, day.day, 23, 59, 59);
      final from = updated.toUtc().add(const Duration(milliseconds: 1));
      if (!from.isBefore(end.toUtc())) {
        continue;
      }
      out.addAll(await listSegmentsInRange(from: from, to: end));
    }
    out.sort((a, b) => a.spokenAt.compareTo(b.spokenAt));
    if (out.length <= maxTotal) {
      return out;
    }
    return out.sublist(out.length - maxTotal);
  }

  DateTime? _parseDayKey(String key) {
    final p = key.split('-');
    if (p.length != 3) {
      return null;
    }
    final y = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    final d = int.tryParse(p[2]);
    if (y == null || m == null || d == null) {
      return null;
    }
    return DateTime(y, m, d);
  }

  Future<void> _createMemoryChatTable(DatabaseExecutor db) async {
    await db.execute('''
CREATE TABLE memory_chats (
  id TEXT PRIMARY KEY,
  asked_at TEXT NOT NULL,
  question TEXT NOT NULL,
  answer TEXT,
  error TEXT,
  day_keys_json TEXT NOT NULL DEFAULT '[]'
)''');
    await db.execute(
      'CREATE INDEX idx_memory_chats_asked ON memory_chats(asked_at)',
    );
  }

  Future<List<MemoryChatTurn>> listMemoryChats() async {
    final db = await _open();
    final rows = await db.query('memory_chats', orderBy: 'asked_at ASC');
    return rows.map(_memoryChatFromRow).toList();
  }

  Future<void> upsertMemoryChat(MemoryChatTurn turn) async {
    final db = await _open();
    await db.insert(
      'memory_chats',
      {
        'id': turn.id,
        'asked_at': turn.askedAt.toUtc().toIso8601String(),
        'question': turn.question,
        'answer': turn.answer,
        'error': turn.error,
        'day_keys_json': jsonEncode(turn.dayKeys),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> clearMemoryChats() async {
    final db = await _open();
    await db.delete('memory_chats');
  }

  MemoryChatTurn _memoryChatFromRow(Map<String, Object?> r) {
    var dayKeys = <String>[];
    try {
      final raw = jsonDecode(r['day_keys_json'] as String? ?? '[]');
      if (raw is List) {
        dayKeys = raw.map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList();
      }
    } catch (_) {}
    return MemoryChatTurn(
      id: r['id'] as String,
      askedAt: DateTime.tryParse(r['asked_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      question: r['question'] as String? ?? '',
      answer: r['answer'] as String?,
      error: r['error'] as String?,
      dayKeys: dayKeys,
    );
  }

  Future<void> _ensureNotesTable(DatabaseExecutor db) async {
    await _createNotesTable(db);
  }

  Future<void> _createNotesTable(DatabaseExecutor db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS notes (
  id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL,
  text TEXT NOT NULL,
  clip_id TEXT
)''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_notes_created ON notes(created_at)',
    );
  }

  Future<void> insertNote(SpokenNote note) async {
    final db = await _open();
    await db.insert('notes', {
      'id': note.id,
      'created_at': note.createdAt.toUtc().toIso8601String(),
      'text': note.text,
      'clip_id': note.clipId,
    });
  }

  Future<void> deleteNote(String id) async {
    final db = await _open();
    await db.delete('notes', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<SpokenNote>> listNotesInRange({
    required DateTime from,
    required DateTime to,
    String query = '',
  }) async {
    final db = await _open();
    final start = from.toUtc().toIso8601String();
    final end = to.toUtc().toIso8601String();
    final q = query.trim();
    final rows = q.isEmpty
        ? await db.query(
            'notes',
            where: 'created_at >= ? AND created_at <= ?',
            whereArgs: [start, end],
            orderBy: 'created_at DESC',
          )
        : await db.query(
            'notes',
            where: 'created_at >= ? AND created_at <= ? AND text LIKE ?',
            whereArgs: [start, end, '%$q%'],
            orderBy: 'created_at DESC',
          );
    return [
      for (final r in rows)
        SpokenNote(
          id: r['id'] as String,
          createdAt: DateTime.tryParse(r['created_at'] as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
          text: r['text'] as String? ?? '',
          clipId: r['clip_id'] as String?,
        ),
    ];
  }

  Future<void> _createDayRecapTable(DatabaseExecutor db) async {
    await db.execute('''
CREATE TABLE day_recaps (
  day_key TEXT PRIMARY KEY,
  body_json TEXT NOT NULL,
  model TEXT,
  input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  cost_usd REAL NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
)''');
  }

  Future<void> applyCleanedSegments(List<TranscriptSegment> segs) async {
    final db = await _open();
    await db.transaction((txn) async {
      final clipIds = <String>{};
      for (final s in segs) {
        final id = s.id;
        if (id == null) {
          continue;
        }
        await txn.update(
          'segments',
          {
            'text': s.text,
            'speaker': s.speaker,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
        final cid = s.clipId;
        if (cid != null && cid.isNotEmpty) {
          clipIds.add(cid);
        }
      }
      for (final cid in clipIds) {
        final rows = await txn.query(
          'segments',
          where: 'clip_id = ?',
          whereArgs: [cid],
          orderBy: 'start_s ASC',
        );
        final labeled = rows
            .map(_segmentFromRow)
            .map((s) => s.labeledText)
            .where((t) => t.isNotEmpty)
            .join(' ');
        await txn.update(
          'clips',
          {'full_text': labeled, 'status': 'ok'},
          where: 'id = ?',
          whereArgs: [cid],
        );
      }
    });
  }

  Future<void> renameSpeaker({
    required String from,
    required String to,
  }) async {
    final db = await _open();
    await db.update(
      'segments',
      {'speaker': to},
      where: 'speaker = ?',
      whereArgs: [from],
    );
  }

  Future<DayRecap?> getDayRecap(String dayKey) async {
    final db = await _open();
    final rows = await db.query(
      'day_recaps',
      where: 'day_key = ?',
      whereArgs: [dayKey],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _recapFromRow(rows.first);
  }

  Future<List<DayRecap>> listDayRecaps() async {
    final db = await _open();
    final rows = await db.query('day_recaps', orderBy: 'day_key DESC');
    final out = <DayRecap>[];
    for (final r in rows) {
      final recap = _recapFromRow(r);
      if (recap != null) {
        out.add(recap);
      }
    }
    return out;
  }

  DayRecap? _recapFromRow(Map<String, Object?> r) {
    final dayKey = r['day_key'] as String? ?? '';
    if (dayKey.isEmpty) {
      return null;
    }
    Map<String, dynamic> json;
    try {
      json = jsonDecode(r['body_json'] as String) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    return DayRecap.fromJson(
      dayKey: dayKey,
      json: json,
      model: r['model'] as String?,
      costUsd: (r['cost_usd'] as num?)?.toDouble() ?? 0,
      updatedAt: DateTime.tryParse(r['updated_at'] as String? ?? ''),
    );
  }

  Future<void> upsertDayRecap({
    required DayRecap recap,
    required int inputTokens,
    required int outputTokens,
  }) async {
    final db = await _open();
    await db.insert('day_recaps', {
      'day_key': recap.dayKey,
      'body_json': jsonEncode(recap.toJson()),
      'model': recap.model,
      'input_tokens': inputTokens,
      'output_tokens': outputTokens,
      'cost_usd': recap.costUsd,
      'updated_at': (recap.updatedAt ?? DateTime.now().toUtc()).toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Home list: session groups (newest first) plus standalone clips.
  Future<List<Object>> listHome({String query = ''}) async {
    final clips = await listClips(query: query);
    if (query.trim().isNotEmpty) {
      final ids = clips.map((c) => c.sessionId).whereType<String>().toSet();
      if (ids.isNotEmpty) {
        final extra = await _clipsForSessions(ids);
        final byId = {for (final c in clips) c.id: c};
        for (final c in extra) {
          byId[c.id] = c;
        }
        return _groupClips(byId.values.toList());
      }
    }
    return _groupClips(clips);
  }

  Future<List<ClipRecord>> _clipsForSessions(Set<String> sessionIds) async {
    final db = await _open();
    final clips = <ClipRecord>[];
    for (final sid in sessionIds) {
      final rows = await db.query(
        'clips',
        where: 'session_id = ?',
        whereArgs: [sid],
        orderBy: 'seq ASC',
      );
      for (final row in rows) {
        clips.add(await _clipFromRow(db, row));
      }
    }
    return clips;
  }

  List<Object> _groupClips(List<ClipRecord> clips) {
    final bySession = <String, List<ClipRecord>>{};
    final standalone = <ClipRecord>[];
    for (final c in clips) {
      final sid = c.sessionId;
      if (sid == null || sid.isEmpty) {
        standalone.add(c);
      } else {
        bySession.putIfAbsent(sid, () => []).add(c);
      }
    }
    final groups = <SessionGroup>[];
    for (final e in bySession.entries) {
      e.value.sort((a, b) {
        final s = a.seq.compareTo(b.seq);
        if (s != 0) {
          return s;
        }
        return a.startedAt.compareTo(b.startedAt);
      });
      groups.add(SessionGroup(sessionId: e.key, clips: e.value));
    }
    final items = <Object>[...groups, ...standalone];
    items.sort((a, b) {
      final at = a is SessionGroup ? a.startedAt : (a as ClipRecord).startedAt;
      final bt = b is SessionGroup ? b.startedAt : (b as ClipRecord).startedAt;
      return bt.compareTo(at);
    });
    return items;
  }

  Future<ClipRecord?> getClip(String id) async {
    final db = await _open();
    final rows = await db.query('clips', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) {
      return null;
    }
    return _clipFromRow(db, rows.first);
  }

  Future<double> totalCostUsd() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(cost_usd), 0) + COALESCE(SUM(refine_cost_usd), 0) + COALESCE(SUM(alt_cost_usd), 0) AS t FROM clips',
    );
    final clipSum = (rows.first['t'] as num?)?.toDouble() ?? 0;
    final recapRows = await db.rawQuery(
      'SELECT COALESCE(SUM(cost_usd), 0) AS t FROM day_recaps',
    );
    final recapSum = (recapRows.first['t'] as num?)?.toDouble() ?? 0;
    return clipSum + recapSum;
  }

  Future<({double billedS, int inputTokens, int outputTokens})> totalUsage() async {
    final db = await _open();
    final rows = await db.rawQuery('''
SELECT COALESCE(SUM(billed_s), 0) AS billed,
       COALESCE(SUM(input_tokens), 0) AS inn,
       COALESCE(SUM(output_tokens), 0) AS outt
FROM clips
''');
    final r = rows.first;
    return (
      billedS: (r['billed'] as num?)?.toDouble() ?? 0,
      inputTokens: (r['inn'] as num?)?.toInt() ?? 0,
      outputTokens: (r['outt'] as num?)?.toInt() ?? 0,
    );
  }

  Future<ClipRecord> _clipFromRow(Database db, Map<String, Object?> row) async {
    final id = row['id'] as String;
    final segs = await db.query(
      'segments',
      where: 'clip_id = ?',
      whereArgs: [id],
      orderBy: 'start_s ASC',
    );
    return ClipRecord(
      id: id,
      startedAt: DateTime.parse(row['started_at'] as String),
      durationS: (row['duration_s'] as num).toDouble(),
      fullText: row['full_text'] as String? ?? '',
      wavPath: row['wav_path'] as String?,
      sttModel: row['stt_model'] as String?,
      status: row['status'] as String,
      sessionId: row['session_id'] as String?,
      seq: (row['seq'] as num?)?.toInt() ?? 0,
      billedS: (row['billed_s'] as num?)?.toDouble() ?? 0,
      removedS: (row['removed_s'] as num?)?.toDouble() ?? 0,
      inputTokens: (row['input_tokens'] as num?)?.toInt() ?? 0,
      outputTokens: (row['output_tokens'] as num?)?.toInt() ?? 0,
      costUsd: (row['cost_usd'] as num?)?.toDouble() ?? 0,
      refineInputTokens: (row['refine_input_tokens'] as num?)?.toInt() ?? 0,
      refineOutputTokens: (row['refine_output_tokens'] as num?)?.toInt() ?? 0,
      refineCostUsd: (row['refine_cost_usd'] as num?)?.toDouble() ?? 0,
      altSttModel: row['alt_stt_model'] as String?,
      altFullText: row['alt_full_text'] as String? ?? '',
      altCostUsd: (row['alt_cost_usd'] as num?)?.toDouble() ?? 0,
      altError: row['alt_error'] as String? ?? '',
      altSegments: decodeAltSegments(
        row['alt_segments_json'] as String? ?? '',
        clipId: id,
      ),
      segments: segs.map(_segmentFromRow).toList(),
    );
  }
}
