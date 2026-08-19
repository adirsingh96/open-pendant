import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class VoiceProfile {
  VoiceProfile({
    required this.id,
    required this.name,
    required this.wavPath,
  });

  final String id;
  final String name;
  final String wavPath;

  Map<String, String> toJson() => {
        'id': id,
        'name': name,
        'wavPath': wavPath,
      };

  factory VoiceProfile.fromJson(Map<String, dynamic> json) {
    return VoiceProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      wavPath: json['wavPath'] as String,
    );
  }
}

class VoiceStore {
  static const maxVoices = 4;

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, 'voices.json'));
  }

  static Future<Directory> _wavDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(dir.path, 'voices'));
    await d.create(recursive: true);
    return d;
  }

  static String sanitizeName(String raw) {
    var n = raw.trim();
    n = n.replaceAll(RegExp(r'[\r\n<>]'), '');
    if (n.length > 40) {
      n = n.substring(0, 40);
    }
    return n;
  }

  static Future<List<VoiceProfile>> list() async {
    final f = await _file();
    if (!await f.exists()) {
      return [];
    }
    final decoded = jsonDecode(await f.readAsString());
    if (decoded is! List) {
      return [];
    }
    return decoded
        .map((e) => VoiceProfile.fromJson(Map<String, dynamic>.from(e as Map)))
        .where((v) => File(v.wavPath).existsSync())
        .toList();
  }

  static Future<void> _write(List<VoiceProfile> voices) async {
    final f = await _file();
    await f.writeAsString(
      jsonEncode(voices.map((v) => v.toJson()).toList()),
      flush: true,
    );
  }

  static Future<VoiceProfile> add({
    required String name,
    required List<int> wavBytes,
  }) async {
    final clean = sanitizeName(name);
    if (clean.isEmpty) {
      throw Exception('Name cannot be empty');
    }
    final voices = await list();
    if (voices.length >= maxVoices) {
      throw Exception('At most $maxVoices named voices');
    }
    if (voices.any((v) => v.name.toLowerCase() == clean.toLowerCase())) {
      throw Exception('That name is already used');
    }
    final id = const Uuid().v4();
    final dir = await _wavDir();
    final wavPath = p.join(dir.path, '$id.wav');
    await File(wavPath).writeAsBytes(wavBytes, flush: true);
    final profile = VoiceProfile(id: id, name: clean, wavPath: wavPath);
    voices.add(profile);
    await _write(voices);
    return profile;
  }

  static Future<void> remove(String id) async {
    final voices = await list();
    VoiceProfile? gone;
    final kept = <VoiceProfile>[];
    for (final v in voices) {
      if (v.id == id) {
        gone = v;
      } else {
        kept.add(v);
      }
    }
    if (gone != null) {
      try {
        await File(gone.wavPath).delete();
      } catch (_) {}
    }
    await _write(kept);
  }

  static Future<String> dataUrl(VoiceProfile voice) async {
    final bytes = await File(voice.wavPath).readAsBytes();
    return 'data:audio/wav;base64,${base64Encode(bytes)}';
  }
}
