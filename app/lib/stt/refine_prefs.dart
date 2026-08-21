import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class RefinePrefs {
  static bool enabled = true;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'clean_transcripts'));
  }

  static Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) {
        enabled = true;
        return;
      }
      enabled = (await f.readAsString()).trim() != '0';
    } catch (_) {
      enabled = true;
    }
  }

  static Future<void> save(bool on) async {
    enabled = on;
    final f = await _file();
    await f.writeAsString(on ? '1\n' : '0\n', flush: true);
  }
}
