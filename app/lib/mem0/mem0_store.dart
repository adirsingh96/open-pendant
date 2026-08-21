import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Mem0 hobby key + stable user_id for this install.
class Mem0Store {
  static const _keyName = 'mem0_api_key';
  static const _secure = FlutterSecureStorage();

  static bool get _useFile =>
      Platform.isMacOS || Platform.isLinux || Platform.isWindows;

  static Future<Directory> _dir() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _keyFile() async {
    return File(p.join((await _dir()).path, 'mem0_api_key'));
  }

  static Future<File> _userFile() async {
    return File(p.join((await _dir()).path, 'mem0_user_id'));
  }

  static Future<String> readKey() async {
    if (_useFile) {
      final f = await _keyFile();
      if (!await f.exists()) {
        return '';
      }
      return (await f.readAsString()).trim();
    }
    return ((await _secure.read(key: _keyName)) ?? '').trim();
  }

  static Future<void> writeKey(String value) async {
    final v = value.trim();
    if (_useFile) {
      final f = await _keyFile();
      await f.writeAsString(v, flush: true);
      try {
        await Process.run('chmod', ['600', f.path]);
      } catch (_) {}
      return;
    }
    await _secure.write(key: _keyName, value: v);
  }

  static Future<String> userId() async {
    final f = await _userFile();
    if (await f.exists()) {
      final id = (await f.readAsString()).trim();
      if (id.isNotEmpty) {
        return id;
      }
    }
    final id = const Uuid().v4();
    await f.writeAsString('$id\n', flush: true);
    return id;
  }

  static Future<File> _syncedFile() async {
    return File(p.join((await _dir()).path, 'mem0_synced_days'));
  }

  static String recapMark(String dayKey, DateTime? updatedAt) {
    return '$dayKey@${updatedAt?.toUtc().toIso8601String() ?? ''}';
  }

  static Future<bool> wasSynced(String mark) async {
    final f = await _syncedFile();
    if (!await f.exists()) {
      return false;
    }
    final lines = (await f.readAsString()).split('\n');
    return lines.map((e) => e.trim()).contains(mark);
  }

  static Future<void> markSynced(String mark) async {
    if (mark.isEmpty) {
      return;
    }
    if (await wasSynced(mark)) {
      return;
    }
    final f = await _syncedFile();
    await f.writeAsString('$mark\n', mode: FileMode.append, flush: true);
  }
}
