import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum SttEngine { saaras, local }

class SttPrefs {
  static bool diarize = true;
  static SttEngine engine = SttEngine.saaras;

  static Future<Directory> _dir() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _diarizeFile() async {
    return File(p.join((await _dir()).path, 'stt_diarize'));
  }

  static Future<File> _engineFile() async {
    return File(p.join((await _dir()).path, 'stt_engine'));
  }

  static Future<void> load() async {
    try {
      final f = await _diarizeFile();
      if (await f.exists()) {
        diarize = (await f.readAsString()).trim() != '0';
      } else {
        final legacy = File(p.join((await _dir()).path, 'stt_provider'));
        if (await legacy.exists()) {
          final v = (await legacy.readAsString()).trim();
          diarize = v != 'saaras:v4';
        } else {
          diarize = true;
        }
      }
    } catch (_) {
      diarize = true;
    }
    try {
      final f = await _engineFile();
      if (await f.exists()) {
        engine = (await f.readAsString()).trim() == 'local'
            ? SttEngine.local
            : SttEngine.saaras;
      } else {
        engine = SttEngine.saaras;
      }
    } catch (_) {
      engine = SttEngine.saaras;
    }
  }

  static Future<void> save({bool? diarize, SttEngine? engine}) async {
    if (diarize != null) {
      SttPrefs.diarize = diarize;
    }
    if (engine != null) {
      SttPrefs.engine = engine;
    }
    final df = await _diarizeFile();
    await df.writeAsString(SttPrefs.diarize ? '1\n' : '0\n', flush: true);
    final ef = await _engineFile();
    await ef.writeAsString(
      SttPrefs.engine == SttEngine.local ? 'local\n' : 'saaras\n',
      flush: true,
    );
  }
}
