import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _storageKey = 'openai_api_key';

/// macOS debug Keychain often fails with -34018 (missing entitlement).
/// Desktop: file in app support. iOS/Android: Keychain/Keystore.
class ApiKeyStore {
  static const _secure = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock,
    ),
  );
  static String _cached = '';

  static bool get _useFile =>
      Platform.isMacOS || Platform.isLinux || Platform.isWindows;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'openai_api_key'));
  }

  static Future<String> read({bool refresh = false}) async {
    if (!refresh && _cached.isNotEmpty) {
      return _cached;
    }
    if (_useFile) {
      final f = await _file();
      if (!await f.exists()) {
        return '';
      }
      final value = (await f.readAsString()).trim();
      if (value.isNotEmpty) {
        _cached = value;
      }
      return value;
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      final value = ((await _secure.read(key: _storageKey)) ?? '').trim();
      if (value.isNotEmpty) {
        _cached = value;
        return value;
      }
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
    return _cached;
  }

  static Future<void> write(String value) async {
    final v = value.trim();
    _cached = v;
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
