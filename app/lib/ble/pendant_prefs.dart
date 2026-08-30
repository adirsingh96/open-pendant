import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Remembers that a pendant has been paired before, so the UI can tell
/// "never set up" apart from "paired but offline", and show last-seen time.
class PendantPrefs {
  static bool paired = false;
  static String name = 'Pendant';
  static DateTime? lastSeen;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'pendant_pairing'));
  }

  static Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) {
        return;
      }
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
    } catch (_) {}
  }

  static Future<void> markSeen({String? deviceName}) async {
    paired = true;
    if (deviceName != null && deviceName.trim().isNotEmpty) {
      name = deviceName.trim();
    }
    lastSeen = DateTime.now();
    try {
      final f = await _file();
      await f.writeAsString(
        '1|$name|${lastSeen!.millisecondsSinceEpoch}\n',
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
