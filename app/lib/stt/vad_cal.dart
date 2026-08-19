import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../audio/speech_vad.dart';

class VadCal {
  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'vad_energy_floor'));
  }

  static Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) {
        VadGate.energyFloor = VadGate.defaultEnergyFloor;
        VadGate.calibratedAt = null;
        return;
      }
      final lines = (await f.readAsString()).trim().split('\n');
      if (lines.isEmpty) {
        return;
      }
      VadGate.energyFloor = double.parse(lines.first.trim());
      if (lines.length > 1 && lines[1].trim().isNotEmpty) {
        VadGate.calibratedAt = DateTime.tryParse(lines[1].trim());
      } else {
        VadGate.calibratedAt = DateTime.now().toUtc();
      }
    } catch (_) {
      VadGate.energyFloor = VadGate.defaultEnergyFloor;
      VadGate.calibratedAt = null;
    }
  }

  static Future<void> save(double floor) async {
    VadGate.energyFloor = floor;
    VadGate.calibratedAt = DateTime.now().toUtc();
    final f = await _file();
    await f.writeAsString(
      '${floor.toStringAsExponential(6)}\n${VadGate.calibratedAt!.toIso8601String()}\n',
      flush: true,
    );
  }

  static Future<void> clear() async {
    VadGate.energyFloor = VadGate.defaultEnergyFloor;
    VadGate.calibratedAt = null;
    final f = await _file();
    if (await f.exists()) {
      await f.delete();
    }
  }

  static String statusLine() {
    if (VadGate.calibratedAt == null) {
      return 'VAD: default (calibrate while wearing the pendant)';
    }
    final when = VadGate.calibratedAt!.toLocal();
    return 'VAD: calibrated '
        '${when.month}/${when.day} ${when.hour.toString().padLeft(2, '0')}:'
        '${when.minute.toString().padLeft(2, '0')}';
  }
}
