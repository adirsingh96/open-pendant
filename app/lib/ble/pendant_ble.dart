import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'pcm_reassembler.dart';

const pendantServiceUuid = '70301101-4a1b-4c8d-9e0f-a1b2c3d4e5f6';
const pcmCharUuid = '70301102-4a1b-4c8d-9e0f-a1b2c3d4e5f6';
const statusCharUuid = '70301103-4a1b-4c8d-9e0f-a1b2c3d4e5f6';

class PendantStatus {
  PendantStatus({
    required this.imuSleep,
    required this.micRunning,
    required this.imuReady,
    required this.imuFetchOk,
    required this.volume,
    required this.stillHits,
    required this.updatedAt,
  });

  final bool imuSleep;
  final bool micRunning;
  final bool imuReady;
  final bool imuFetchOk;
  final int volume;
  final int stillHits;
  final DateTime updatedAt;

  static PendantStatus? parse(List<int> data) {
    if (data.length < 4) {
      return null;
    }
    final flags = data[0];
    final volume = data[1] | (data[2] << 8);
    return PendantStatus(
      imuSleep: (flags & 1) != 0,
      micRunning: (flags & 2) != 0,
      imuReady: (flags & 4) != 0,
      imuFetchOk: (flags & 8) != 0,
      volume: volume,
      stillHits: data[3],
      updatedAt: DateTime.now(),
    );
  }
}

bool isPendantName(String? name) {
  final n = (name ?? '').toLowerCase();
  return n == 'openpendant' || n == 'ai pendant' || n.contains('pendant');
}

class PendantBle {
  BluetoothDevice? device;
  BluetoothCharacteristic? _pcm;
  BluetoothCharacteristic? _status;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<List<int>>? _statusSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  final PcmReassembler reassembler = PcmReassembler();
  void Function()? onConnectionLost;
  void Function(PendantStatus status)? onStatus;
  PendantStatus? lastStatus;
  bool _intentionalDisconnect = false;

  Future<BluetoothDevice?> findExisting() async {
    bool match(BluetoothDevice d) =>
        isPendantName(d.platformName) || isPendantName(d.advName);

    for (final d in FlutterBluePlus.connectedDevices) {
      if (match(d)) {
        return d;
      }
    }
    try {
      final sys = await FlutterBluePlus.systemDevices([
        Guid(pendantServiceUuid),
      ]);
      for (final d in sys) {
        if (match(d)) {
          return d;
        }
      }
      if (sys.length == 1) {
        return sys.first;
      }
    } catch (_) {}
    return null;
  }

  Future<BluetoothDevice> scan({Duration timeout = const Duration(seconds: 20)}) async {
    final existing = await findExisting();
    if (existing != null) {
      return existing;
    }
    BluetoothDevice? found;
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName;
        final uuids = r.advertisementData.serviceUuids
            .map((g) => g.str.toLowerCase())
            .toList();
        if (isPendantName(name) || uuids.contains(pendantServiceUuid)) {
          found = r.device;
          FlutterBluePlus.stopScan();
        }
      }
    });
    await FlutterBluePlus.startScan(timeout: timeout);
    await FlutterBluePlus.isScanning.where((v) => v == false).first;
    await sub.cancel();
    if (found == null) {
      throw Exception(
        'Did not find OpenPendant. It allows one BLE link — quit nRF Connect, '
        'or tap Connect again if macOS still holds the last session.',
      );
    }
    return found!;
  }

  Future<void> connect(BluetoothDevice d) async {
    _intentionalDisconnect = false;
    device = d;
    await _connSub?.cancel();
    await d.connect(timeout: const Duration(seconds: 20));
    try {
      await d.requestMtu(247);
    } catch (_) {}
    final services = await d.discoverServices();
    _pcm = null;
    _status = null;
    for (final s in services) {
      for (final c in s.characteristics) {
        final id = c.uuid.str.toLowerCase();
        if (id == pcmCharUuid) {
          _pcm = c;
        }
        if (id == statusCharUuid) {
          _status = c;
        }
      }
    }
    if (_pcm == null) {
      throw Exception('PCM characteristic not found');
    }
    await _listenStatus();
    // Subscribe after connect so the initial "disconnected" event is ignored.
    _connSub = d.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _pcm = null;
        if (!_intentionalDisconnect) {
          onConnectionLost?.call();
        }
      }
    });
  }

  Future<void> _listenStatus() async {
    await _statusSub?.cancel();
    final c = _status;
    if (c == null) {
      return;
    }
    _statusSub = c.onValueReceived.listen((data) {
      final parsed = PendantStatus.parse(data);
      if (parsed != null) {
        lastStatus = parsed;
        onStatus?.call(parsed);
      }
    });
    try {
      await c.setNotifyValue(true);
      final first = await c.read();
      final parsed = PendantStatus.parse(first);
      if (parsed != null) {
        lastStatus = parsed;
        onStatus?.call(parsed);
      }
    } catch (_) {}
  }

  Future<void> reconnect() async {
    final existing = await findExisting();
    if (existing != null) {
      await connect(existing);
      return;
    }
    final last = device;
    if (last != null) {
      try {
        await connect(last);
        return;
      } catch (_) {}
    }
    final scanned = await scan(timeout: const Duration(seconds: 15));
    await connect(scanned);
  }

  Future<void> startRecording(void Function() onPacket) async {
    final c = _pcm;
    if (c == null) {
      throw Exception('Not connected');
    }
    reassembler.reset();
    await _notifySub?.cancel();
    _notifySub = c.onValueReceived.listen((data) {
      reassembler.addNotify(data);
      onPacket();
    });
    await c.setNotifyValue(true);
  }

  Future<void> stopRecording() async {
    try {
      await _pcm?.setNotifyValue(false);
    } catch (_) {}
    await _notifySub?.cancel();
    _notifySub = null;
  }

  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    await stopRecording();
    try {
      await _status?.setNotifyValue(false);
    } catch (_) {}
    try {
      await device?.disconnect();
    } catch (_) {}
    await _notifySub?.cancel();
    _notifySub = null;
    await _statusSub?.cancel();
    _statusSub = null;
    await _connSub?.cancel();
    _connSub = null;
    _pcm = null;
    _status = null;
    lastStatus = null;
  }
}
