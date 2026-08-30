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
  final _noteDraft = TextEditingController();

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
  List<MeetingRecord> _meetings = [];
  List<SpokenNote> _notes = [];
  List<TranscriptSegment> _rangeSegs = [];
  bool _cleaning = false;
  bool _commandNext = false;
  bool _noteHolding = false;
  bool _noteTempArm = false;
  int _noteFromByte = 0;
  int _btnSeqSeen = 0;
  bool _btnSeqPrimed = false;
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
    _noteDraft.dispose();
    _dev.dispose();
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
    _syncButtonNote(s);
    _syncDev();
    if (!_armed || _noteHolding) {
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
    if (!_connected) {
      _noteHolding = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Connect the pendant to take a note.')),
        );
      }
      return;
    }
    try {
      if (!_armed) {
        _noteTempArm = true;
        await _ble.startRecording(_onPcm);
        _noteFromByte = 0;
      } else {
        _noteTempArm = false;
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
        setState(() => _status = 'Note… hold to talk, release to save');
      }
    } catch (e) {
      _noteHolding = false;
      _noteTempArm = false;
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
        await _ble.stopRecording();
      } catch (_) {}
      _ble.reassembler.reset();
      _noteTempArm = false;
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

  String _dayHeading() {
    final day = _selectedDay;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final full = DateFormat.yMMMMEEEEd().format(day);
    if (_sameDay(day, today)) {
      return '$full · Today';
    }
    if (_sameDay(day, yesterday)) {
      return '$full · Yesterday';
    }
    return full;
  }

  Future<void> _cleanMeeting(MeetingRecord meeting) async {
    final segs = meeting.segments.where((s) => s.text.trim().isNotEmpty).toList();
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
        const SnackBar(content: Text('Add an OpenAI API key in Settings first.')),
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
        rangeLabel:
            '${DateFormat.MMMd().add_jm().format(start)} – '
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

  Future<void> _toggleMeeting() async {
    if (_busy || !_connected) {
      return;
    }
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
      await _ble.startRecording(_onPcm);
      _armTick?.cancel();
      _armTick = Timer.periodic(const Duration(milliseconds: 200), (_) => _onArmTick());
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
    if (_hadSpeechInChunk &&
        now.difference(_lastSpeechAt ?? now) >= quiet) {
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
        ? '…'
        : (_dbg!.imuSleep ? 'Resting' : 'Listening');
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
          _status = keepSession
              ? 'Chunk flushed. Reconnecting…'
              : 'Meeting ended.';
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
    if ((needOpenAi && openaiKey.isEmpty) || (needSarvam && sarvamKey.isEmpty)) {
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
    final pcm = full.length > 44 &&
            String.fromCharCodes(full.sublist(0, 4)) == 'RIFF'
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
    await File(speechPath).writeAsBytes(pcmToWav(pcm: speech.speechPcm), flush: true);
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
      final TranscriptResult? primary = openaiOk
          ? openai
          : (saarasOk ? saaras : openai ?? saaras);
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

  Future<void> _addTypedNote() async {
    final text = _noteDraft.text.trim();
    if (text.isEmpty) {
      return;
    }
    try {
      await _store.insertNote(
        SpokenNote(
          id: const Uuid().v4(),
          createdAt: DateTime.now().toUtc(),
          text: text,
          meetingId: _armed ? _sessionId : null,
        ),
      );
      _noteDraft.clear();
      await _reload();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Note saved')),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save note: $e')),
      );
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

  Future<void> _openMeeting(MeetingRecord meeting, {bool developer = false}) async {
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ClipPage.range(
          segments: meeting.segments,
          clips: meeting.clips,
          title: meeting.timeRangeLabel(now: DateTime.now()),
          onRenameSpeaker: _renameSpeaker,
          showDeveloper: developer,
          header: _meetingDetailHeader(meeting),
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

  @override
  Widget build(BuildContext context) {
    final recLabel = _armed ? 'End meeting' : 'Start meeting';
    final selected = _selectedDay;
    final meetingsLabel =
        'Meetings · ${DateFormat.MMMd().format(selected)}';
    final meetingById = {for (final m in _meetings) m.id: m};
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
            tooltip: 'Memories',
            icon: const Icon(Icons.auto_awesome),
            onPressed: _openMemories,
          ),
          IconButton(
            tooltip: 'People',
            icon: const Icon(Icons.record_voice_over),
            onPressed: _openVoices,
          ),
          IconButton(
            tooltip: 'Settings',
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
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: Row(
                    children: [
                      Chip(
                        avatar: Icon(
                          _noteHolding
                              ? Icons.edit_note
                              : (_armed ? Icons.groups : Icons.power_settings_new),
                          size: 18,
                        ),
                        label: Text(_wearerLabel()),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _status,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
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
                        onPressed: _busy || !_connected ? null : _toggleMeeting,
                        child: Text(recLabel),
                      ),
                      OutlinedButton(
                        onPressed: _busy || (!_connected && !_armed)
                            ? null
                            : _sleep,
                        child: const Text('Sleep'),
                      ),
                      if (Platform.isMacOS && CursorPrefs.enabled)
                        FilterChip(
                          label: Text(_commandNext ? 'Command next' : 'Command'),
                          selected: _commandNext,
                          onSelected: (on) => setState(() => _commandNext = on),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
                  child: Text(
                    _dayHeading(),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final day in _stripDays())
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: FilterChip(
                              label: Text(_stripLabel(day)),
                              selected: _sameDay(day, selected),
                              onSelected: (_) => _selectDay(day),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
                  child: Text(
                    'Notes · ${DateFormat.MMMd().format(selected)}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _noteDraft,
                          decoration: const InputDecoration(
                            hintText: 'Hold the button to talk, or type a note',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onSubmitted: (_) => _addTypedNote(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _addTypedNote,
                        child: const Text('Add'),
                      ),
                    ],
                  ),
                ),
                if (_notes.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Text('No notes this day. Hold the pendant button to capture one.'),
                  )
                else
                  for (final n in _notes)
                    Card(
                      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: ListTile(
                        title: Text(n.text),
                        subtitle: Text(_noteSubtitle(n, meetingById)),
                        trailing: IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.close),
                          onPressed: () async {
                            await _store.deleteNote(n.id);
                            await _reload();
                          },
                        ),
                      ),
                    ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
                  child: Text(
                    meetingsLabel,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      hintText: 'Search notes and meetings',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.search),
                    ),
                    onSubmitted: (_) => _reload(),
                    onChanged: (_) => _reload(),
                  ),
                ),
              ],
            ),
          ),
          if (_meetings.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No meetings this day. Click the pendant button or Start meeting.',
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final meeting = _meetings[i];
                  final people = meeting.displaySpeakers.join(', ');
                  final live = _armed && meeting.id == _sessionId;
                  return Card(
                    margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ListTile(
                          isThreeLine: true,
                          title: Text(
                            [
                              if (live) 'Live · ',
                              meeting.timeRangeLabel(now: DateTime.now()),
                            ].join(),
                          ),
                          subtitle: Text(
                            [
                              if (people.isNotEmpty) people,
                              if (meeting.notes.isNotEmpty)
                                '${meeting.notes.length} note${meeting.notes.length == 1 ? '' : 's'}',
                              meeting.preview.isEmpty
                                  ? 'No transcript yet'
                                  : meeting.preview,
                            ].join('\n'),
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _openMeeting(meeting),
                          onLongPress: () =>
                              _openMeeting(meeting, developer: true),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: _busy || _cleaning
                                  ? null
                                  : () => _cleanMeeting(meeting),
                              icon: const Icon(Icons.auto_fix_high, size: 18),
                              label: Text(
                                meeting.recap == null
                                    ? 'Recap'
                                    : 'Refresh recap',
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
                childCount: _meetings.length,
              ),
            ),
        ],
      ),
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
