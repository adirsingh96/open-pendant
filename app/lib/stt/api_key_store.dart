import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _storageKey = 'openai_api_key';

/// macOS debug Keychain often fails with -34018 (missing entitlement).
/// Desktop: file in app support. iOS/Android: Keychain/Keystore.
class ApiKeyStore {
  static const _secure = FlutterSecureStorage();

  static bool get _useFile =>
      Platform.isMacOS || Platform.isLinux || Platform.isWindows;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'openai_api_key'));
  }

  static Future<String> read() async {
    if (_useFile) {
      final f = await _file();
      if (!await f.exists()) {
        return '';
      }
      return (await f.readAsString()).trim();
    }
    return ((await _secure.read(key: _storageKey)) ?? '').trim();
  }

  static Future<void> write(String value) async {
    final v = value.trim();
    if (_useFile) {
      final f = await _file();
      await f.writeAsString(v, flush: true);
      try {
        await Process.run('chmod', ['600', f.path]);
      } catch (_) {}
      return;
    }
    await _secure.write(key: _storageKey, value: v);
  }
}
