import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// After turning off the macOS sandbox, path_provider leaves the container
/// and opens empty ~/Documents. Copy the journal + keys once if the old
/// container copy is larger.
Future<void> migrateMacosSandboxData() async {
  if (!Platform.isMacOS) {
    return;
  }
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    return;
  }
  final srcDocs = Directory(
    p.join(
      home,
      'Library',
      'Containers',
      'com.openpendant.openpendant',
      'Data',
      'Documents',
    ),
  );
  final srcDb = File(p.join(srcDocs.path, 'openpendant.db'));
  if (!await srcDb.exists()) {
    return;
  }
  final destDocs = await getApplicationDocumentsDirectory();
  await destDocs.create(recursive: true);
  final destDb = File(p.join(destDocs.path, 'openpendant.db'));
  final srcSize = (await srcDb.stat()).size;
  final destSize =
      await destDb.exists() ? (await destDb.stat()).size : 0;
  if (srcSize > destSize) {
    await srcDb.copy(destDb.path);
    for (final extra in ['-wal', '-shm']) {
      final f = File('${srcDb.path}$extra');
      if (await f.exists()) {
        await f.copy('${destDb.path}$extra');
      }
    }
    await _mergeDir(
      Directory(p.join(srcDocs.path, 'clips')),
      Directory(p.join(destDocs.path, 'clips')),
    );
    await _mergeDir(
      Directory(p.join(srcDocs.path, 'voices')),
      Directory(p.join(destDocs.path, 'voices')),
    );
    final voices = File(p.join(srcDocs.path, 'voices.json'));
    if (await voices.exists()) {
      await voices.copy(p.join(destDocs.path, 'voices.json'));
    }
  }

  final srcSupport = Directory(
    p.join(
      home,
      'Library',
      'Containers',
      'com.openpendant.openpendant',
      'Data',
      'Library',
      'Application Support',
      'com.openpendant.openpendant',
    ),
  );
  if (!await srcSupport.exists()) {
    return;
  }
  final destSupport = await getApplicationSupportDirectory();
  await destSupport.create(recursive: true);
  await for (final e in srcSupport.list()) {
    if (e is! File) {
      continue;
    }
    final name = p.basename(e.path);
    final dest = File(p.join(destSupport.path, name));
    if (await dest.exists() && (await dest.stat()).size > 0) {
      continue;
    }
    await e.copy(dest.path);
  }
}

Future<void> _mergeDir(Directory src, Directory dest) async {
  if (!await src.exists()) {
    return;
  }
  await dest.create(recursive: true);
  await for (final e in src.list()) {
    if (e is! File) {
      continue;
    }
    final to = File(p.join(dest.path, p.basename(e.path)));
    if (await to.exists()) {
      continue;
    }
    await e.copy(to.path);
  }
}
