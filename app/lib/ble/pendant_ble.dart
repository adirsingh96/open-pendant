import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'pcm_reassembler.dart';
import 'pendant_prefs.dart';

const pendantServiceUuid = '70301101-4a1b-4c8d-9e0f-a1b2c3d4e5f6';
const pcmCharUuid = '70301102-4a1b-4c8d-9e0f-a1b2c3d4e5f6';
const statusCharUuid = '70301103-4a1b-4c8d-9e0f-a1b2c3d4e5f6';
const controlCharUuid = '70301104-4a1b-4c8d-9e0f-a1b2c3d4e5f6';
const sdDataCharUuid = '70301105-4a1b-4c8d-9e0f-a1b2c3d4e5f6';

const sdCtrlList = 0x10;
const sdCtrlOpen = 0x11;
const sdCtrlRead = 0x12;
const sdCtrlDelete = 0x13;
const sdMsgList = 0x10;
const sdMsgRead = 0x12;
const sdMsgEnd = 0x1f;
const sdKindMeeting = 1;
const sdKindNote = 2;

String pendantClipIdHex(List<int> id) {
  final b = StringBuffer();
  for (final v in id) {
    b.write(v.toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

class SdPendingClip {
  SdPendingClip({
    required this.id,
    required this.kind,
    required this.size,
    required this.seq,
    required this.session,
  });

  final List<int> id;
  final int kind;
  final int size;
  final int seq;
  final String session;

  String get idHex => pendantClipIdHex(id);
  bool get isMeeting => kind == sdKindMeeting;
  bool get isNote => kind == sdKindNote;
}

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
    this.offlineRecording = false,
    this.sdResult = 0,
    this.sdDetail = 0,
    this.pendingSdCount = 0,
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
  final bool offlineRecording;
  final int sdResult;
  final int sdDetail;
  final int pendingSdCount;

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

  String get sdLabel {
    switch (sdResult) {
      case 1:
        return 'testing…';
      case 2:
        return 'pass (wrote + read /SD:/opentest.txt)';
      case 3:
        return 'fail: card init (detail $sdDetail)';
      case 4:
        return 'fail: FAT mount (format FAT32? detail $sdDetail)';
      case 5:
        return 'fail: write (detail $sdDetail)';
      case 6:
        return 'fail: read (detail $sdDetail)';
      case 7:
        return 'fail: data mismatch';
      default:
        return 'not run yet';
    }
  }

  bool get sdBusy => sdResult == 1;
  bool get sdPass => sdResult == 2;

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
      offlineRecording: (flags & 64) != 0,
      sdResult: data.length >= 10 ? data[8] : 0,
      sdDetail: data.length >= 10 ? data[9] : 0,
      pendingSdCount: data.length >= 12 ? (data[10] | (data[11] << 8)) : 0,
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
  BluetoothCharacteristic? _sdData;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<List<int>>? _statusSub;
  StreamSubscription<List<int>>? _sdDataSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  final PcmReassembler reassembler = PcmReassembler();
  void Function()? onConnectionLost;
  void Function(PendantStatus status)? onStatus;
  PendantStatus? lastStatus;
  bool _intentionalDisconnect = false;
  final _sdInbox = <List<int>>[];
  Completer<List<int>>? _sdWait;
  bool _sdSyncBusy = false;

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
    await _sdDataSub?.cancel();
    _sdDataSub = null;
    await d.connect(timeout: const Duration(seconds: 20));
    // Subscribe early so a drop during discovery is handled cleanly.
    _connSub = d.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _pcm = null;
        _sdData = null;
        if (!_intentionalDisconnect) {
          onConnectionLost?.call();
        }
      }
    });
    try {
      await d.requestMtu(247);
    } catch (_) {}
    final services = await d.discoverServices();
    _pcm = null;
    _status = null;
    _control = null;
    _sdData = null;
    for (final s in services) {
      for (final c in s.characteristics) {
        final id = c.uuid.str.toLowerCase().replaceAll('-', '');
        if (id == pcmCharUuid.replaceAll('-', '')) {
          _pcm = c;
        } else if (id == statusCharUuid.replaceAll('-', '')) {
          _status = c;
        } else if (id == controlCharUuid.replaceAll('-', '')) {
          _control = c;
        } else if (id == sdDataCharUuid.replaceAll('-', '')) {
          _sdData = c;
        }
      }
    }
    if (_pcm == null) {
      throw Exception('PCM characteristic not found');
    }
    await _listenStatus();
    // SD notify is optional — never block the link on it.
    unawaited(_listenSdData());
  }

  Future<void> _listenSdData() async {
    await _sdDataSub?.cancel();
    _sdInbox.clear();
    _sdWait = null;
    final c = _sdData;
    if (c == null) {
      return;
    }
    _sdDataSub = c.onValueReceived.listen(_onSdData);
    try {
      await c.setNotifyValue(true);
    } catch (_) {}
  }

  void _onSdData(List<int> data) {
    final wait = _sdWait;
    if (wait != null && !wait.isCompleted) {
      wait.complete(List<int>.from(data));
      _sdWait = null;
      return;
    }
    _sdInbox.add(List<int>.from(data));
  }

  /// Arm waiter before the control write so a fast notify is not dropped.
  Future<List<int>> _writeControlAwaitSd(
    List<int> payload, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (_sdInbox.isNotEmpty) {
      _sdInbox.clear();
    }
    final c = Completer<List<int>>();
    _sdWait = c;
    if (!await _writeControl(payload)) {
      if (identical(_sdWait, c)) {
        _sdWait = null;
      }
      throw Exception('Could not write SD control');
    }
    try {
      return await c.future.timeout(timeout);
    } on TimeoutException {
      if (identical(_sdWait, c)) {
        _sdWait = null;
      }
      throw Exception('SD sync timed out waiting for pendant data');
    }
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
      await _sdData?.setNotifyValue(false);
    } catch (_) {}
    try {
      await device?.disconnect();
    } catch (_) {}
    await _notifySub?.cancel();
    _notifySub = null;
    await _statusSub?.cancel();
    _statusSub = null;
    await _sdDataSub?.cancel();
    _sdDataSub = null;
    await _connSub?.cancel();
    _connSub = null;
    _pcm = null;
    _status = null;
    _control = null;
    _sdData = null;
    _sdInbox.clear();
    _sdWait = null;
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
    return _writeControl([on ? 1 : 0]);
  }

  /// Run the pendant SD card mount / write / read self-test.
  Future<bool> runSdTest() async {
    return _writeControl([2]);
  }

  /// List pending offline clips on the microSD (control 0x10 until END).
  Future<List<SdPendingClip>> listPendingSd() async {
    if (_sdData == null || _control == null) {
      throw Exception('SD sync characteristic missing — update firmware');
    }
    if (_sdSyncBusy) {
      throw Exception('SD sync already running');
    }
    _sdSyncBusy = true;
    _sdInbox.clear();
    try {
      await _listenSdData();
      final out = <SdPendingClip>[];
      for (var i = 0; i < 64; i++) {
        final pkt = await _writeControlAwaitSd([sdCtrlList]);
        if (pkt.isEmpty) {
          continue;
        }
        if (pkt[0] == sdMsgEnd) {
          break;
        }
        if (pkt[0] != sdMsgList || pkt.length < 16) {
          throw Exception('Unexpected SD list packet');
        }
        final kind = pkt[1];
        final id = pkt.sublist(2, 10);
        final size = pkt[10] |
            (pkt[11] << 8) |
            (pkt[12] << 16) |
            (pkt[13] << 24);
        final seq = pkt[14] | (pkt[15] << 8);
        var session = '';
        if (pkt.length > 16) {
          final end = pkt.length < 48 ? pkt.length : 48;
          final raw = pkt.sublist(16, end);
          final nul = raw.indexOf(0);
          session = String.fromCharCodes(nul < 0 ? raw : raw.sublist(0, nul));
        }
        out.add(
          SdPendingClip(
            id: id,
            kind: kind,
            size: size,
            seq: seq,
            session: session,
          ),
        );
      }
      return out;
    } finally {
      _sdSyncBusy = false;
    }
  }

  /// Pull one clip's raw PCM after [listPendingSd] / open.
  Future<List<int>> pullSdClip(List<int> id, {required int size}) async {
    if (id.length != 8) {
      throw Exception('SD clip id must be 8 bytes');
    }
    if (_sdData == null || _control == null) {
      throw Exception('SD sync characteristic missing — update firmware');
    }
    if (_sdSyncBusy) {
      throw Exception('SD sync already running');
    }
    _sdSyncBusy = true;
    _sdInbox.clear();
    try {
      await _listenSdData();
      if (!await _writeControl([sdCtrlOpen, ...id])) {
        throw Exception('Could not open SD clip');
      }
      final pcm = <int>[];
      var offset = 0;
      while (offset < size) {
        final want = (size - offset).clamp(0, 220);
        final payload = <int>[
          sdCtrlRead,
          offset & 0xff,
          (offset >> 8) & 0xff,
          (offset >> 16) & 0xff,
          (offset >> 24) & 0xff,
          want & 0xff,
          (want >> 8) & 0xff,
        ];
        final pkt = await _writeControlAwaitSd(payload);
        if (pkt.isEmpty || pkt[0] != sdMsgRead || pkt.length < 15) {
          throw Exception('Unexpected SD read packet');
        }
        final got = pkt[13] | (pkt[14] << 8);
        if (got == 0) {
          break;
        }
        if (pkt.length < 15 + got) {
          throw Exception('Truncated SD read packet');
        }
        pcm.addAll(pkt.sublist(15, 15 + got));
        offset += got;
      }
      return pcm;
    } finally {
      _sdSyncBusy = false;
    }
  }

  Future<bool> deleteSdClip(List<int> id) async {
    if (id.length != 8) {
      return false;
    }
    return _writeControl([sdCtrlDelete, ...id]);
  }

  Future<bool> _writeControl(List<int> payload) async {
    final c = _control;
    if (c == null) {
      return false;
    }
    try {
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
