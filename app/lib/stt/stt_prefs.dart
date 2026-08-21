import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class SttPrefs {
  static const openai = 'openai';
  static const saarasV4 = 'saaras:v4';
  static const both = 'both';

  static String provider = openai;

  static bool get useSaarasOnly => provider == saarasV4;

  static bool get useBoth => provider == both;

  static bool get useSaaras => useSaarasOnly || useBoth;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'stt_provider'));
  }

  static Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) {
        provider = openai;
        return;
      }
      final v = (await f.readAsString()).trim();
      if (v == saarasV4 || v == both) {
        provider = v;
      } else {
        provider = openai;
      }
    } catch (_) {
      provider = openai;
    }
  }

  static Future<void> save(String value) async {
    if (value == saarasV4 || value == both) {
      provider = value;
    } else {
      provider = openai;
    }
    final f = await _file();
    await f.writeAsString('$provider\n', flush: true);
  }
}
