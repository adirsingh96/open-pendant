import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class SttPrefs {
  static bool diarize = true;

  static Future<Directory> _dir() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _file() async {
    return File(p.join((await _dir()).path, 'stt_diarize'));
  }

  static Future<void> load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        diarize = (await f.readAsString()).trim() != '0';
        return;
      }
      final legacy = File(p.join((await _dir()).path, 'stt_provider'));
      if (await legacy.exists()) {
        final v = (await legacy.readAsString()).trim();
        diarize = v != 'saaras:v4';
        return;
      }
      diarize = true;
    } catch (_) {
      diarize = true;
    }
  }

  static Future<void> save({required bool diarize}) async {
    SttPrefs.diarize = diarize;
    final f = await _file();
    await f.writeAsString(diarize ? '1\n' : '0\n', flush: true);
  }
}
