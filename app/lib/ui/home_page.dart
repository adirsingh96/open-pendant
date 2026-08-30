import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../calendar/note_command.dart';
import '../notes/note_prefs.dart';
import '../audio/speech_vad.dart';
import '../audio/wav_writer.dart';
import '../audio/device_mic.dart';
import '../ble/pendant_ble.dart';
import '../db/clip_store.dart';
import '../db/day_recap.dart';
import '../db/meeting.dart';
import '../db/models.dart';
import '../stt/api_key_store.dart';
import '../stt/cursor_command.dart';
import '../stt/cursor_prefs.dart';
import '../macos/cursor_composer.dart';
import '../stt/local_speaker.dart';
import '../stt/openai_refine.dart';
import '../stt/openai_stt.dart';
import '../stt/saaras_stt.dart';
import '../stt/sarvam_key_store.dart';
import '../stt/stt_prefs.dart';
import '../stt/voice_store.dart';
import 'clip_page.dart';
import 'calibrate_page.dart';
import 'developer_page.dart';
import 'settings_page.dart';
import 'voices_page.dart';
import 'app_theme.dart';
import 'meeting_detail_page.dart';
import 'transcript_bubbles.dart';
import 'liquid_glass.dart';
import 'mesh_backdrop.dart';
import '../stt/vad_cal.dart';
import '../db/scene_group.dart';
import '../mem0/mem0_client.dart';
import '../mem0/mem0_store.dart';
import 'memories_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _maxChunkBytes = 30 * 16000 * 2;
  static const _quietRotate = Duration(seconds: 8);
  static const _cursorQuietRotate = Duration(milliseconds: 1500);
  static const _noPcmRotate = Duration(seconds: 2);
  static const _notePrerollBytes = 16000 * 2 * 7 ~/ 10;

  AppLifecycleListener? _lifecycle;
  Timer? _armTick;
  final _ble = PendantBle();
  final _store = ClipStore();
  final _stt = OpenAiStt();
  final _saaras = SaarasStt();
  final _refine = OpenAiRefine();
  final _dev = DeveloperLive();
  final _search = TextEditingController();

  String _status = 'Disconnected. Force-quit nRF Connect first.';
  bool _busy = false;
  bool _connected = false;
  bool _armed = false;
  bool _usingDeviceMic = false;
  final _deviceMic = DeviceMic();
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
  List<MeetingRecord> _meetings = [];
  List<SpokenNote> _notes = [];
  List<TranscriptSegment> _rangeSegs = [];
  bool _cleaning = false;
  bool _commandNext = false;
  bool _noteHolding = false;
  bool _noteTempArm = false;
  bool _noteUsingDeviceMic = false;
  bool _noteStopping = false;
  int _noteFromByte = 0;
  int _btnSeqSeen = 0;
  bool _btnSeqPrimed = false;
  int _tab = 0;
  bool _showLive = false;
  String _wearerName = '';
  List<double> _levels = [];
  DateTime? _meetingStartedAt;
  Future<void>? _noteBegin;
  final _buttonNoteIds = <String>{};
  final _buttonNoteMeetingIds = <String, String>{};
  List<DateTime> _speechDays = [];
  DateTime? _rangeFrom;
  DateTime? _rangeTo;
  double _totalCostUsd = 0;
  double _totalBilledS = 0;
  int _totalInTok = 0;
  int _totalOutTok = 0;

  @override
  void initState() {
    super.initState();
    _ble.onConnectionLost = _onConnectionLost;
    _ble.onStatus = _onPendantStatus;
    _ble.warmup();
    VadCal.load().then((_) {
      if (mounted) {
        setState(() {});
      }
    });
    SttPrefs.load();
    CursorPrefs.load();
    NotePrefs.load();
    final now = DateTime.now();
    _rangeFrom = DateTime(now.year, now.month, now.day);
    _rangeTo = DateTime(now.year, now.month, now.day, 23, 59, 59);
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
    _dev.dispose();
    _ble.disconnect();
    unawaited(_deviceMic.stop());
    super.dispose();
  }

  void _onPendantStatus(PendantStatus s) {
    if (!mounted) {
      return;
    }
    final wasSleep = _imuWasSleep;
    _imuWasSleep = s.imuSleep;
    setState(() {
      _dbg = s;
      final v = (s.volume / 3500).clamp(0.06, 1.0).toDouble();
      _levels = [..._levels, v];
      if (_levels.length > 36) {
        _levels = _levels.sublist(_levels.length - 36);
      }
    });
    _syncButtonNote(s);
    _syncDev();
    if (!_armed || _noteHolding || _usingDeviceMic) {
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

  void _syncButtonNote(PendantStatus s) {
    var held = s.noteHeld;
    if (s.buttonSeq != 0 && !_btnSeqPrimed) {
      _btnSeqSeen = s.buttonSeq;
      _btnSeqPrimed = true;
    } else if (s.buttonSeq != 0 && s.buttonSeq != _btnSeqSeen) {
      _btnSeqSeen = s.buttonSeq;
      if (s.buttonEvent == 3) {
        held = true;
      } else if (s.buttonEvent == 4) {
        held = false;
      } else if (s.buttonEvent == 1 && !_noteHolding && !_busy) {
        unawaited(_toggleMeeting());
      }
    }
    if (held && !_noteHolding) {
      _noteHolding = true;
      _noteBegin = _beginButtonNote();
    } else if (!held && _noteHolding) {
      _noteHolding = false;
      unawaited(_endButtonNote());
    }
  }

  Future<void> _beginButtonNote() async {
    await NotePrefs.load();
    if (!NotePrefs.enabled) {
      _noteHolding = false;
      return;
    }
    try {
      if (!_armed) {
        _noteTempArm = true;
        _ble.reassembler.reset();
        _noteFromByte = 0;
        if (_connected) {
          _noteUsingDeviceMic = false;
          await _ble.startRecording(_onPcm);
        } else {
          _noteUsingDeviceMic = true;
          await _deviceMic.start(
            pcm: _ble.reassembler,
            onPacket: _onPcm,
          );
        }
      } else {
        _noteTempArm = false;
        _noteUsingDeviceMic = false;
        var from = _ble.reassembler.pcmByteLength - _notePrerollBytes;
        if (from < 0) {
          from = 0;
        }
        if (from.isOdd) {
          from -= 1;
        }
        _noteFromByte = from;
      }
      if (mounted) {
        setState(() => _status = 'Note… tap again to save');
      }
    } catch (e) {
      _noteHolding = false;
      _noteTempArm = false;
      if (_noteUsingDeviceMic) {
        await _deviceMic.stop();
      }
      _noteUsingDeviceMic = false;
      if (mounted) {
        setState(() => _status = '$e');
      }
    }
  }

  Future<void> _endButtonNote() async {
    await _noteBegin;
    if (!NotePrefs.enabled) {
      return;
    }
    final all = _ble.reassembler.pcmBytes();
    var from = _noteFromByte;
    if (from < 0) {
      from = 0;
    }
    if (from > all.length) {
      from = all.length;
    }
    if (from.isOdd) {
      from -= 1;
    }
    final slice = all.sublist(from);
    if (_noteTempArm) {
      try {
        if (_noteUsingDeviceMic) {
          await _deviceMic.stop();
        } else {
          await _ble.stopRecording();
        }
      } catch (_) {}
      _ble.reassembler.reset();
      _noteTempArm = false;
      _noteUsingDeviceMic = false;
    } else {
      _ble.reassembler.replaceWith(all.sublist(0, from));
      _bytes = _ble.reassembler.pcmByteLength;
    }
    if (slice.length < 3200) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Hold a bit longer while you speak.')),
        );
        _refreshArmedStatus();
      }
      return;
    }
    try {
      final started = DateTime.now().toUtc().subtract(
            Duration(milliseconds: (slice.length / 2 / 16).round()),
          );
      final duration = slice.length / 2 / 16000;
      final id = const Uuid().v4();
      final dir = await getApplicationDocumentsDirectory();
      final wavPath = p.join(dir.path, 'clips', '$id.wav');
      await Directory(p.dirname(wavPath)).create(recursive: true);
      await File(wavPath).writeAsBytes(pcmToWav(pcm: slice), flush: true);
      final clip = ClipRecord(
        id: id,
        startedAt: started,
        durationS: duration,
        fullText: '',
        wavPath: wavPath,
        sttModel: null,
        status: 'transcribing',
        sessionId: null,
        seq: 0,
      );
      _buttonNoteIds.add(id);
      if (_armed && _sessionId != null) {
        _buttonNoteMeetingIds[id] = _sessionId!;
      }
      await _store.upsertClip(clip);
      await _reload();
      _enqueueStt(clip);
      if (mounted) {
        setState(() => _status = 'Saving note…');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = '$e');
      }
    }
  }

  Future<void> _reload() async {
    final cost = await _store.totalCostUsd();
    final usage = await _store.totalUsage();
    final now = DateTime.now();
    final from = _rangeFrom ?? DateTime(now.year, now.month, now.day);
    final to = _rangeTo ?? DateTime(now.year, now.month, now.day, 23, 59, 59);
    final segs = await _store.listSegmentsInRange(
      from: from,
      to: to,
      query: _search.text,
    );
    final allSegs = _search.text.trim().isEmpty
        ? segs
        : await _store.listSegmentsInRange(from: from, to: to);
    final notes = await _store.listNotesInRange(
      from: from,
      to: to,
      query: _search.text,
    );
    final meetings = await _store.listMeetingsInRange(
      from: from,
      to: to,
      query: _search.text,
    );
    final weekStart = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 6));
    final speechDays = await _store.listLocalDaysWithSpeech(
      from: weekStart,
      to: DateTime(now.year, now.month, now.day, 23, 59, 59),
    );
    final voices = await VoiceStore.list();
    if (!mounted) {
      return;
    }
    setState(() {
      _meetings = meetings;
      _rangeSegs = allSegs;
      _notes = notes;
      _speechDays = speechDays;
      _totalCostUsd = cost;
      _totalBilledS = usage.billedS;
      _totalInTok = usage.inputTokens;
      _totalOutTok = usage.outputTokens;
      _wearerName = voices.isEmpty
          ? ''
          : voices.first.name.trim().split(RegExp(r'\s+')).first;
    });
    _syncDev(force: true);
  }

  DateTime _calendarDay(DateTime t) {
    final l = t.toLocal();
    return DateTime(l.year, l.month, l.day);
  }

  bool _sameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  DateTime get _selectedDay {
    final now = DateTime.now();
    return _calendarDay(
      _rangeFrom ?? DateTime(now.year, now.month, now.day),
    );
  }

  List<DateTime> _stripDays() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final extra = _speechDays.where(
      (d) => !_sameDay(d, today) && !_sameDay(d, yesterday),
    );
    return [today, yesterday, ...extra];
  }

  String _stripLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final short = DateFormat('EEE d MMM').format(day);
    if (_sameDay(day, today)) {
      return 'Today · $short';
    }
    if (_sameDay(day, yesterday)) {
      return 'Yesterday · $short';
    }
    return short;
  }

  Future<void> _selectDay(DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    return _applyRange(
      start,
      DateTime(day.year, day.month, day.day, 23, 59, 59),
    );
  }

  Future<void> _cleanMeeting(MeetingRecord meeting) async {
    final segs =
        meeting.segments.where((s) => s.text.trim().isNotEmpty).toList();
    if (segs.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing to recap in this meeting yet.')),
      );
      return;
    }
    final key = await ApiKeyStore.read();
    if (key.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Add an OpenAI API key in Settings first.')),
      );
      return;
    }
    setState(() => _cleaning = true);
    try {
      final start = meeting.startedAt.toLocal();
      final end = (meeting.endedAt ?? DateTime.now()).toLocal();
      final result = await _refine.cleanAndRecapDay(
        apiKey: key,
        dayKey: meeting.id,
        dateLabel: 'Meeting ${DateFormat.MMMd().add_jm().format(start)}',
        rangeLabel: '${DateFormat.MMMd().add_jm().format(start)} – '
            '${DateFormat.jm().format(end)} '
            '(only these recorded turns; do not invent later hours)',
        segments: segs,
      );
      await _store.applyCleanedSegments(result.segments);
      await _store.upsertMeetingRecap(
        meetingId: meeting.id,
        recap: result.recap,
      );
      await _reload();
      final memStatus = await _syncMem0(
        recap: result.recap,
        dateLabel: DateFormat.MMMd().add_jm().format(start),
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Meeting recap saved. $memStatus')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Recap failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _cleaning = false);
      }
    }
  }

  Future<String> _syncMem0({
    required DayRecap recap,
    required String dateLabel,
  }) async {
    final memKey = await Mem0Store.readKey();
    if (memKey.isEmpty) {
      return 'Mem0 skipped (no MEM0_API_KEY).';
    }
    try {
      final userId = await Mem0Store.userId();
      await Mem0Client().addRecap(
        apiKey: memKey,
        userId: userId,
        recap: recap,
        dateLabel: dateLabel,
      );
      await Mem0Store.markSynced(
        Mem0Store.recapMark(recap.dayKey, recap.updatedAt),
      );
      return 'Sent recap to Mem0.';
    } catch (e) {
      return 'Memory sync failed: $e';
    }
  }

  void _syncDev({bool force = false}) {
    _dev.sync(
      connected: _connected,
      armed: _armed,
      bytes: _bytes,
      dbg: _dbg,
      sttQueue: _sttQueue.length + (_sttBusy ? 1 : 0),
      totalCostUsd: _totalCostUsd,
      totalBilledS: _totalBilledS,
      totalInTok: _totalInTok,
      totalOutTok: _totalOutTok,
      segments: _rangeSegs,
      force: force,
    );
  }

  String _wearerLabel() {
    if (!_connected) {
      return 'Off';
    }
    if (_noteHolding) {
      return 'Note';
    }
    if (_armed) {
      return 'Meeting ${_meetingElapsed()}';
    }
    return 'Idle';
  }

  String _meetingElapsed() {
    final start = _meetingStartedAt;
    if (start == null) {
      return '';
    }
    final d = DateTime.now().difference(start);
    final m = d.inMinutes.clamp(0, 99 * 60);
    final s = d.inSeconds.remainder(60);
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
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
            'Connected to ${d.platformName}. Click starts a meeting; hold the button for a note.';
      });
    } catch (e) {
      if (mounted) {
        setState(() => _status = _friendlyBleError(e));
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
    if (_usingDeviceMic || _noteUsingDeviceMic) {
      setState(() {
        _connected = false;
        _dbg = null;
      });
      return;
    }
    if (_noteHolding && !_armed) {
      unawaited(_failPendantNote());
      return;
    }
    if (_armed) {
      unawaited(_failPendantMeeting());
      return;
    }
    final wasArmed = _armed;
    _resumeAfterReconnect = wasArmed;
    setState(() {
      _connected = false;
      _dbg = null;
      _btnSeqPrimed = false;
      _status = 'Connection lost. Reconnecting…';
    });
    Future(() async {
      if (wasArmed) {
        await _disarm(flush: true, keepSession: true);
      }
      await _beginAutoReconnect();
    });
  }

  Future<void> _failPendantNote() async {
    _noteHolding = false;
    await _noteBegin;
    if (_noteTempArm) {
      try {
        await _ble.stopRecording();
      } catch (_) {}
      _ble.reassembler.reset();
      _noteTempArm = false;
    }
    _noteUsingDeviceMic = false;
    if (!mounted) {
      return;
    }
    setState(() {
      _connected = false;
      _dbg = null;
      _status = 'Pendant disconnected. Note stopped.';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 5),
        content: Text(
          'Pendant disconnected. Note stopped. Reconnect to talk from the necklace, or hold to talk on this device’s mic.',
        ),
      ),
    );
  }

  Future<void> _failPendantMeeting() async {
    _autoReconnect = false;
    _resumeAfterReconnect = false;
    await _disarm(flush: true, keepSession: false);
    if (!mounted) {
      return;
    }
    setState(() {
      _connected = false;
      _showLive = false;
      _status = 'Pendant disconnected. Meeting stopped.';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 5),
        content: Text(
          'Pendant disconnected. Meeting stopped. Reconnect to record with the necklace, or start a new meeting on this device’s mic.',
        ),
      ),
    );
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
          _status =
              'Reconnected to ${_ble.device?.platformName ?? 'OpenPendant'}.';
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
      _status =
          'Could not reconnect. Tap Reconnect when the pendant is nearby.';
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
        _status =
            'Reconnected to ${_ble.device?.platformName ?? 'OpenPendant'}.';
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

  Future<void> _toggleMeeting() async {
    if (_busy) {
      return;
    }
    if (_armed) {
      await _disarm(flush: true, keepSession: false);
      if (mounted) {
        setState(() => _showLive = false);
      }
    } else {
      await _arm(resumeSession: false);
      if (mounted && _armed) {
        setState(() => _showLive = true);
      }
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
        _meetingStartedAt = DateTime.now();
        await _store.startMeeting(
          MeetingRecord(
            id: _sessionId!,
            startedAt: DateTime.now().toUtc(),
          ),
        );
      }
      _meetingStartedAt ??= DateTime.now();
      _chunkStartedAt = DateTime.now().toUtc();
      _lastSpeechAt = DateTime.now();
      _lastPcmAt = DateTime.now();
      _hadSpeechInChunk = false;
      _imuWasSleep = _dbg?.imuSleep ?? false;
      _bytes = 0;
      _usingDeviceMic = !_connected;
      if (_usingDeviceMic) {
        _ble.reassembler.reset();
        await _deviceMic.start(
          pcm: _ble.reassembler,
          onPacket: _onPcm,
        );
      } else {
        await _ble.startRecording(_onPcm);
      }
      _armTick?.cancel();
      _armTick = Timer.periodic(
          const Duration(milliseconds: 200), (_) => _onArmTick());
      setState(() => _armed = true);
      _refreshArmedStatus();
    } catch (e) {
      _usingDeviceMic = false;
      await _deviceMic.stop();
      if (!resumeSession && _sessionId != null) {
        try {
          await _store.endMeeting(_sessionId!);
        } catch (_) {}
        _sessionId = null;
        _meetingStartedAt = null;
      }
      if (mounted) {
        setState(() => _status = '$e');
      }
    } finally {
      setState(() => _busy = false);
    }
  }

  void _onPcm() {
    if (!mounted || (!_armed && !_noteHolding)) {
      return;
    }
    final last = _ble.reassembler.lastComplete;
    _lastPcmAt = DateTime.now();
    if (pcmHasVoice(last, energyFloor: VadGate.energyFloor)) {
      _lastSpeechAt = DateTime.now();
      _hadSpeechInChunk = true;
    }
    setState(() => _bytes = _ble.reassembler.pcmByteLength);
    if (_usingDeviceMic || _noteUsingDeviceMic) {
      _pushLevelFromPcm(last);
    }
    _syncDev();
    if (!_noteHolding && _ble.reassembler.pcmByteLength >= _maxChunkBytes) {
      Future.microtask(() => _rotateChunk());
    }
  }

  void _onArmTick() {
    if (!_armed || _rotating || _noteHolding) {
      return;
    }
    final now = DateTime.now();
    final quiet = (CursorPrefs.enabled || NotePrefs.enabled)
        ? _cursorQuietRotate
        : _quietRotate;
    if (_hadSpeechInChunk && now.difference(_lastSpeechAt ?? now) >= quiet) {
      Future.microtask(() => _rotateChunk());
      return;
    }
    final imuSleep = _dbg?.imuSleep ?? false;
    if (!_usingDeviceMic &&
        !imuSleep &&
        _bytes > 0 &&
        now.difference(_lastPcmAt ?? now) >= _noPcmRotate) {
      Future.microtask(() => _rotateChunk());
    }
    _refreshArmedStatus();
  }

  void _pushLevelFromPcm(List<int> pcm) {
    if (pcm.length < 4) {
      return;
    }
    var sum = 0;
    final n = pcm.length ~/ 2;
    for (var i = 0; i + 1 < pcm.length; i += 2) {
      var s = pcm[i] | (pcm[i + 1] << 8);
      if (s > 32767) {
        s -= 65536;
      }
      sum += s.abs();
    }
    final avg = n == 0 ? 0.0 : sum / n;
    final v = (avg / 4000).clamp(0.06, 1.0).toDouble();
    _levels = [..._levels, v];
    if (_levels.length > 36) {
      _levels = _levels.sublist(_levels.length - 36);
    }
  }

  void _refreshArmedStatus() {
    if (!mounted || !_armed) {
      return;
    }
    final imu = _dbg == null ? '…' : (_dbg!.imuSleep ? 'Resting' : 'Listening');
    setState(() {
      _status =
          '${_wearerLabel()}${_dbg == null ? '' : ' · $imu'} · ${_sttEngineLabel()} · queue ${_sttQueue.length + (_sttBusy ? 1 : 0)}';
    });
    _syncDev();
  }

  Future<void> _rotateChunk() async {
    if (!_armed || _rotating || _noteHolding) {
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
    if (_noteHolding) {
      _noteHolding = false;
      await _endButtonNote();
    }
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
      await _deviceMic.stop();
      _usingDeviceMic = false;
      if (!keepSession) {
        if (_sessionId != null) {
          await _store.endMeeting(_sessionId!);
        }
        _sessionId = null;
        _seq = 0;
        _meetingStartedAt = null;
      }
      if (mounted) {
        setState(() {
          _status =
              keepSession ? 'Chunk flushed. Reconnecting…' : 'Meeting ended.';
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

  String _sttEngineLabel() {
    if (SttPrefs.useBoth) {
      return 'OpenAI+Saaras';
    }
    if (SttPrefs.useSaarasOnly) {
      return 'Saaras v4';
    }
    return 'OpenAI';
  }

  List<TranscriptSegment> _sttSegs(TranscriptResult result) {
    return [
      for (final s in result.segments)
        s.copyWith(rawText: s.rawText.trim().isEmpty ? s.text : s.rawText),
    ];
  }

  bool _sttHasText(TranscriptResult r) {
    return r.text.trim().isNotEmpty ||
        r.segments.any((s) => s.text.trim().isNotEmpty);
  }

  Future<({TranscriptResult? result, Object? error})> _tryOpenai({
    required File wav,
    required String apiKey,
    required DateTime startedAt,
    required SpeechExtract speech,
  }) async {
    try {
      return (
        result: await _stt.transcribe(
          wav: wav,
          apiKey: apiKey,
          startedAt: startedAt,
          speech: speech,
          fast: CursorPrefs.enabled || NotePrefs.enabled,
        ),
        error: null,
      );
    } catch (e) {
      return (result: null, error: e);
    }
  }

  Future<({TranscriptResult? result, Object? error})> _trySaaras({
    required File wav,
    required String apiKey,
    required DateTime startedAt,
    required SpeechExtract speech,
  }) async {
    try {
      var result = await _saaras.transcribe(
        wav: wav,
        apiKey: apiKey,
        startedAt: startedAt,
        speech: speech,
      );
      try {
        result = await LocalSpeaker.tagTranscript(
          wav: wav,
          transcript: result,
          speech: speech,
        );
      } catch (e) {
        debugPrint('local speaker: $e');
      }
      final named =
          result.segments.any((s) => (s.speaker ?? '').trim().isNotEmpty);
      final voices = await VoiceStore.list();
      if (!named && voices.length == 1) {
        result = applySaarasVoiceTags(result, voices);
      }
      return (result: result, error: null);
    } catch (e) {
      return (result: null, error: e);
    }
  }

  Future<void> _transcribeClip(ClipRecord clip) async {
    await SttPrefs.load();
    final buttonNote = _buttonNoteIds.contains(clip.id);
    final wavPath = clip.wavPath;
    final openaiKey = await ApiKeyStore.read();
    final sarvamKey = await SarvamKeyStore.read();
    final needOpenAi = !SttPrefs.useSaarasOnly;
    final needSarvam = SttPrefs.useSaaras;
    if (wavPath == null || !File(wavPath).existsSync()) {
      _buttonNoteIds.remove(clip.id);
      await _store.upsertClip(clip.copyWith(status: 'error'));
      return;
    }
    if ((needOpenAi && openaiKey.isEmpty) ||
        (needSarvam && sarvamKey.isEmpty)) {
      _buttonNoteIds.remove(clip.id);
      await _store.upsertClip(clip.copyWith(status: 'error'));
      final missing = [
        if (needOpenAi && openaiKey.isEmpty) 'OpenAI',
        if (needSarvam && sarvamKey.isEmpty) 'Sarvam',
      ].join(' and ');
      _toastSttFailed('No $missing API key. Add it in Settings.');
      return;
    }

    final full = await File(wavPath).readAsBytes();
    final pcm =
        full.length > 44 && String.fromCharCodes(full.sublist(0, 4)) == 'RIFF'
            ? full.sublist(44)
            : full;
    final speech = extractSpeech(
      pcm,
      energyFloor: VadGate.energyFloor,
      minSpeechS: buttonNote ? 0.12 : VadGate.minSpeechS,
    );
    if (speech.speechDurationS < (buttonNote ? 0.12 : VadGate.minSpeechS)) {
      if (buttonNote) {
        _buttonNoteIds.remove(clip.id);
        await _store.upsertClip(
          clip.copyWith(
            status: 'note',
            billedS: 0,
            removedS: speech.originalDurationS,
            costUsd: 0,
            inputTokens: 0,
            outputTokens: 0,
            clearAlt: true,
          ),
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No speech in that note.')),
          );
        }
        return;
      }
      await _store.upsertClip(
        clip.copyWith(
          status: 'silence',
          billedS: 0,
          removedS: speech.originalDurationS,
          costUsd: 0,
          inputTokens: 0,
          outputTokens: 0,
          clearAlt: true,
        ),
      );
      return;
    }

    final speechPath = p.join(p.dirname(wavPath), '${clip.id}_speech.wav');
    await File(speechPath)
        .writeAsBytes(pcmToWav(pcm: speech.speechPcm), flush: true);
    final wav = File(speechPath);
    try {
      TranscriptResult? openai;
      TranscriptResult? saaras;
      Object? openaiErr;
      Object? saarasErr;
      Future<void>? cursorKickoff;
      if (SttPrefs.useBoth) {
        final openaiF = _tryOpenai(
          wav: wav,
          apiKey: openaiKey,
          startedAt: clip.startedAt,
          speech: speech,
        );
        final saarasF = _trySaaras(
          wav: wav,
          apiKey: sarvamKey,
          startedAt: clip.startedAt,
          speech: speech,
        );
        final o = await openaiF;
        openai = o.result;
        openaiErr = o.error;
        if (!buttonNote && openai != null && _sttHasText(openai)) {
          cursorKickoff = _maybeCursorCommand(
            segs: _sttSegs(openai),
            fullText: openai.text,
          );
        }
        final s = await saarasF;
        saaras = s.result;
        saarasErr = s.error;
      } else if (SttPrefs.useSaarasOnly) {
        final one = await _trySaaras(
          wav: wav,
          apiKey: sarvamKey,
          startedAt: clip.startedAt,
          speech: speech,
        );
        saaras = one.result;
        saarasErr = one.error;
      } else {
        final one = await _tryOpenai(
          wav: wav,
          apiKey: openaiKey,
          startedAt: clip.startedAt,
          speech: speech,
        );
        openai = one.result;
        openaiErr = one.error;
      }

      final openaiOk = openai != null && _sttHasText(openai);
      final saarasOk = saaras != null && _sttHasText(saaras);
      final TranscriptResult? primary =
          openaiOk ? openai : (saarasOk ? saaras : openai ?? saaras);
      if (primary == null || !_sttHasText(primary)) {
        if (buttonNote) {
          _buttonNoteIds.remove(clip.id);
        }
        if (openaiErr != null || saarasErr != null) {
          throw openaiErr ?? saarasErr!;
        }
        await _store.upsertClip(
          clip.copyWith(
            status: 'silence',
            fullText: '',
            sttModel: openai?.model ?? saaras?.model,
            segments: const [],
            billedS: speech.speechDurationS,
            removedS: speech.originalDurationS - speech.speechDurationS,
            inputTokens: openai?.inputTokens ?? 0,
            outputTokens: openai?.outputTokens ?? 0,
            costUsd: (openai?.costUsd ?? 0) + (saaras?.costUsd ?? 0),
            clearAlt: true,
          ),
        );
        return;
      }

      if (buttonNote) {
        _buttonNoteIds.remove(clip.id);
        final text = primary.text.trim();
        await _store.upsertClip(
          clip.copyWith(
            fullText: '',
            sttModel: primary.model,
            status: 'note',
            segments: const [],
            billedS: speech.speechDurationS,
            removedS: speech.originalDurationS - speech.speechDurationS,
            inputTokens: openai?.inputTokens ?? 0,
            outputTokens: openai?.outputTokens ?? 0,
            costUsd: (openai?.costUsd ?? 0) + (saaras?.costUsd ?? 0),
            clearAlt: true,
          ),
        );
        if (text.isNotEmpty) {
          await _store.insertNote(
            SpokenNote(
              id: const Uuid().v4(),
              createdAt: clip.startedAt,
              text: text,
              clipId: clip.id,
              meetingId: _buttonNoteMeetingIds.remove(clip.id),
            ),
          );
          await _reload();
          if (mounted) {
            final preview =
                text.length > 80 ? '${text.substring(0, 80)}…' : text;
            final msg = 'Note saved: $preview';
            setState(() => _status = msg);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                duration: const Duration(seconds: 6),
                content: Text(msg),
              ),
            );
          }
        }
        return;
      }

      TranscriptResult? alt;
      var altError = '';
      if (SttPrefs.useBoth && openaiOk && saarasOk) {
        alt = saaras;
      } else if (SttPrefs.useBoth && openaiOk && !saarasOk) {
        altError = saarasErr?.toString() ?? 'Saaras returned no text';
      } else if (SttPrefs.useBoth && !openaiOk && saarasOk) {
        altError = openaiErr?.toString() ?? 'OpenAI returned no text';
      }

      final primarySegs = _sttSegs(primary);
      final journalSegs = segsWithoutNoteCommands(primarySegs);
      final journalText = joinSegmentText(journalSegs);
      final journalOk = journalSegs.isNotEmpty && journalText.isNotEmpty;
      final altSegs = alt == null
          ? const <TranscriptSegment>[]
          : segsWithoutNoteCommands(_sttSegs(alt));
      final altText = joinSegmentText(altSegs);

      await _store.upsertClip(
        clip.copyWith(
          fullText: journalText,
          sttModel: primary.model,
          status: journalOk ? 'ok' : 'note',
          segments: journalSegs,
          billedS: speech.speechDurationS,
          removedS: speech.originalDurationS - speech.speechDurationS,
          inputTokens: openai?.inputTokens ?? 0,
          outputTokens: openai?.outputTokens ?? 0,
          costUsd: primary.costUsd,
          altFullText: alt == null ? '' : altText,
          altSttModel: alt?.model,
          altCostUsd: alt?.costUsd ?? 0,
          altError: altError,
          altSegments: altSegs,
          clearAlt: !SttPrefs.useBoth,
        ),
      );
      if (cursorKickoff != null) {
        await cursorKickoff;
      } else {
        await _maybeCursorCommand(
          segs: _sttSegs(primary),
          fullText: primary.text,
        );
      }
      await _maybeSpokenNote(
        segs: _sttSegs(primary),
        fullText: primary.text,
        clipId: clip.id,
      );
    } catch (e) {
      _buttonNoteIds.remove(clip.id);
      await _store.upsertClip(clip.copyWith(status: 'error'));
      _toastSttFailed();
    }
  }

  void _toastSttFailed([String? message]) {
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 4),
        content: Text(message ?? 'Transcription failed'),
      ),
    );
  }

  Future<void> _maybeCursorCommand({
    required List<TranscriptSegment> segs,
    required String fullText,
  }) async {
    if (!Platform.isMacOS) {
      return;
    }
    await CursorPrefs.load();
    if (!CursorPrefs.enabled) {
      return;
    }
    final voices = await VoiceStore.list();
    final wearer = voices.isEmpty ? null : voices.first.name;
    final force = _commandNext;
    final prompt = cursorPromptFromClip(
      segs: segs,
      fallback: fullText,
      forceNext: force,
      wearer: wearer,
    );
    if (force && mounted) {
      setState(() => _commandNext = false);
    }
    if (prompt == null) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: prompt));
    var pasted = false;
    var pasteErr = '';
    if (CursorPrefs.pasteIntoCursor) {
      final r = await pasteIntoCursorComposer(
        autoSend: CursorPrefs.autoSend,
      );
      pasted = r.ok;
      pasteErr = r.detail;
    }
    if (!mounted) {
      return;
    }
    final preview = prompt.length > 80 ? '${prompt.substring(0, 80)}…' : prompt;
    final msg = pasted
        ? (CursorPrefs.autoSend
            ? 'Sent to Cursor: $preview'
            : 'Copied to Cursor: $preview')
        : 'Copied: $preview${pasteErr.isEmpty ? '. Click Composer, Cmd+V' : '. Paste failed: $pasteErr'}';
    setState(() => _status = msg);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(duration: const Duration(seconds: 8), content: Text(msg)),
    );
  }

  Future<void> _maybeSpokenNote({
    required List<TranscriptSegment> segs,
    required String fullText,
    required String clipId,
  }) async {
    await NotePrefs.load();
    if (!NotePrefs.enabled) {
      return;
    }
    final voices = await VoiceStore.list();
    final wearer = voices.isEmpty ? null : voices.first.name;
    final note = calendarNoteFromClip(
      segs: segs,
      fallback: fullText,
      wearer: wearer,
    );
    if (note == null) {
      return;
    }
    try {
      await _store.insertNote(
        SpokenNote(
          id: const Uuid().v4(),
          createdAt: DateTime.now().toUtc(),
          text: note,
          clipId: clipId,
          meetingId: _armed ? _sessionId : null,
        ),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save note: $e')),
      );
      return;
    }
    await _reload();
    if (!mounted) {
      return;
    }
    final preview = note.length > 80 ? '${note.substring(0, 80)}…' : note;
    final msg = 'Note saved: $preview';
    setState(() => _status = msg);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(duration: const Duration(seconds: 6), content: Text(msg)),
    );
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
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          onOpenDeveloper: () {
            Navigator.of(context).pop();
            _openDeveloper();
          },
          onOpenCalibrate: () {
            Navigator.of(context).pop();
            _openCalibrate();
          },
        ),
      ),
    );
    await CursorPrefs.load();
    await NotePrefs.load();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openDeveloper() async {
    _syncDev(force: true);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ListenableBuilder(
          listenable: _dev,
          builder: (context, _) => DeveloperPage(
            live: _dev,
            rangeBar: _rangeBar(),
          ),
        ),
      ),
    );
    await _reload();
  }

  Future<void> _openMemories() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MemoriesPage(
          onOpenDay: _selectDay,
          store: _store,
        ),
      ),
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
    final now = DateTime.now();
    setState(() {
      _rangeFrom = DateTime(now.year, now.month, now.day);
      _rangeTo = DateTime(now.year, now.month, now.day, 23, 59, 59);
    });
    await _reload();
  }

  String _fmtBound(DateTime? t) {
    if (t == null) {
      return 'Choose';
    }
    return DateFormat('MMM d, HH:mm').format(t);
  }

  Widget _rangeBar() {
    final now = DateTime.now();
    final hourStart = DateTime(now.year, now.month, now.day, now.hour);
    final todayStart = DateTime(now.year, now.month, now.day);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
            TextButton(onPressed: _clearRange, child: const Text('Today')),
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
              label: const Text('Yesterday'),
              onPressed: () {
                final y = todayStart.subtract(const Duration(days: 1));
                _applyRange(
                  y,
                  todayStart.subtract(const Duration(milliseconds: 1)),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _renameSpeaker(String from, String to) async {
    await _store.renameSpeaker(from: from, to: to);
    await _reload();
  }

  Future<void> _openMeeting(MeetingRecord meeting,
      {bool developer = false}) async {
    if (!mounted) {
      return;
    }
    if (developer) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ClipPage.range(
            segments: meeting.segments,
            clips: meeting.clips,
            title: meeting.timeRangeLabel(now: DateTime.now()),
            onRenameSpeaker: _renameSpeaker,
            showDeveloper: true,
            header: _meetingDetailHeader(meeting),
          ),
        ),
      );
      await _reload();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MeetingDetailPage(
          meeting: meeting,
          onRecap: () => _cleanMeeting(meeting),
          reload: () async {
            await _reload();
            for (final m in _meetings) {
              if (m.id == meeting.id) {
                return m;
              }
            }
            return null;
          },
        ),
      ),
    );
    await _reload();
  }

  Widget _meetingDetailHeader(MeetingRecord meeting) {
    final recap = meeting.recap;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (meeting.live || (_armed && meeting.id == _sessionId))
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Live meeting'),
          ),
        if (recap != null) ...[
          Text(
            recap.headline.isEmpty ? 'Recap' : recap.headline,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
          if (recap.arc.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(recap.arc),
          ],
          const SizedBox(height: 12),
        ],
        FilledButton.tonalIcon(
          onPressed: _cleaning ? null : () => _cleanMeeting(meeting),
          icon: _cleaning
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_fix_high),
          label: Text(_cleaning ? 'Recapping…' : 'Recap this meeting'),
        ),
        if (meeting.notes.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('Notes in this meeting',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final n in meeting.notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('• ${n.text}'),
            ),
        ],
        const SizedBox(height: 8),
        const Text('Transcript', style: TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }

  String _greeting() {
    final h = DateTime.now().hour;
    final name = _wearerName.isEmpty ? '' : ', $_wearerName';
    if (h < 12) {
      return 'Good morning$name.';
    }
    if (h < 17) {
      return 'Good afternoon$name.';
    }
    return 'Good evening$name.';
  }

  String _batteryLabel() {
    final s = _dbg;
    if (!_connected) {
      return _busy ? 'Connecting…' : 'Connect';
    }
    if (s == null) {
      return 'Connected';
    }
    if (s.usbPowered) {
      return 'Connected · USB';
    }
    if (s.batteryPct != null) {
      return 'Connected · ${s.batteryPct}%';
    }
    return 'Connected';
  }

  String get _hostMicLabel {
    if (Platform.isIOS) {
      return 'iPhone';
    }
    if (Platform.isMacOS) {
      return 'Mac';
    }
    return 'phone';
  }

  MeetingRecord? get _currentMeeting {
    final id = _sessionId;
    if (id == null) {
      return null;
    }
    for (final m in _meetings) {
      if (m.id == id) {
        return m;
      }
    }
    return null;
  }

  Future<void> _toggleVoiceNote() async {
    if (_busy) {
      return;
    }
    if (_noteHolding || _noteTempArm || _noteUsingDeviceMic) {
      await _stopScreenNote();
      return;
    }
    setState(() => _noteHolding = true);
    _noteBegin = _beginButtonNote();
    await _noteBegin;
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _stopScreenNote() async {
    if (_noteStopping) {
      await _noteBegin;
      return;
    }
    _noteStopping = true;
    try {
      await _noteBegin;
      if (!_noteHolding && !_noteTempArm && !_noteUsingDeviceMic) {
        return;
      }
      _noteHolding = false;
      await _endButtonNote();
    } finally {
      _noteStopping = false;
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _markMoment() async {
    await _store.insertNote(
      SpokenNote(
        id: const Uuid().v4(),
        createdAt: DateTime.now().toUtc(),
        text: 'Marked moment',
        meetingId: _sessionId,
      ),
    );
    await _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Moment marked')),
      );
    }
  }

  String _friendlyBleError(Object e) {
    final s = e.toString();
    if (s.contains('bluetooth must be turned on') ||
        s.contains('CBManagerState')) {
      return 'Turn Bluetooth on, then tap Connect pendant.';
    }
    if (s.contains('permission')) {
      return 'Allow Bluetooth for OpenPendant, then tap Connect pendant.';
    }
    return s;
  }

  Future<void> _connectPendant() async {
    if (_busy) {
      return;
    }
    if (_connected) {
      await _disconnectPendant();
      return;
    }
    if (_ble.device != null) {
      await _manualReconnect();
    } else {
      await _connect();
    }
  }

  Future<void> _disconnectPendant() async {
    _autoReconnect = false;
    _resumeAfterReconnect = false;
    if (_armed && !_usingDeviceMic) {
      await _disarm(flush: true, keepSession: false);
    }
    await _ble.disconnect();
    if (!mounted) {
      return;
    }
    setState(() {
      _connected = false;
      _dbg = null;
      if (!_usingDeviceMic) {
        _armed = false;
        _showLive = false;
      }
      _status = 'Disconnected. Tap Connect pendant.';
    });
  }

  Future<void> _onStartMeetingTapped() async {
    if (_busy) {
      return;
    }
    await _toggleMeeting();
  }

  Widget _phoneShell({required Widget child, Widget? bottom}) {
    final wide = MediaQuery.sizeOf(context).width > 640;
    final scaffold = Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(child: child),
      bottomNavigationBar: bottom == null
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: LiquidGlass(
                radius: 30,
                child: bottom,
              ),
            ),
    );
    final layered = Stack(
      fit: StackFit.expand,
      children: [
        const MeshBackdrop(),
        scaffold,
      ],
    );
    if (!wide) {
      return layered;
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        const MeshBackdrop(),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: scaffold,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final live = _armed && _showLive;
    return _phoneShell(
      bottom: live
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.wb_sunny_outlined),
                  selectedIcon: Icon(Icons.wb_sunny),
                  label: 'Today',
                ),
                NavigationDestination(
                  icon: Icon(Icons.forum_outlined),
                  selectedIcon: Icon(Icons.forum),
                  label: 'Meetings',
                ),
                NavigationDestination(
                  icon: Icon(Icons.bolt_outlined),
                  selectedIcon: Icon(Icons.bolt),
                  label: 'Notes',
                ),
                NavigationDestination(
                  icon: Icon(Icons.search),
                  label: 'Search',
                ),
              ],
            ),
      child: live ? _liveScreen() : _tabScreen(),
    );
  }

  Widget _tabScreen() {
    switch (_tab) {
      case 1:
        return _meetingsTab();
      case 2:
        return _notesTab();
      case 3:
        return _searchTab();
      default:
        return _todayTab();
    }
  }

  Widget _headerRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
      child: Row(
        children: [
          const Text(
            'OpenPendant',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 20,
              letterSpacing: -0.4,
            ),
          ),
          const Spacer(),
          Flexible(
            child: GestureDetector(
              onTap: _busy ? null : _connectPendant,
              child: LiquidGlass(
                radius: 20,
                prominent: !_connected,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  child: Text(
                    '• ${_batteryLabel()}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _connected ? AppColors.rule : AppColors.ink,
                    ),
                  ),
                ),
              ),
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz),
            onSelected: (v) {
              switch (v) {
                case 'settings':
                  _openSettings();
                case 'people':
                  _openVoices();
                case 'memories':
                  _openMemories();
                case 'calibrate':
                  _openCalibrate();
                case 'developer':
                  _openDeveloper();
                case 'sleep':
                  _sleep();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'settings', child: Text('Settings')),
              PopupMenuItem(value: 'people', child: Text('People')),
              PopupMenuItem(value: 'memories', child: Text('Memories')),
              PopupMenuItem(value: 'calibrate', child: Text('Calibrate')),
              PopupMenuItem(value: 'developer', child: Text('Developer')),
              PopupMenuItem(value: 'sleep', child: Text('Sleep pendant')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _todayTab() {
    final recent =
        <({String title, String sub, IconData icon, VoidCallback tap})>[
      for (final m in _meetings)
        (
          title: m.preview.isEmpty
              ? m.timeRangeLabel(now: DateTime.now())
              : m.preview,
          sub: [
            m.durationAt(DateTime.now()).inMinutes > 0
                ? '${m.durationAt(DateTime.now()).inMinutes} min'
                : SceneGroup.clock(m.startedAt.toLocal()),
            if (m.recap != null && m.recap!.followUps.isNotEmpty)
              '${m.recap!.followUps.length} action items',
            if (m.live || (_armed && m.id == _sessionId)) 'Live',
          ].join(' · '),
          icon: Icons.forum_outlined,
          tap: () {
            if (_armed && m.id == _sessionId) {
              setState(() => _showLive = true);
            } else {
              _openMeeting(m);
            }
          },
        ),
      for (final n in _notes)
        (
          title: n.text,
          sub: 'Voice note · ${DateFormat.jm().format(n.createdAt.toLocal())}',
          icon: Icons.bolt,
          tap: () => setState(() => _tab = 2),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _headerRow(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              Text(
                _greeting(),
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  height: 1.15,
                  letterSpacing: -0.6,
                  color: AppColors.ink,
                ),
              ),
              if (_status.isNotEmpty && !_armed) ...[
                const SizedBox(height: 8),
                Text(
                  _status,
                  style: const TextStyle(color: AppColors.muted, fontSize: 13),
                ),
              ],
              const SizedBox(height: 20),
              _actionCard(
                prominent: true,
                fg: AppColors.ink,
                icon: _armed ? Icons.stop_circle_outlined : Icons.graphic_eq,
                title: _armed ? 'End meeting' : 'Start a meeting',
                sub: _armed
                    ? (_usingDeviceMic
                        ? 'Recording with this $_hostMicLabel mic'
                        : 'Or press the pendant once')
                    : (_connected
                        ? 'Press pendant once, or tap here.'
                        : 'Uses this $_hostMicLabel mic. Connect the pendant for necklace audio.'),
                onTap: _busy ? null : _onStartMeetingTapped,
              ),
              const SizedBox(height: 12),
              _actionCard(
                prominent: _noteHolding,
                fg: AppColors.ink,
                icon: _noteHolding ? Icons.mic : Icons.bolt,
                iconColor: _noteHolding ? AppColors.ink : AppColors.bolt,
                title: _noteHolding ? 'Stop note' : 'Capture a quick note',
                sub: _noteHolding
                    ? 'Recording — tap to save'
                    : (_connected
                        ? 'Tap here, or long-press pendant.'
                        : 'Uses this $_hostMicLabel mic. Tap to record.'),
                onTap: _busy ? null : _toggleVoiceNote,
              ),
              const SizedBox(height: 28),
              const Text(
                'Recent',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 8),
              if (recent.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'Nothing today yet. Start a meeting or capture a note.',
                    style: TextStyle(color: AppColors.muted),
                  ),
                )
              else
                for (final r in recent.take(8))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: AppColors.mint,
                      child: Icon(r.icon, color: AppColors.ink, size: 18),
                    ),
                    title: Text(
                      r.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(r.sub),
                    trailing:
                        const Icon(Icons.chevron_right, color: AppColors.muted),
                    onTap: r.tap,
                  ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _actionCard({
    required Color fg,
    required IconData icon,
    required String title,
    required String sub,
    required VoidCallback? onTap,
    Color? iconColor,
    bool prominent = false,
  }) {
    final radius = BorderRadius.circular(28);
    return LiquidGlass(
      radius: 28,
      prominent: prominent,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 22, color: iconColor ?? AppColors.rule),
                const SizedBox(height: 22),
                Text(
                  title,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w700,
                    fontSize: 22,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  sub,
                  style: TextStyle(
                    color: fg.withValues(alpha: 0.62),
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _meetingsTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _headerRow(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(
            'Meetings · ${DateFormat.MMMd().format(_selectedDay)}',
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 20,
              letterSpacing: -0.4,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final day in _stripDays())
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(_stripLabel(day)),
                      selected: _sameDay(day, _selectedDay),
                      onSelected: (_) => _selectDay(day),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: _meetings.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No meetings this day. Press the pendant or start from Today.',
                    style: TextStyle(color: AppColors.muted),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  itemCount: _meetings.length,
                  itemBuilder: (context, i) {
                    final meeting = _meetings[i];
                    final live = _armed && meeting.id == _sessionId;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: LiquidGlass(
                        radius: 22,
                        blur: false,
                        child: ListTile(
                          title: Text(
                            [
                              if (live) 'Live · ',
                              meeting.timeRangeLabel(now: DateTime.now()),
                            ].join(),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(
                            meeting.preview.isEmpty
                                ? 'No transcript yet'
                                : meeting.preview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            if (live) {
                              setState(() => _showLive = true);
                            } else {
                              _openMeeting(meeting);
                            }
                          },
                          onLongPress: () =>
                              _openMeeting(meeting, developer: true),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _notesTab() {
    final meetingById = {for (final m in _meetings) m.id: m};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _headerRow(),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(
            'Notes',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 20,
              letterSpacing: -0.4,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: FilledButton.tonal(
            onPressed: _busy ? null : _toggleVoiceNote,
            child: Text(_noteHolding ? 'Stop note' : 'Capture a quick note'),
          ),
        ),
        Expanded(
          child: _notes.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No notes this day. Tap to record on this device, or long-press the pendant.',
                    style: TextStyle(color: AppColors.muted),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  itemCount: _notes.length,
                  itemBuilder: (context, i) {
                    final n = _notes[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: LiquidGlass(
                        radius: 22,
                        blur: false,
                        child: ListTile(
                          title: Text(n.text),
                          subtitle: Text(_noteSubtitle(n, meetingById)),
                          trailing: IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () async {
                              await _store.deleteNote(n.id);
                              await _reload();
                            },
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _searchTab() {
    final meetingById = {for (final m in _meetings) m.id: m};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _headerRow(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: TextField(
            controller: _search,
            decoration: InputDecoration(
              hintText: 'Search notes and meetings',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: const Color(0x99FFFFFF),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: (_) => _reload(),
            onSubmitted: (_) => _reload(),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
            children: [
              for (final n in _notes)
                ListTile(
                  leading: const Icon(Icons.bolt, color: AppColors.teal),
                  title: Text(n.text),
                  subtitle: Text(_noteSubtitle(n, meetingById)),
                  onTap: () => setState(() => _tab = 2),
                ),
              for (final m in _meetings)
                ListTile(
                  leading:
                      const Icon(Icons.forum_outlined, color: AppColors.teal),
                  title: Text(
                    m.preview.isEmpty
                        ? m.timeRangeLabel(now: DateTime.now())
                        : m.preview,
                  ),
                  subtitle: Text(m.timeRangeLabel(now: DateTime.now())),
                  onTap: () => _openMeeting(m),
                ),
              if (_notes.isEmpty && _meetings.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No matches this day.',
                    style: TextStyle(color: AppColors.muted),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _liveScreen() {
    final meeting = _currentMeeting;
    final title = meeting?.recap?.headline.trim().isNotEmpty == true
        ? meeting!.recap!.headline.trim()
        : 'Meeting';
    final imu = _dbg?.imuSleep == true;
    final segs = meeting?.segments ?? const <TranscriptSegment>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 0),
          child: Row(
            children: [
              IconButton(
                onPressed: () => setState(() => _showLive = false),
                icon: const Icon(Icons.arrow_back_ios_new, size: 18),
              ),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              LiquidGlass(
                radius: 16,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  child: const Text(
                    '• LIVE',
                    style: TextStyle(
                      color: AppColors.live,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          _meetingElapsed().isEmpty ? '00:00' : _meetingElapsed(),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 56,
            fontWeight: FontWeight.w200,
            letterSpacing: 1.5,
            color: AppColors.ink,
          ),
        ),
        const Text(
          'Recording',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.live,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: LiquidGlass(
            radius: 20,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Text(
                _usingDeviceMic
                    ? 'Recording with this $_hostMicLabel mic'
                    : (_connected
                        ? (imu
                            ? 'OpenPendant connected · resting'
                            : 'OpenPendant connected · audio clear')
                        : 'Pendant disconnected'),
                style: const TextStyle(
                  color: AppColors.rule,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 18, 28, 8),
          child: _WaveBars(levels: _levels),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            children: [
              TranscriptThread(segments: segs),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _markMoment,
                  child: const Text('+ Mark moment'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _toggleVoiceNote,
                  child: Text(_noteHolding ? 'Stop note' : '+ Private note'),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.live,
              side: const BorderSide(color: Color(0x66FF3B30)),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: const StadiumBorder(),
            ),
            onPressed: _busy ? null : _toggleMeeting,
            child: const Column(
              children: [
                Text(
                  'End meeting',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
                Text(
                  'or press pendant once',
                  style: TextStyle(fontSize: 12, color: AppColors.muted),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _noteSubtitle(SpokenNote n, Map<String, MeetingRecord> meetings) {
    final when = DateFormat.jm().format(n.createdAt.toLocal());
    final m = n.meetingId == null ? null : meetings[n.meetingId!];
    if (m == null) {
      return when;
    }
    return '$when · in ${SceneGroup.clock(m.startedAt.toLocal())} meeting';
  }
}

class _WaveBars extends StatelessWidget {
  const _WaveBars({required this.levels});

  final List<double> levels;

  @override
  Widget build(BuildContext context) {
    final bars = levels.isEmpty ? List<double>.filled(20, 0.12) : levels;
    return SizedBox(
      height: 56,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final l in bars)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.2),
                child: FractionallySizedBox(
                  heightFactor: l.clamp(0.08, 1.0),
                  alignment: Alignment.bottomCenter,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.rule,
                      borderRadius: BorderRadius.all(Radius.circular(1)),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
