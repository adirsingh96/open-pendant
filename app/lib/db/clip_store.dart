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
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
CREATE TABLE clips (
  id TEXT PRIMARY KEY,
  started_at TEXT NOT NULL,
  duration_s REAL NOT NULL,
  full_text TEXT NOT NULL,
  wav_path TEXT,
  stt_model TEXT,
  status TEXT NOT NULL
)''');
        await db.execute('''
CREATE TABLE segments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  clip_id TEXT NOT NULL,
  start_s REAL NOT NULL,
  end_s REAL NOT NULL,
  spoken_at TEXT NOT NULL,
  text TEXT NOT NULL,
  FOREIGN KEY (clip_id) REFERENCES clips(id)
)''');
        await db.execute(
          'CREATE INDEX idx_segments_spoken ON segments(spoken_at)',
        );
        await db.execute('CREATE INDEX idx_segments_text ON segments(text)');
      },
    );
    return _db!;
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
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.delete('segments', where: 'clip_id = ?', whereArgs: [clip.id]);
      for (final s in clip.segments) {
        await txn.insert('segments', {
          'clip_id': clip.id,
          'start_s': s.startS,
          'end_s': s.endS,
          'spoken_at': s.spokenAt.toUtc().toIso8601String(),
          'text': s.text,
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

  Future<ClipRecord?> getClip(String id) async {
    final db = await _open();
    final rows = await db.query('clips', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) {
      return null;
    }
    return _clipFromRow(db, rows.first);
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
      segments: segs
          .map(
            (s) => TranscriptSegment(
              startS: (s['start_s'] as num).toDouble(),
              endS: (s['end_s'] as num).toDouble(),
              spokenAt: DateTime.parse(s['spoken_at'] as String),
              text: s['text'] as String? ?? '',
            ),
          )
          .toList(),
    );
  }
}
