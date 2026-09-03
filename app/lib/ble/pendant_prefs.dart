import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Remembers that a pendant has been paired before, so the UI can tell
/// "never set up" apart from "paired but offline", and show last-seen time.
class PendantPrefs {
  static bool paired = false;
  static String name = 'Pendant';
  static DateTime? lastSeen;
  static bool autoConnect = false;
  static String remoteId = '';

  static Future<Directory> _dir() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _file() async {
    return File(p.join((await _dir()).path, 'pendant_pairing'));
  }

  static Future<File> _autoFile() async {
    return File(p.join((await _dir()).path, 'pendant_auto_connect'));
  }

  static Future<void> load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final parts = (await f.readAsString()).trim().split('|');
        paired = parts.isNotEmpty && parts[0] == '1';
        if (parts.length > 1 && parts[1].isNotEmpty) {
          name = parts[1];
        }
        if (parts.length > 2) {
          final ms = int.tryParse(parts[2]);
          if (ms != null && ms > 0) {
            lastSeen = DateTime.fromMillisecondsSinceEpoch(ms);
          }
        }
        if (parts.length > 3 && parts[3].trim().isNotEmpty) {
          remoteId = parts[3].trim();
        }
      }
    } catch (_) {}
    try {
      final af = await _autoFile();
      if (await af.exists()) {
        autoConnect = (await af.readAsString()).trim() == '1';
      } else {
        autoConnect = false;
      }
    } catch (_) {
      autoConnect = false;
    }
  }

  static Future<void> saveAutoConnect({required bool on}) async {
    autoConnect = on;
    final f = await _autoFile();
    await f.writeAsString(on ? '1\n' : '0\n', flush: true);
  }

  static Future<void> markSeen({String? deviceName, String? remoteId}) async {
    paired = true;
    if (deviceName != null && deviceName.trim().isNotEmpty) {
      name = deviceName.trim();
    }
    if (remoteId != null && remoteId.trim().isNotEmpty) {
      PendantPrefs.remoteId = remoteId.trim();
    }
    lastSeen = DateTime.now();
    try {
      final f = await _file();
      await f.writeAsString(
        '1|$name|${lastSeen!.millisecondsSinceEpoch}|${PendantPrefs.remoteId}\n',
        flush: true,
      );
    } catch (_) {}
  }

  /// "just now", "5m ago", "2h ago", "3d ago".
  static String lastSeenLabel() {
    final t = lastSeen;
    if (t == null) {
      return '';
    }
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) {
      return 'just now';
    }
    if (d.inHours < 1) {
      return '${d.inMinutes}m ago';
    }
    if (d.inDays < 1) {
      return '${d.inHours}h ago';
    }
    return '${d.inDays}d ago';
  }
}
