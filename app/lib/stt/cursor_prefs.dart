import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class CursorPrefs {
  static bool enabled = false;
  static bool pasteIntoCursor = true;
  static bool autoSend = true;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'cursor_commands'));
  }

  static Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) {
        enabled = false;
        pasteIntoCursor = true;
        autoSend = true;
        return;
      }
      final lines = (await f.readAsString()).split('\n');
      enabled = lines.isNotEmpty && lines[0].trim() == '1';
      pasteIntoCursor = lines.length < 2 || lines[1].trim() != '0';
      autoSend = lines.length < 3 || lines[2].trim() != '0';
    } catch (_) {
      enabled = false;
      pasteIntoCursor = true;
      autoSend = true;
    }
  }

  static Future<void> save({
    required bool on,
    required bool paste,
    required bool send,
  }) async {
    enabled = on;
    pasteIntoCursor = paste;
    autoSend = send;
    final f = await _file();
    await f.writeAsString(
      '${on ? 1 : 0}\n${paste ? 1 : 0}\n${send ? 1 : 0}\n',
      flush: true,
    );
  }
}
