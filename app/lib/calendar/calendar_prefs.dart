import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class CalendarPrefs {
  static bool enabled = false;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'calendar_notes'));
  }

  static Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) {
        enabled = false;
        return;
      }
      enabled = (await f.readAsString()).trim() == '1';
    } catch (_) {
      enabled = false;
    }
  }

  static Future<void> save({required bool on}) async {
    enabled = on;
    final f = await _file();
    await f.writeAsString(on ? '1\n' : '0\n', flush: true);
  }
}
