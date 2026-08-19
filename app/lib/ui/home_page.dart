import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../audio/speech_vad.dart';
import '../audio/wav_writer.dart';
import '../ble/pendant_ble.dart';
import '../db/clip_store.dart';
import '../db/models.dart';
import '../stt/api_key_store.dart';
import '../stt/openai_stt.dart';
import '../stt/stt_pricing.dart';
import 'clip_page.dart';
import 'calibrate_page.dart';
import 'settings_page.dart';
import 'voices_page.dart';
import '../stt/vad_cal.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _maxChunkBytes = 30 * 16000 * 2;
  static const _quietRotate = Duration(seconds: 8);
  static const _noPcmRotate = Duration(seconds: 2);

  AppLifecycleListener? _lifecycle;
  Timer? _armTick;
  final _ble = PendantBle();
  final _store = ClipStore();
  final _stt = OpenAiStt();
  final _search = TextEditingController();
  final _liveScroll = ScrollController();

  String _status = 'Disconnected. Force-quit nRF Connect first.';
  bool _busy = false;
  bool _connected = false;
  bool _armed = false;
  bool _rotating = false;
  DateTime? _chunkStartedAt;
  DateTime? _lastSpeechAt;
  DateTime? _lastPcmAt;
  bool _hadSpeechInChunk = false;
  bool _imuWasSleep = false;
  bool _autoReconnect = false;
  bool _resumeAfterReconnect = false;
  PendantStatus? _dbg;
  int _bytes = 0;
  String? _sessionId;
  int _seq = 0;
  final _sttQueue = <ClipRecord>[];
  bool _sttBusy = false;
  List<Object> _homeItems = [];
  List<TranscriptSegment> _rangeSegs = [];
  DateTime? _rangeFrom;
  DateTime? _rangeTo;
  String _liveTranscript = '';
  double _totalCostUsd = 0;
  double _totalBilledS = 0;
  int _totalInTok = 0;
  int _totalOutTok = 0;

  @override
  void initState() {
    super.initState();
    _ble.onConnectionLost = _onConnectionLost;
    _ble.onStatus = _onPendantStatus;
    VadCal.load().then((_) {
      if (mounted) {
        setState(() {});
      }
    });
    _reload();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await _ble.disconnect();
        return AppExitResponse.exit;
      },
      onDetach: () {
        _ble.disconnect();
      },
    );
  }

  @override
  void dispose() {
    _armTick?.cancel();
    _lifecycle?.dispose();
    _search.dispose();
    _liveScroll.dispose();
    _ble.disconnect();
    super.dispose();
  }

  void _onPendantStatus(PendantStatus s) {
    if (!mounted) {
      return;
    }
    final wasSleep = _imuWasSleep;
    _imuWasSleep = s.imuSleep;
    setState(() => _dbg = s);
    if (!_armed) {
      return;
    }
    if (s.imuSleep && !wasSleep) {
      Future.microtask(() => _rotateChunk());
    } else if (!s.imuSleep && wasSleep) {
      _chunkStartedAt = DateTime.now().toUtc();
      _lastSpeechAt = DateTime.now();
      _hadSpeechInChunk = false;
      _refreshArmedStatus();
    }
  }

  Future<void> _reload() async {
    final cost = await _store.totalCostUsd();
    final usage = await _store.totalUsage();
    if (_rangeFrom != null && _rangeTo != null) {
      final segs = await _store.listSegmentsInRange(
        from: _rangeFrom!,
        to: _rangeTo!,
        query: _search.text,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _rangeSegs = segs;
        _liveTranscript = segs.map((s) => s.labeledText).where((t) => t.isNotEmpty).join(' ');
        _totalCostUsd = cost;
        _totalBilledS = usage.billedS;
        _totalInTok = usage.inputTokens;
        _totalOutTok = usage.outputTokens;
      });
      _scrollLiveToEnd();
      return;
    }
    final items = await _store.listHome(query: _search.text);
    var live = '';
    if (_sessionId != null) {
      for (final item in items) {
        if (item is SessionGroup && item.sessionId == _sessionId) {
          live = item.fullText;
          break;
        }
      }
    } else if (items.isNotEmpty) {
      final first = items.first;
      live = first is SessionGroup ? first.fullText : (first as ClipRecord).fullText;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _homeItems = items;
      _liveTranscript = live;
      _totalCostUsd = cost;
      _totalBilledS = usage.billedS;
      _totalInTok = usage.inputTokens;
      _totalOutTok = usage.outputTokens;
    });
    _scrollLiveToEnd();
  }

  void _scrollLiveToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_liveScroll.hasClients) {
        return;
      }
      _liveScroll.jumpTo(_liveScroll.position.maxScrollExtent);
    });
  }

  Future<bool> _blePerms() async {
    if (Platform.isAndroid) {
      final scan = await Permission.bluetoothScan.request();
      final connect = await Permission.bluetoothConnect.request();
      final loc = await Permission.locationWhenInUse.request();
      return scan.isGranted && connect.isGranted && loc.isGranted;
    }
    return true;
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _status = 'Scanning…';
    });
    try {
      if (!await _blePerms()) {
        throw Exception('Bluetooth permission denied');
      }
      final d = await _ble.scan();
      await _ble.connect(d);
      if (!mounted) {
        return;
      }
      setState(() {
        _connected = true;
        _autoReconnect = false;
        _status =
            'Connected to ${d.platformName}. Record arms capture; LED stays solid while armed.';
      });
    } catch (e) {
      if (mounted) {
        setState(() => _status = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _onConnectionLost() {
    if (!mounted || _autoReconnect) {
      return;
    }
    final wasArmed = _armed;
    _resumeAfterReconnect = wasArmed;
    setState(() {
      _connected = false;
      _dbg = null;
      _status = 'Connection lost. Reconnecting…';
    });
    Future(() async {
      if (wasArmed) {
        await _disarm(flush: true, keepSession: true);
      }
      await _beginAutoReconnect();
    });
  }

  Future<void> _beginAutoReconnect() async {
    _autoReconnect = true;
    for (var attempt = 1; attempt <= 5; attempt++) {
      if (!mounted || !_autoReconnect) {
        return;
      }
      setState(() => _status = 'Reconnecting… ($attempt/5)');
      await Future<void>.delayed(Duration(seconds: attempt == 1 ? 2 : 3));
      if (!mounted || !_autoReconnect) {
        return;
      }
      try {
        setState(() => _busy = true);
        await _ble.reconnect();
        if (!mounted) {
          return;
        }
        final resume = _resumeAfterReconnect;
        _resumeAfterReconnect = false;
        _autoReconnect = false;
        setState(() {
          _connected = true;
          _busy = false;
          _status = 'Reconnected to ${_ble.device?.platformName ?? 'OpenPendant'}.';
        });
        if (resume) {
          await _arm(resumeSession: true);
        }
        return;
      } catch (e) {
        if (mounted) {
          setState(() {
            _busy = false;
            _status = 'Reconnect try $attempt failed. Retrying…';
          });
        }
      }
    }
    if (!mounted) {
      return;
    }
    _autoReconnect = false;
    setState(() {
      _busy = false;
      _status = 'Could not reconnect. Tap Reconnect when the pendant is nearby.';
    });
  }

  Future<void> _manualReconnect() async {
    _autoReconnect = false;
    setState(() {
      _busy = true;
      _status = 'Reconnecting…';
    });
    try {
      if (!await _blePerms()) {
        throw Exception('Bluetooth permission denied');
      }
      await _ble.reconnect();
      if (!mounted) {
        return;
      }
      setState(() {
        _connected = true;
        _status = 'Reconnected to ${_ble.device?.platformName ?? 'OpenPendant'}.';
      });
    } catch (e) {
      if (mounted) {
        setState(() => _status = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _toggleRecord() async {
    if (_armed) {
      await _disarm(flush: true, keepSession: false);
    } else {
      await _arm(resumeSession: false);
    }
  }

  Future<void> _arm({required bool resumeSession}) async {
    setState(() {
      _busy = true;
    });
    try {
      if (!resumeSession || _sessionId == null) {
        _sessionId = const Uuid().v4();
        _seq = 0;
      }
      _chunkStartedAt = DateTime.now().toUtc();
      _lastSpeechAt = DateTime.now();
      _lastPcmAt = DateTime.now();
      _hadSpeechInChunk = false;
      _imuWasSleep = _dbg?.imuSleep ?? false;
      _bytes = 0;
      await _ble.startRecording(_onPcm);
      _armTick?.cancel();
      _armTick = Timer.periodic(const Duration(seconds: 1), (_) => _onArmTick());
      setState(() => _armed = true);
      _refreshArmedStatus();
    } catch (e) {
      setState(() => _status = '$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  void _onPcm() {
    if (!mounted || !_armed) {
      return;
    }
    final last = _ble.reassembler.lastComplete;
    _lastPcmAt = DateTime.now();
    if (pcmHasVoice(last, energyFloor: VadGate.energyFloor)) {
      _lastSpeechAt = DateTime.now();
      _hadSpeechInChunk = true;
    }
    setState(() => _bytes = _ble.reassembler.pcmByteLength);
    if (_ble.reassembler.pcmByteLength >= _maxChunkBytes) {
      Future.microtask(() => _rotateChunk());
    }
  }

  void _onArmTick() {
    if (!_armed || _rotating) {
      return;
    }
    final now = DateTime.now();
    if (_hadSpeechInChunk &&
        now.difference(_lastSpeechAt ?? now) >= _quietRotate) {
      Future.microtask(() => _rotateChunk());
      return;
    }
    final imuSleep = _dbg?.imuSleep ?? false;
    if (!imuSleep &&
        _bytes > 0 &&
        now.difference(_lastPcmAt ?? now) >= _noPcmRotate) {
      Future.microtask(() => _rotateChunk());
    }
    _refreshArmedStatus();
  }

  void _refreshArmedStatus() {
    if (!mounted || !_armed) {
      return;
    }
    final imu = _dbg == null
        ? 'IMU …'
        : (_dbg!.imuSleep ? 'IMU SLEEP' : 'IMU AWAKE');
    final chunkS = _bytes / 2 / 16000;
    setState(() {
      _status =
          'Armed — mic gated by IMU · $imu · chunk ${chunkS.toStringAsFixed(0)}s · STT queue ${_sttQueue.length + (_sttBusy ? 1 : 0)}';
    });
  }

  Future<void> _rotateChunk() async {
    if (!_armed || _rotating) {
      return;
    }
    _rotating = true;
    try {
      final started = _chunkStartedAt ?? DateTime.now().toUtc();
      final pcm = _ble.reassembler.pcmBytes();
      _ble.reassembler.reset();
      _chunkStartedAt = DateTime.now().toUtc();
      _lastSpeechAt = DateTime.now();
      _lastPcmAt = DateTime.now();
      _hadSpeechInChunk = false;
      _bytes = 0;
      if (pcm.length < 3200) {
        _refreshArmedStatus();
        return;
      }
      final duration = pcm.length / 2 / 16000;
      final id = const Uuid().v4();
      final dir = await getApplicationDocumentsDirectory();
      final wavPath = p.join(dir.path, 'clips', '$id.wav');
      await Directory(p.dirname(wavPath)).create(recursive: true);
      await File(wavPath).writeAsBytes(pcmToWav(pcm: pcm), flush: true);
      final clip = ClipRecord(
        id: id,
        startedAt: started,
        durationS: duration,
        fullText: '',
        wavPath: wavPath,
        sttModel: null,
        status: 'transcribing',
        sessionId: _sessionId,
        seq: _seq++,
      );
      await _store.upsertClip(clip);
      await _reload();
      _enqueueStt(clip);
      _refreshArmedStatus();
    } catch (e) {
      if (mounted) {
        setState(() => _status = '$e');
      }
    } finally {
      _rotating = false;
    }
  }

  Future<void> _disarm({required bool flush, required bool keepSession}) async {
    _armTick?.cancel();
    _armTick = null;
    while (_rotating) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    setState(() {
      _busy = true;
      _armed = false;
      _status = flush ? 'Stopping…' : 'Disarmed.';
    });
    try {
      if (flush) {
        final pcm = _ble.reassembler.pcmBytes();
        _ble.reassembler.reset();
        if (pcm.length >= 3200) {
          final started = _chunkStartedAt ?? DateTime.now().toUtc();
          final duration = pcm.length / 2 / 16000;
          final id = const Uuid().v4();
          final dir = await getApplicationDocumentsDirectory();
          final wavPath = p.join(dir.path, 'clips', '$id.wav');
          await Directory(p.dirname(wavPath)).create(recursive: true);
          await File(wavPath).writeAsBytes(pcmToWav(pcm: pcm), flush: true);
          final clip = ClipRecord(
            id: id,
            startedAt: started,
            durationS: duration,
            fullText: '',
            wavPath: wavPath,
            sttModel: null,
            status: 'transcribing',
            sessionId: _sessionId,
            seq: _seq++,
          );
          await _store.upsertClip(clip);
          await _reload();
          _enqueueStt(clip);
        }
      }
      await _ble.stopRecording();
      if (!keepSession) {
        _sessionId = null;
        _seq = 0;
      }
      if (mounted) {
        setState(() {
          _status = keepSession
              ? 'Chunk flushed. Reconnecting…'
              : 'Disarmed. Notify off.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _enqueueStt(ClipRecord clip) {
    _sttQueue.add(clip);
    _pumpStt();
  }

  Future<void> _pumpStt() async {
    if (_sttBusy) {
      return;
    }
    _sttBusy = true;
    while (_sttQueue.isNotEmpty) {
      final clip = _sttQueue.removeAt(0);
      if (mounted && _armed) {
        _refreshArmedStatus();
      }
      await _transcribeClip(clip);
      await _reload();
    }
    _sttBusy = false;
    if (mounted && _armed) {
      _refreshArmedStatus();
    }
  }

  Future<void> _transcribeClip(ClipRecord clip) async {
    final key = await ApiKeyStore.read();
    final wavPath = clip.wavPath;
    if (key.isEmpty || wavPath == null || !File(wavPath).existsSync()) {
      await _store.upsertClip(clip.copyWith(status: 'error'));
      if (mounted && !_armed) {
        setState(() => _status = 'Saved WAV but no API key. Add it in Settings, then Retry.');
      }
      return;
    }

    final full = await File(wavPath).readAsBytes();
    final pcm = full.length > 44 &&
            String.fromCharCodes(full.sublist(0, 4)) == 'RIFF'
        ? full.sublist(44)
        : full;
    final speech = extractSpeech(
      pcm,
      energyFloor: VadGate.energyFloor,
      minSpeechS: VadGate.minSpeechS,
    );
    if (speech.speechDurationS < VadGate.minSpeechS) {
      await _store.upsertClip(
        clip.copyWith(
          status: 'silence',
          billedS: 0,
          removedS: speech.originalDurationS,
          costUsd: 0,
          inputTokens: 0,
          outputTokens: 0,
        ),
      );
      return;
    }

    final speechPath = p.join(p.dirname(wavPath), '${clip.id}_speech.wav');
    await File(speechPath).writeAsBytes(pcmToWav(pcm: speech.speechPcm), flush: true);
    try {
      final result = await _stt.transcribe(
        wav: File(speechPath),
        apiKey: key,
        startedAt: clip.startedAt,
        speech: speech,
      );
      final hasText = result.text.trim().isNotEmpty ||
          result.segments.any((s) => s.text.trim().isNotEmpty);
      if (!hasText) {
        await _store.upsertClip(
          clip.copyWith(
            status: 'silence',
            fullText: '',
            sttModel: result.model,
            segments: const [],
            billedS: speech.speechDurationS,
            removedS: speech.originalDurationS - speech.speechDurationS,
            inputTokens: result.inputTokens,
            outputTokens: result.outputTokens,
            costUsd: result.costUsd,
          ),
        );
        return;
      }
      await _store.upsertClip(
        clip.copyWith(
          fullText: result.text,
          sttModel: result.model,
          status: 'ok',
          segments: result.segments,
          billedS: speech.speechDurationS,
          removedS: speech.originalDurationS - speech.speechDurationS,
          inputTokens: result.inputTokens,
          outputTokens: result.outputTokens,
          costUsd: result.costUsd,
        ),
      );
    } catch (e) {
      await _store.upsertClip(clip.copyWith(status: 'error'));
      if (mounted && !_armed) {
        setState(() => _status = 'WAV saved; STT failed: $e');
      }
    }
  }

  Future<void> _retry(ClipRecord clip) async {
    setState(() => _busy = true);
    try {
      await _store.upsertClip(clip.copyWith(status: 'transcribing'));
      await _reload();
      _enqueueStt(clip.copyWith(status: 'transcribing'));
      while (_sttBusy || _sttQueue.isNotEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await _reload();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _sleep() async {
    _autoReconnect = false;
    _resumeAfterReconnect = false;
    if (_armed) {
      await _disarm(flush: true, keepSession: false);
    }
    await _ble.disconnect();
    if (!mounted) {
      return;
    }
    setState(() {
      _connected = false;
      _armed = false;
      _dbg = null;
      _status = 'Sleeping. Notify off, LED blinks. Connect to wake.';
    });
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
  }

  Future<void> _openVoices() async {
    if (_armed) {
      setState(() => _status = 'Stop recording before adding a voice sample.');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VoicesPage(
          ble: _ble,
          connected: _connected,
          armed: _armed,
        ),
      ),
    );
  }

  Future<void> _openCalibrate() async {
    if (_armed) {
      setState(() => _status = 'Stop recording before calibrating.');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CalibratePage(
          ble: _ble,
          connected: _connected,
          armed: _armed,
        ),
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _pickBound({required bool isFrom}) async {
    final now = DateTime.now();
    final initial = isFrom
        ? (_rangeFrom ?? now.subtract(const Duration(hours: 1)))
        : (_rangeTo ?? now);
    final d = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 1),
    );
    if (d == null || !mounted) {
      return;
    }
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (t == null || !mounted) {
      return;
    }
    final picked = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    setState(() {
      if (isFrom) {
        _rangeFrom = picked;
      } else {
        _rangeTo = picked;
      }
    });
    if (_rangeFrom != null && _rangeTo != null) {
      await _applyRange(_rangeFrom!, _rangeTo!);
    }
  }

  Future<void> _applyRange(DateTime from, DateTime to) async {
    var a = from;
    var b = to;
    if (a.isAfter(b)) {
      final tmp = a;
      a = b;
      b = tmp;
    }
    setState(() {
      _rangeFrom = a;
      _rangeTo = b;
    });
    await _reload();
  }

  Future<void> _clearRange() async {
    setState(() {
      _rangeFrom = null;
      _rangeTo = null;
      _rangeSegs = [];
    });
    await _reload();
  }

  String _fmtBound(DateTime? t) {
    if (t == null) {
      return 'Choose';
    }
    return DateFormat('MMM d, HH:mm').format(t);
  }

  Widget _liveCard() {
    final ranging = _rangeFrom != null && _rangeTo != null;
    final label = ranging
        ? 'Transcript in range'
        : (_armed ? 'Live transcript (updates when a chunk finishes)' : 'Latest transcript');
    final body = _liveTranscript.trim().isEmpty
        ? (ranging
            ? 'No speech in this time range yet.'
            : 'Speech will appear here after OpenAI finishes a chunk.')
        : _liveTranscript;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                controller: _liveScroll,
                child: SelectableText(body),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rangeBar() {
    final now = DateTime.now();
    final hourStart = DateTime(now.year, now.month, now.day, now.hour);
    final todayStart = DateTime(now.year, now.month, now.day);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Time range', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                onPressed: () => _pickBound(isFrom: true),
                child: Text('From ${_fmtBound(_rangeFrom)}'),
              ),
              OutlinedButton(
                onPressed: () => _pickBound(isFrom: false),
                child: Text('To ${_fmtBound(_rangeTo)}'),
              ),
              if (_rangeFrom != null || _rangeTo != null)
                TextButton(onPressed: _clearRange, child: const Text('Clear')),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              ActionChip(
                label: const Text('This hour'),
                onPressed: () => _applyRange(hourStart, now),
              ),
              ActionChip(
                label: const Text('Last hour'),
                onPressed: () =>
                    _applyRange(now.subtract(const Duration(hours: 1)), now),
              ),
              ActionChip(
                label: const Text('Today'),
                onPressed: () => _applyRange(todayStart, now),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _batteryLine(PendantStatus s) {
    final mv = s.batteryMv;
    final mvLabel = (mv != null && mv > 0)
        ? '  rail ${(mv / 1000).toStringAsFixed(2)} V'
        : '';
    if (s.usbPowered) {
      return 'Power: USB$mvLabel  (SoC only when unplugged — charger looks like a full cell)';
    }
    final pct = s.batteryPct;
    if (pct == null || mv == null) {
      return 'Battery: not seen';
    }
    final warn = pct <= 20 ? '  — charge soon' : '';
    return 'Battery: ~$pct%  (${(mv / 1000).toStringAsFixed(2)} V)$warn';
  }

  Widget _debugCard() {
    final s = _dbg;
    final imuLabel = !_connected
        ? '—'
        : (s == null)
            ? 'waiting (flash IMU firmware if this stays empty)'
            : s.imuSleep
                ? 'SLEEP'
                : 'AWAKE';
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Debug', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text('Link: ${_connected ? 'connected' : 'down'}'),
            Text('Mode: ${_armed ? 'armed (notify on)' : 'idle'}'),
            Text(VadCal.statusLine()),
            Text('IMU: $imuLabel'),
            if (s != null) ...[
              Text(_batteryLine(s)),
              Text('Mic: ${s.micRunning ? 'running' : 'stopped'}'),
              Text(
                'Chip: ${s.imuReady ? 'LSM6DS3 ready' : 'not ready (sleep will not start)'}',
              ),
              Text(
                'IMU read: ${s.imuFetchOk ? 'ok' : 'fail (still meter stays 0)'}',
              ),
              Text('Still meter: ${s.stillHits}/10  (10 still polls → sleep)'),
              Text('Mic level: ${s.volume}  (info only; host VAD filters noise)'),
            ],
            const Text(
              'Armed: LED stays solid. Sit still ~10s → IMU SLEEP cuts a chunk '
              '(no OpenAI if quiet). Move and talk → next chunk.',
            ),
          ],
        ),
      ),
    );
  }

  void _openItem(Object item) {
    if (item is SessionGroup) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ClipPage.session(session: item)),
      );
    } else if (item is ClipRecord) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ClipPage.single(clip: item)),
      );
    }
  }

  Widget _homeTile(Object item) {
    if (item is SessionGroup) {
      final when = DateFormat.yMMMd().add_Hms().format(item.startedAt.toLocal());
      final title = item.fullText.isEmpty ? '(${item.status})' : item.fullText;
      final err = item.clips.where((c) => c.status == 'error').firstOrNull;
      return ListTile(
        isThreeLine: true,
        title: Text(title, maxLines: 6, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '$when  ${item.clips.length} chunks  ${item.status}\n${item.usageLine}',
        ),
        trailing: err != null
            ? TextButton(
                onPressed: _busy ? null : () => _retry(err),
                child: const Text('Retry'),
              )
            : null,
        onTap: () => _openItem(item),
      );
    }
    final c = item as ClipRecord;
    final when = DateFormat.yMMMd().add_Hms().format(c.startedAt.toLocal());
    return ListTile(
      isThreeLine: true,
      title: Text(
        c.fullText.isEmpty ? '(${c.status})' : c.fullText,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text('$when  ${c.status}\n${c.usageLine}'),
      trailing: c.status == 'error'
          ? TextButton(
              onPressed: _busy ? null : () => _retry(c),
              child: const Text('Retry'),
            )
          : null,
      onTap: () => _openItem(c),
    );
  }

  @override
  Widget build(BuildContext context) {
    final recLabel = _armed ? 'Stop' : 'Record';
    return Scaffold(
      appBar: AppBar(
        title: const Text('OpenPendant'),
        actions: [
          if (_dbg != null && _connected)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  _dbg!.usbPowered
                      ? 'USB'
                      : (_dbg!.batteryPct != null ? '${_dbg!.batteryPct}%' : ''),
                  style: TextStyle(
                    color: (!_dbg!.usbPowered &&
                            _dbg!.batteryPct != null &&
                            _dbg!.batteryPct! <= 20)
                        ? Colors.orange
                        : null,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          IconButton(
            tooltip: 'Named voices',
            icon: const Icon(Icons.record_voice_over),
            onPressed: _openVoices,
          ),
          IconButton(
            tooltip: 'API key and settings',
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!_connected && _ble.device != null)
                  MaterialBanner(
                    content: Text(
                      _autoReconnect
                          ? 'Pendant disconnected — trying to reconnect…'
                          : 'Pendant disconnected.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: _busy ? null : _manualReconnect,
                        child: const Text('Reconnect'),
                      ),
                    ],
                  ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_status),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Text(
                    'STT spend ${SttPricing.formatUsd(_totalCostUsd)}  ·  '
                    '${_totalBilledS.toStringAsFixed(1)}s billed'
                    '${(_totalInTok + _totalOutTok) > 0 ? '  ·  $_totalInTok in / $_totalOutTok out tok' : ''}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: _busy || _connected
                            ? null
                            : (_ble.device != null ? _manualReconnect : _connect),
                        child: Text(_ble.device != null ? 'Reconnect' : 'Connect'),
                      ),
                      FilledButton.tonal(
                        onPressed: _busy || !_connected ? null : _toggleRecord,
                        child: Text(recLabel),
                      ),
                      OutlinedButton(
                        onPressed: _busy || (!_connected && !_armed) ? null : _sleep,
                        child: const Text('Sleep'),
                      ),
                      OutlinedButton(
                        onPressed: _openCalibrate,
                        child: const Text('Calibrate'),
                      ),
                      OutlinedButton(
                        onPressed: _openVoices,
                        child: const Text('Voices'),
                      ),
                      OutlinedButton(
                        onPressed: _openSettings,
                        child: const Text('Settings'),
                      ),
                    ],
                  ),
                ),
                if (_armed)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text('PCM bytes: $_bytes'),
                  ),
                _debugCard(),
                _rangeBar(),
                _liveCard(),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      labelText: 'Search transcripts',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _reload(),
                    onChanged: (_) => _reload(),
                  ),
                ),
              ],
            ),
          ),
          if (_rangeFrom != null && _rangeTo != null)
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  if (_rangeSegs.isEmpty) {
                    return const ListTile(
                      title: Text('No lines in this range.'),
                    );
                  }
                  final s = _rangeSegs[i];
                  return ListTile(
                    title: Text(s.labeledText),
                    subtitle: Text(
                      [
                        if (s.speaker != null && s.speaker!.trim().isNotEmpty) s.speaker,
                        DateFormat.yMMMd().add_Hms().format(s.spokenAt.toLocal()),
                      ].join('  '),
                    ),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ClipPage.range(
                            segments: _rangeSegs,
                            title:
                                '${_fmtBound(_rangeFrom)} – ${_fmtBound(_rangeTo)}',
                          ),
                        ),
                      );
                    },
                  );
                },
                childCount: _rangeSegs.isEmpty ? 1 : _rangeSegs.length,
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => _homeTile(_homeItems[i]),
                childCount: _homeItems.length,
              ),
            ),
        ],
      ),
    );
  }
}
