import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'models.dart';

class ClipStore {
  Database? _db;

  Future<Database> _open() async {
    if (_db != null) {
      return _db!;
    }
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'openpendant.db');
    _db = await openDatabase(
      path,
      version: 4,
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
  cost_usd REAL NOT NULL DEFAULT 0
)''');
        await _createSegmentTable(db);
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
      },
    );
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
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.delete('segments', where: 'clip_id = ?', whereArgs: [clip.id]);
      for (final s in clip.segments) {
        await txn.insert('segments', {
          'clip_id': clip.id,
          'start_s': s.startS,
          'end_s': s.endS,
          'spoken_at': s.spokenAt.toUtc().toIso8601String(),
          'text': s.text,
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
            where: 'spoken_at >= ? AND spoken_at <= ? AND text LIKE ?',
            whereArgs: [start, end, '%$q%'],
            orderBy: 'spoken_at ASC',
          );
    return rows
        .map(
          (s) => TranscriptSegment(
            startS: (s['start_s'] as num).toDouble(),
            endS: (s['end_s'] as num).toDouble(),
            spokenAt: DateTime.parse(s['spoken_at'] as String),
            text: s['text'] as String? ?? '',
            speaker: s['speaker'] as String?,
          ),
        )
        .toList();
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
      'SELECT COALESCE(SUM(cost_usd), 0) AS t FROM clips',
    );
    return (rows.first['t'] as num?)?.toDouble() ?? 0;
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
      segments: segs
          .map(
            (s) => TranscriptSegment(
              startS: (s['start_s'] as num).toDouble(),
              endS: (s['end_s'] as num).toDouble(),
              spokenAt: DateTime.parse(s['spoken_at'] as String),
              text: s['text'] as String? ?? '',
              speaker: s['speaker'] as String?,
            ),
          )
          .toList(),
    );
  }
}
