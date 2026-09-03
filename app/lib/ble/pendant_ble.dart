import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'pcm_reassembler.dart';
import 'pendant_prefs.dart';

const pendantServiceUuid = '70301101-4a1b-4c8d-9e0f-a1b2c3d4e5f6';
const pcmCharUuid = '70301102-4a1b-4c8d-9e0f-a1b2c3d4e5f6';
const statusCharUuid = '70301103-4a1b-4c8d-9e0f-a1b2c3d4e5f6';
const controlCharUuid = '70301104-4a1b-4c8d-9e0f-a1b2c3d4e5f6';

class PendantStatus {
  PendantStatus({
    required this.imuSleep,
    required this.micRunning,
    required this.imuReady,
    required this.imuFetchOk,
    required this.volume,
    required this.stillHits,
    required this.batteryMv,
    required this.usbPowered,
    required this.updatedAt,
    this.buttonEvent = 0,
    this.buttonSeq = 0,
    this.noteHeld = false,
  });

  final bool imuSleep;
  final bool micRunning;
  final bool imuReady;
  final bool imuFetchOk;
  final int volume;
  final int stillHits;
  final int? batteryMv;
  final bool usbPowered;
  final DateTime updatedAt;
  final int buttonEvent;
  final int buttonSeq;
  final bool noteHeld;

  String get buttonLabel {
    switch (buttonEvent) {
      case 1:
        return 'single press';
      case 2:
        return 'double press';
      case 3:
        return 'long press';
      case 4:
        return 'long release';
      default:
        return 'none';
    }
  }

  /// Resting 1S LiPo estimate. Invalid on USB — the charger rail is ~4.1 V
  /// even with no cell attached.
  int? get batteryPct {
    if (usbPowered) {
      return null;
    }
    final mv = batteryMv;
    if (mv == null || mv < 2800) {
      return null;
    }
    const points = <List<int>>[
      [4200, 100],
      [4110, 90],
      [4000, 80],
      [3920, 70],
      [3840, 60],
      [3760, 50],
      [3690, 40],
      [3620, 30],
      [3560, 20],
      [3480, 10],
      [3400, 5],
      [3300, 0],
    ];
    if (mv >= points.first[0]) {
      return 100;
    }
    if (mv <= points.last[0]) {
      return 0;
    }
    for (var i = 0; i < points.length - 1; i++) {
      final hi = points[i];
      final lo = points[i + 1];
      if (mv <= hi[0] && mv >= lo[0]) {
        final t = (mv - lo[0]) / (hi[0] - lo[0]);
        return (lo[1] + t * (hi[1] - lo[1])).round();
      }
    }
    return 0;
  }

  static PendantStatus? parse(List<int> data) {
    if (data.length < 4) {
      return null;
    }
    final flags = data[0];
    final volume = data[1] | (data[2] << 8);
    int? batteryMv;
    if (data.length >= 6) {
      batteryMv = data[4] | (data[5] << 8);
    }
    return PendantStatus(
      imuSleep: (flags & 1) != 0,
      micRunning: (flags & 2) != 0,
      imuReady: (flags & 4) != 0,
      imuFetchOk: (flags & 8) != 0,
      volume: volume,
      stillHits: data[3],
      batteryMv: batteryMv,
      usbPowered: (flags & 16) != 0,
      updatedAt: DateTime.now(),
      buttonEvent: data.length >= 8 ? data[6] : 0,
      buttonSeq: data.length >= 8 ? data[7] : 0,
      noteHeld: (flags & 32) != 0,
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
  BluetoothCharacteristic? _control;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<List<int>>? _statusSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  final PcmReassembler reassembler = PcmReassembler();
  void Function()? onConnectionLost;
  void Function(PendantStatus status)? onStatus;
  PendantStatus? lastStatus;
  bool _intentionalDisconnect = false;

  /// Starts CoreBluetooth so the first Connect tap is not racing adapter init.
  void warmup() {
    _adapterSub ??= FlutterBluePlus.adapterState.listen((_) {});
  }

  Future<void> waitForAdapter({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    warmup();
    if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on) {
      return;
    }
    try {
      await FlutterBluePlus.adapterState
          .firstWhere((s) => s == BluetoothAdapterState.on)
          .timeout(timeout);
    } on TimeoutException {
      switch (FlutterBluePlus.adapterStateNow) {
        case BluetoothAdapterState.off:
          throw Exception('Turn Bluetooth on, then tap Connect pendant.');
        case BluetoothAdapterState.unauthorized:
          throw Exception(
            'Allow Bluetooth for OpenPendant, then tap Connect pendant.',
          );
        default:
          throw Exception(
            'Bluetooth is still starting. Tap Connect pendant again.',
          );
      }
    }
  }

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

  Future<BluetoothDevice> scan(
      {Duration timeout = const Duration(seconds: 20)}) async {
    await waitForAdapter();
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
    try {
      await FlutterBluePlus.startScan(timeout: timeout);
    } catch (e) {
      if (!_adapterNotReady(e)) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await waitForAdapter();
      await FlutterBluePlus.startScan(timeout: timeout);
    }
    await FlutterBluePlus.isScanning.where((v) => v == false).first;
    await sub.cancel();
    if (found == null) {
      throw Exception(
        'Did not find your pendant. Make sure it is nearby and that no other '
        'app is holding its Bluetooth link, then try again.',
      );
    }
    return found!;
  }

  static bool _adapterNotReady(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('bluetooth must be turned on') ||
        s.contains('cbmanagerstate') ||
        s.contains('adapter is off');
  }

  Future<void> connect(BluetoothDevice d) async {
    await waitForAdapter();
    _intentionalDisconnect = false;
    device = d;
    await PendantPrefs.markSeen(
      deviceName: d.platformName,
      remoteId: d.remoteId.str,
    );
    await _connSub?.cancel();
    await d.connect(timeout: const Duration(seconds: 20));
    try {
      await d.requestMtu(247);
    } catch (_) {}
    final services = await d.discoverServices();
    _pcm = null;
    _status = null;
    _control = null;
    for (final s in services) {
      for (final c in s.characteristics) {
        final id = c.uuid.str.toLowerCase();
        if (id == pcmCharUuid) {
          _pcm = c;
        }
        if (id == statusCharUuid) {
          _status = c;
        }
        if (id == controlCharUuid) {
          _control = c;
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

  /// Reattach GATT if iOS/Android still holds the pendant after a process
  /// restore. Does not scan.
  Future<void> adoptExisting() async {
    await waitForAdapter();
    final d = await _knownDevice();
    if (d == null || !d.isConnected) {
      throw Exception('No restored pendant');
    }
    await connect(d);
  }

  /// Reconnect a previously paired pendant without scanning (works while the
  /// phone is locked; iOS forbids background scans).
  Future<void> reconnectKnown() async {
    await waitForAdapter();
    final d = await _knownDevice();
    if (d == null) {
      throw Exception('No known pendant to reconnect');
    }
    await connect(d);
  }

  Future<BluetoothDevice?> _knownDevice() async {
    final existing = await findExisting();
    if (existing != null) {
      return existing;
    }
    final last = device;
    if (last != null) {
      return last;
    }
    final id = PendantPrefs.remoteId.trim();
    if (id.isNotEmpty) {
      return BluetoothDevice.fromId(id);
    }
    return null;
  }

  Future<void> reconnect() async {
    try {
      await reconnectKnown();
      return;
    } catch (_) {}
    final scanned = await scan(timeout: const Duration(seconds: 15));
    await connect(scanned);
  }

  bool get isCapturing => _notifySub != null;

  Future<void> startRecording(void Function() onPacket) async {
    final c = _pcm;
    if (c == null) {
      throw Exception('Not connected');
    }
    reassembler.reset();
    try {
      await device?.requestMtu(247);
    } catch (_) {}
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
    _control = null;
    lastStatus = null;
  }

  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  bool get isConnected {
    final d = device;
    return d != null && d.isConnected;
  }

  /// Flash the board LEDs (needs firmware with the control characteristic).
  Future<bool> setLocate(bool on) async {
    final c = _control;
    if (c == null) {
      return false;
    }
    try {
      final payload = [on ? 1 : 0];
      if (c.properties.writeWithoutResponse) {
        await c.write(payload, withoutResponse: true);
      } else {
        await c.write(payload);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<int?> readRssi() async {
    final d = device;
    if (d == null || !d.isConnected) {
      return null;
    }
    try {
      return await d.readRssi();
    } catch (_) {
      return null;
    }
  }

  bool _isPendantResult(ScanResult r) {
    final name = r.advertisementData.advName.isNotEmpty
        ? r.advertisementData.advName
        : r.device.platformName;
    final uuids = r.advertisementData.serviceUuids
        .map((g) => g.str.toLowerCase())
        .toList();
    return isPendantName(name) || uuids.contains(pendantServiceUuid);
  }

  /// Live advertisement RSSI while the pendant is not connected.
  Future<StreamSubscription<List<ScanResult>>> listenScanRssi(
    void Function(int rssi) onRssi,
  ) async {
    await stopScan();
    final sub = FlutterBluePlus.scanResults.listen((results) {
      int? best;
      for (final r in results) {
        if (!_isPendantResult(r)) {
          continue;
        }
        if (best == null || r.rssi > best) {
          best = r.rssi;
        }
      }
      if (best != null) {
        onRssi(best);
      }
    });
    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 40),
      continuousUpdates: true,
      androidScanMode: AndroidScanMode.lowLatency,
    );
    return sub;
  }
}
