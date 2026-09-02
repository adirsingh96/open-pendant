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
import '../ble/pendant_prefs.dart';
import '../db/clip_store.dart';
import '../db/day_recap.dart';
import '../db/meeting.dart';
import '../db/models.dart';
import '../stt/api_key_store.dart';
import '../stt/cursor_command.dart';
import '../stt/cursor_prefs.dart';
import '../macos/cursor_composer.dart';
import '../stt/openai_refine.dart';
import '../stt/openai_stt.dart';
import '../stt/saaras_stt.dart';
import '../stt/sarvam_key_store.dart';
import '../stt/speaker_spans.dart';
import '../stt/stt_prefs.dart';
import '../stt/voice_store.dart';
import 'clip_page.dart';
import 'calibrate_page.dart';
import 'developer_page.dart';
import 'settings_page.dart';
import 'voices_page.dart';
import 'app_theme.dart';
import 'aurora_orb.dart';
import 'pendant_connect_sheet.dart';
import 'circle_button.dart';
import 'edge_glow.dart';
import 'liquid_glass.dart';
import 'meeting_detail_page.dart';
import 'mesh_backdrop.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'page_scaffold.dart';
import 'pendant_chip.dart';
import 'transcript_bubbles.dart';
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

  String _status = '';
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
  /// True when Capture on the phone started the note. Pendant status still
  /// reports `noteHeld: false`, so those packets must not end an in-app note.
  bool _noteFromApp = false;
  DateTime? _noteStartedAt;
  Timer? _noteTick;
  bool _noteTempArm = false;
  bool _noteUsingDeviceMic = false;
  bool _noteStopping = false;
  int _noteFromByte = 0;
  int _btnSeqSeen = 0;
  bool _btnSeqPrimed = false;
  int _tab = 0;
  int _libTab = 0;
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
    PendantPrefs.load().then((_) {
      if (mounted) {
        setState(() {});
      }
    });
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
    _noteTick?.cancel();
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
    PendantPrefs.lastSeen = DateTime.now();
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
      _noteFromApp = false;
      _noteHolding = true;
      _noteBegin = _beginButtonNote();
    } else if (!held && _noteHolding && !_noteFromApp) {
      _noteHolding = false;
      unawaited(_endButtonNote());
    }
  }

  Future<void> _beginButtonNote() async {
    await NotePrefs.load();
    if (!NotePrefs.enabled) {
      _noteHolding = false;
      _noteFromApp = false;
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
      _noteStartedAt = DateTime.now();
      _noteTick?.cancel();
      _noteTick = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted && _noteHolding) {
          setState(() {});
        }
      });
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      _noteHolding = false;
      _noteFromApp = false;
      _noteTempArm = false;
      _noteStartedAt = null;
      _noteTick?.cancel();
      _noteTick = null;
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
    _noteStartedAt = null;
    _noteTick?.cancel();
    _noteTick = null;
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
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = '$e');
      }
    }
  }

  /// Note finished transcribing: confirm quietly and take the user to it.
  void _onNoteSaved() {
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 2),
        content: Text('Note saved'),
      ),
    );
    if (!_armed && !_noteHolding && !_showLive) {
      setState(() {
        _tab = 1;
        _libTab = 1;
      });
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
    if (_sameDay(day, today)) {
      return 'Today';
    }
    if (_sameDay(day, yesterday)) {
      return 'Yesterday';
    }
    return DateFormat('EEE d').format(day);
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
        rangeLabel: '${DateFormat.MMMd().add_jm().format(start)} to '
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

  void _onConnectionLost() {
    if (!mounted || _autoReconnect) {
      return;
    }
    unawaited(PendantPrefs.markSeen());
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
    _noteFromApp = false;
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
        unawaited(
          PendantPrefs.markSeen(deviceName: _ble.device?.platformName),
        );
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

  Future<void> _toggleMeeting() async {
    if (_busy) {
      return;
    }
    if (_armed) {
      final endedId = _sessionId;
      await _disarm(flush: true, keepSession: false);
      if (mounted) {
        setState(() => _showLive = false);
      }
      if (endedId != null) {
        await _reload();
        if (!mounted) {
          return;
        }
        for (final m in _meetings) {
          if (m.id == endedId) {
            await _openMeeting(m);
            break;
          }
        }
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
    if (pcmHasVoice(
      last,
      energyFloor:
          _noteHolding ? VadGate.energyFloor : VadGate.meetingEnergyFloor,
    )) {
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
      _noteFromApp = false;
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
    return SttPrefs.diarize ? 'Saaras+diarize' : 'Saaras v4';
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
          preferDiarize: true,
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
      return (
        result: await _saaras.transcribe(
          wav: wav,
          apiKey: apiKey,
          startedAt: startedAt,
          speech: speech,
        ),
        error: null,
      );
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
    if (wavPath == null || !File(wavPath).existsSync()) {
      _buttonNoteIds.remove(clip.id);
      await _store.upsertClip(clip.copyWith(status: 'error'));
      return;
    }
    try {
    if (sarvamKey.isEmpty) {
      _buttonNoteIds.remove(clip.id);
      await _store.upsertClip(clip.copyWith(status: 'error'));
      _toastSttFailed('No Sarvam API key. Add it in Settings.');
      return;
    }

    final full = await File(wavPath).readAsBytes();
    final pcm =
        full.length > 44 && String.fromCharCodes(full.sublist(0, 4)) == 'RIFF'
            ? full.sublist(44)
            : full;
    final speech = extractSpeech(
      pcm,
      energyFloor: buttonNote
          ? VadGate.energyFloor
          : VadGate.meetingEnergyFloor,
      minSpeechS: buttonNote ? 0.12 : VadGate.meetingMinSpeechS,
    );
    if (speech.speechDurationS <
        (buttonNote ? 0.12 : VadGate.meetingMinSpeechS)) {
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
      TranscriptResult? openai;
      TranscriptResult? saaras;
      Object? openaiErr;
      Object? saarasErr;
      final wantDiarize =
          SttPrefs.diarize && !buttonNote && openaiKey.isNotEmpty;
      final saarasF = _trySaaras(
        wav: wav,
        apiKey: sarvamKey,
        startedAt: clip.startedAt,
        speech: speech,
      );
      final openaiF = wantDiarize
          ? _tryOpenai(
              wav: wav,
              apiKey: openaiKey,
              startedAt: clip.startedAt,
              speech: speech,
            )
          : null;
      final s = await saarasF;
      saaras = s.result;
      saarasErr = s.error;
      if (openaiF != null) {
        final o = await openaiF;
        openai = o.result;
        openaiErr = o.error;
        final openaiNamed = openai != null &&
            openai.segments.any((x) => (x.speaker ?? '').trim().isNotEmpty);
        if (saaras != null && openaiNamed) {
          saaras = overlayDiarization(words: saaras, diarize: openai);
        }
      }

      final openaiOk = openai != null && _sttHasText(openai);
      final saarasOk = saaras != null && _sttHasText(saaras);
      final TranscriptResult? primary =
          saarasOk ? saaras : (openaiOk ? openai : openai ?? saaras);
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
        final segs = _sttSegs(primary);
        final text = noteTextWithoutSpeakers(
          joinUnlabeledSegmentText(segs).isNotEmpty
              ? joinUnlabeledSegmentText(segs)
              : primary.text.trim(),
        );
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
          _onNoteSaved();
        }
        return;
      }

      final primarySegs = _sttSegs(primary);
      final journalSegs = segsWithoutNoteCommands(primarySegs);
      final journalText = joinSegmentText(journalSegs);
      final journalOk = journalSegs.isNotEmpty && journalText.isNotEmpty;

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
          costUsd: (openai?.costUsd ?? 0) + (saaras?.costUsd ?? 0),
          clearAlt: true,
        ),
      );
      await _maybeCursorCommand(
        segs: _sttSegs(primary),
        fullText: primary.text,
      );
      await _maybeSpokenNote(
        segs: _sttSegs(primary),
        fullText: primary.text,
        clipId: clip.id,
      );
    } catch (e) {
      _buttonNoteIds.remove(clip.id);
      await _store.upsertClip(clip.copyWith(status: 'error'));
      _toastSttFailed();
    } finally {
      await _discardClipAudio(clip);
    }
  }

  Future<void> _discardClipAudio(ClipRecord clip) async {
    final wavPath = clip.wavPath;
    if (wavPath == null || wavPath.isEmpty) {
      return;
    }
    for (final path in [
      wavPath,
      p.join(p.dirname(wavPath), '${clip.id}_speech.wav'),
    ]) {
      try {
        final f = File(path);
        if (await f.exists()) {
          await f.delete();
        }
      } catch (_) {}
    }
    try {
      await _store.clearWavPath(clip.id);
    } catch (_) {}
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
    final unlabeled = joinUnlabeledSegmentText(segs);
    final note = calendarNoteFromClip(
      segs: segs,
      fallback: unlabeled.isNotEmpty
          ? unlabeled
          : noteTextWithoutSpeakers(fullText),
      wearer: wearer,
    );
    if (note == null) {
      return;
    }
    final body = noteTextWithoutSpeakers(note);
    if (body.isEmpty) {
      return;
    }
    try {
      await _store.insertNote(
        SpokenNote(
          id: const Uuid().v4(),
          createdAt: DateTime.now().toUtc(),
          text: body,
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
    _onNoteSaved();
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
          onOpenVoices: () {
            Navigator.of(context).pop();
            _openVoices();
          },
          onOpenMemories: () {
            Navigator.of(context).pop();
            _openMemories();
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
          onRename: (title) => _store.renameMeeting(meeting.id, title),
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
              : const Icon(LucideIcons.sparkles, size: 16),
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
              child: Text('• ${noteTextWithoutSpeakers(n.text)}'),
            ),
        ],
        const SizedBox(height: 8),
        const Text('Transcript', style: TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }

  String _greetingWord() {
    final h = DateTime.now().hour;
    if (h < 12) {
      return 'Good morning';
    }
    if (h < 17) {
      return 'Good afternoon';
    }
    return 'Good evening';
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
    _noteFromApp = true;
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
      _noteFromApp = false;
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

  // ─── Presentation ─────────────────────────────────────────────────────

  double get _liveLevel => _levels.isEmpty ? 0 : _levels.last;

  String _noteElapsed() {
    final start = _noteStartedAt;
    if (start == null) {
      return '0:00';
    }
    final d = DateTime.now().difference(start);
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60);
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  bool get _pendantRecording =>
      _connected &&
      ((_armed && !_usingDeviceMic) || (_noteHolding && !_noteUsingDeviceMic));

  PendantChipState _chipState() {
    if (_connected) {
      return _pendantRecording
          ? PendantChipState.recording
          : PendantChipState.idle;
    }
    if (_busy || _autoReconnect) {
      return PendantChipState.connecting;
    }
    return PendantPrefs.paired
        ? PendantChipState.offline
        : PendantChipState.unpaired;
  }

  Future<String?> _connectForSheet() async {
    if (_connected) {
      return null;
    }
    setState(() => _busy = true);
    Future<String?> attempt() async {
      if (!await _blePerms()) {
        return 'Allow Bluetooth for OpenPendant in System Settings, then try again.';
      }
      if (_ble.device != null) {
        await _ble.reconnect();
      } else {
        final d = await _ble.scan();
        await _ble.connect(d);
      }
      if (!mounted) {
        return null;
      }
      setState(() {
        _connected = true;
        _autoReconnect = false;
        _status = '';
      });
      unawaited(
        PendantPrefs.markSeen(deviceName: _ble.device?.platformName),
      );
      return null;
    }

    try {
      return await attempt().timeout(
        const Duration(seconds: 35),
        onTimeout: () =>
            'Bluetooth did not respond. In System Settings, open Privacy and '
            'Security, then Bluetooth, and make sure OpenPendant is allowed.',
      );
    } catch (e) {
      return _friendlyBleError(e);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _openConnectFlow() async {
    await showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      builder: (_) => PendantConnectSheet(
        connect: _connectForSheet,
        lastStatus: () => _ble.lastStatus,
        name: PendantPrefs.paired ? PendantPrefs.name : 'Your pendant',
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  void _onPendantCardTap() {
    switch (_chipState()) {
      case PendantChipState.recording:
        if (_armed) {
          setState(() => _showLive = true);
        }
      case PendantChipState.idle:
        _showPendantSheet();
      case PendantChipState.connecting:
        break;
      case PendantChipState.offline:
      case PendantChipState.unpaired:
        _openConnectFlow();
    }
  }

  Future<void> _showPendantSheet() async {
    final s = _dbg;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) {
        String battery;
        if (s == null) {
          battery = 'Reading';
        } else if (s.usbPowered) {
          battery = 'Charging on USB';
        } else if (s.batteryPct != null) {
          battery = '${s.batteryPct}%';
        } else {
          battery = 'Reading';
        }
        final motion = s == null
            ? 'Reading'
            : s.imuSleep
                ? 'Resting, mic paused'
                : 'Awake';
        Widget row(String k, String v) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  Text(k.toUpperCase(), style: AppText.micro),
                  const Spacer(),
                  Text(v, style: AppText.body.copyWith(fontSize: 13.5)),
                ],
              ),
            );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(26, 2, 26, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SheetHandle(),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: AppColors.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 9),
                    Text(PendantPrefs.name, style: AppText.title),
                    const Spacer(),
                    Text('CONNECTED', style: AppText.microAccent),
                  ],
                ),
                const SizedBox(height: 16),
                row('Battery', battery),
                row('Motion', motion),
                const SizedBox(height: 20),
                OutlinedButton(
                  onPressed: () {
                    Navigator.pop(sheetCtx);
                    _disconnectPendant();
                  },
                  child: const Text('Disconnect'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () {
                    Navigator.pop(sheetCtx);
                    _sleep();
                  },
                  child: const Text('Sleep pendant'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _phoneShell({required Widget child, Widget? bottom}) {
    final scaffold = Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: child,
          ),
        ),
      ),
      bottomNavigationBar: bottom,
    );
    return EdgeGlow(
      active: _armed || _noteHolding,
      level: _liveLevel,
      child: Stack(
        fit: StackFit.expand,
        children: [const MeshBackdrop(), scaffold],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final live = _armed && _showLive;
    return _phoneShell(
      bottom: live ? null : _bottomBar(),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeIn,
        child: live
            ? KeyedSubtree(key: const ValueKey('live'), child: _liveScreen())
            : KeyedSubtree(key: ValueKey('tab$_tab'), child: _tabScreen()),
      ),
    );
  }

  Widget _tabScreen() {
    return _tab == 1 ? _libraryTab() : _todayTab();
  }

  Widget _bottomBar() {
    Widget tab(int i, String label, IconData icon) {
      final on = _tab == i;
      final color = on ? AppColors.ink : AppColors.faint;
      return InkWell(
        onTap: () => setState(() => _tab = i),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 9),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 25, color: color),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontFamily: AppFonts.sans,
                  fontSize: 10.5,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.paper,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 6, 0, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              tab(0, 'Home', LucideIcons.house),
              const SizedBox(width: 56),
              tab(1, 'Library', LucideIcons.library),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 16, 16, 6),
      child: Row(
        children: [
          Text.rich(
            const TextSpan(
              children: [
                TextSpan(text: 'open'),
                TextSpan(
                  text: '.',
                  style: TextStyle(color: AppColors.accent),
                ),
              ],
            ),
            style: const TextStyle(
              fontFamily: AppFonts.sans,
              fontWeight: FontWeight.w600,
              fontSize: 16,
              letterSpacing: -0.4,
              color: AppColors.ink,
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: _openSettings,
            tooltip: 'Settings',
            icon: const Icon(
              LucideIcons.settings2,
              size: 19,
              color: AppColors.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text, {EdgeInsetsGeometry? padding}) {
    return Padding(
      padding: padding ?? EdgeInsets.zero,
      child: Text(text.toUpperCase(), style: AppText.micro),
    );
  }

  Widget _todayTab() {
    final meetingsToday = _meetings.length;
    final notesToday = _notes.length;
    final hasItems = meetingsToday > 0 || notesToday > 0;
    final summary = [
      if (meetingsToday > 0)
        '$meetingsToday meeting${meetingsToday == 1 ? '' : 's'}',
      if (notesToday > 0) '$notesToday note${notesToday == 1 ? '' : 's'}',
    ].join(' · ');
    final showStatus = _status.isNotEmpty &&
        !_armed &&
        !_status.startsWith('Exception') &&
        !_status.contains('Did not find');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _headerRow(),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Spacer(flex: 3),
                Text(
                  _wearerName.isEmpty
                      ? '${_greetingWord()}.'
                      : '${_greetingWord()},\n$_wearerName.',
                  style: AppText.display,
                ),
                const SizedBox(height: 20),
                const AuroraOrb(size: 60),
                const SizedBox(height: 16),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 300),
                  child: Text(
                    'Your personal meeting assistant.',
                    style: AppText.sub.copyWith(fontSize: 14),
                  ),
                ),
                if (showStatus) ...[
                  const SizedBox(height: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 300),
                    child: Text(
                      _status,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.sub.copyWith(
                        fontSize: 11.5,
                        color: AppColors.faint,
                      ),
                    ),
                  ),
                ],
                const Spacer(flex: 2),
                _pendantCard(),
                if (hasItems) ...[
                  const SizedBox(height: 8),
                  _todayRow(summary),
                ],
                const Spacer(flex: 2),
                _sectionLabel('Capture'),
                const SizedBox(height: 12),
                _captureCards(),
                const Spacer(flex: 2),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _pendantCard() {
    final state = _chipState();
    IconData icon;
    String title;
    String caption;
    var invite = false;
    var rec = false;
    switch (state) {
      case PendantChipState.unpaired:
        invite = true;
        icon = LucideIcons.bluetooth;
        title = 'Connect your pendant';
        caption = 'Wear it and capture all day, hands free';
      case PendantChipState.offline:
        icon = LucideIcons.bluetoothOff;
        title = 'Pendant offline';
        final seen = PendantPrefs.lastSeenLabel();
        caption = seen.isEmpty
            ? 'Tap to reconnect'
            : 'Last seen $seen · tap to reconnect';
      case PendantChipState.connecting:
        icon = LucideIcons.bluetooth;
        title = 'Connecting';
        caption = 'Looking for ${PendantPrefs.name}';
      case PendantChipState.idle:
        icon = LucideIcons.bluetooth;
        final s = _dbg;
        title = 'Pendant connected';
        if (s == null) {
          caption = 'Ready';
        } else if (s.usbPowered) {
          caption = 'Charging on USB';
        } else if (s.batteryPct != null) {
          caption = '${s.batteryPct}% battery';
        } else {
          caption = 'Ready';
        }
      case PendantChipState.recording:
        rec = true;
        icon = LucideIcons.audioLines;
        title = 'Recording from pendant';
        caption =
            _noteHolding ? 'Capturing a note' : _meetingElapsed();
    }
    return Surface(
      radius: 18,
      prominent: invite || rec,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _onPendantCardTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: invite || rec
                        ? AppColors.accentSoft
                        : const Color(0x14FFFFFF),
                    shape: BoxShape.circle,
                  ),
                  child: state == PendantChipState.connecting
                      ? const Padding(
                          padding: EdgeInsets.all(11),
                          child: CircularProgressIndicator(
                            strokeWidth: 1.6,
                            color: AppColors.muted,
                          ),
                        )
                      : Icon(
                          icon,
                          size: 17,
                          color: invite || rec
                              ? AppColors.accentDeep
                              : state == PendantChipState.idle
                                  ? AppColors.ink
                                  : AppColors.muted,
                        ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: AppText.label.copyWith(fontSize: 14),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        caption,
                        style: AppText.sub.copyWith(
                          fontSize: 11.5,
                          color: rec ? AppColors.accentDeep : AppColors.muted,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                if (state == PendantChipState.idle)
                  Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: AppColors.accent,
                      shape: BoxShape.circle,
                    ),
                  )
                else if (rec)
                  const _PulseDot(),
                const SizedBox(width: 8),
                const Icon(LucideIcons.chevronRight,
                    size: 16, color: AppColors.faint),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _todayRow(String summary) {
    return InkWell(
      onTap: () => setState(() => _tab = 1),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const Icon(LucideIcons.layers, size: 15, color: AppColors.muted),
            const SizedBox(width: 13),
            Text(
              'Today',
              style: AppText.body.copyWith(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            Flexible(
              child: Text(
                summary,
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.sub.copyWith(fontSize: 12.5),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(LucideIcons.chevronRight,
                size: 15, color: AppColors.faint),
          ],
        ),
      ),
    );
  }

  Widget _captureCards() {
    final noteActive = _noteHolding || _noteTempArm || _noteUsingDeviceMic;
    return IntrinsicHeight(
      child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _captureCard(
            icon: _armed ? LucideIcons.audioLines : LucideIcons.mic,
            title: _armed ? 'Recording' : 'Start meeting',
            sub: _armed
                ? '${_meetingElapsed()} · tap to open'
                : 'Records and transcribes live',
            filled: true,
            active: _armed,
            onTap: _busy
                ? null
                : _armed
                    ? () => setState(() => _showLive = true)
                    : _onStartMeetingTapped,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _captureCard(
            icon: noteActive ? LucideIcons.circleStop : LucideIcons.notebookPen,
            title: noteActive ? 'Recording note' : 'Take a note',
            sub: noteActive
                ? '${_noteElapsed()} · tap to save'
                : 'A quick spoken thought',
            filled: false,
            active: noteActive,
            onTap: _busy ? null : _toggleVoiceNote,
          ),
        ),
      ],
      ),
    );
  }

  Widget _captureCard({
    required IconData icon,
    required String title,
    required String sub,
    required VoidCallback? onTap,
    required bool filled,
    bool active = false,
  }) {
    return Surface(
      radius: 20,
      prominent: active,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 15),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: filled || active
                            ? AppColors.accent
                            : AppColors.accentSoft,
                        shape: BoxShape.circle,
                        boxShadow: filled || active
                            ? const [
                                BoxShadow(
                                  color: Color(0x40FF4D00),
                                  blurRadius: 16,
                                  offset: Offset(0, 5),
                                ),
                              ]
                            : null,
                      ),
                      child: Icon(
                        icon,
                        size: 18,
                        color: filled || active
                            ? Colors.white
                            : AppColors.accentDeep,
                      ),
                    ),
                    const Spacer(),
                    if (active) const _PulseDot(),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  title,
                  style: AppText.label.copyWith(
                    fontSize: 14.5,
                    color: active ? AppColors.accentDeep : AppColors.ink,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.sub.copyWith(
                    fontSize: 11.5,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _libraryTab() {
    final meetingById = {for (final m in _meetings) m.id: m};
    final searching = _search.text.trim().isNotEmpty;
    final showMeetings = _libTab == 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _headerRow(),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 6, 28, 16),
          child: Text('Library', style: AppText.display.copyWith(fontSize: 26)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 14),
          child: _searchBar(),
        ),
        SizedBox(
          height: 34,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 28),
            children: [
              for (final day in _stripDays())
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _dayChip(day),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 18, 28, 4),
          child: Row(
            children: [
              _underlineTab(
                'Meetings${_meetings.isEmpty ? '' : ' ${_meetings.length}'}',
                _libTab == 0,
                () => setState(() => _libTab = 0),
              ),
              _underlineTab(
                'Notes${_notes.isEmpty ? '' : ' ${_notes.length}'}',
                _libTab == 1,
                () => setState(() => _libTab = 1),
              ),
            ],
          ),
        ),
        Expanded(
          child: showMeetings
              ? _meetings.isEmpty
                  ? _libraryEmpty(
                      searching,
                      searching
                          ? 'Try different words, or another day.'
                          : 'Meetings you record will land here.',
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
                      children: [
                        for (final m in _meetings) _meetingRow(m),
                      ],
                    )
              : _notes.isEmpty
                  ? _libraryEmpty(
                      searching,
                      searching
                          ? 'Try different words, or another day.'
                          : 'Spoken notes you capture will land here.',
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
                      children: [
                        for (final n in _notes) _noteRow(n, meetingById),
                      ],
                    ),
        ),
      ],
    );
  }

  Widget _underlineTab(String label, bool on, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 22),
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: AppText.label.copyWith(
                fontSize: 13.5,
                fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                color: on ? AppColors.ink : AppColors.faint,
              ),
            ),
            const SizedBox(height: 6),
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              width: on ? 18 : 0,
              height: 2,
              decoration: BoxDecoration(
                color: AppColors.accent,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchBar() {
    final hasText = _search.text.isNotEmpty;
    return TextField(
      controller: _search,
      style: AppText.body.copyWith(fontSize: 13.5),
      cursorColor: AppColors.ink,
      decoration: InputDecoration(
        hintText: 'Search',
        prefixIcon: const Padding(
          padding: EdgeInsets.only(left: 6),
          child: Icon(LucideIcons.search, size: 16, color: AppColors.faint),
        ),
        prefixIconConstraints:
            const BoxConstraints(minWidth: 42, minHeight: 20),
        suffixIcon: hasText
            ? IconButton(
                icon: const Icon(LucideIcons.x,
                    size: 15, color: AppColors.muted),
                onPressed: () {
                  _search.clear();
                  _reload();
                },
              )
            : null,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: const BorderSide(color: AppColors.muted, width: 1.2),
        ),
      ),
      onChanged: (_) => _reload(),
      onSubmitted: (_) => _reload(),
    );
  }

  Widget _libraryEmpty(bool searching, String caption) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: const Color(0x0FFFFFFF),
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.line),
              ),
              child: Icon(
                searching ? LucideIcons.search : LucideIcons.audioLines,
                size: 22,
                color: AppColors.faint,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              searching ? 'No matches' : 'Nothing here yet',
              style: AppText.title.copyWith(fontSize: 15),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: Text(
                caption,
                textAlign: TextAlign.center,
                style: AppText.sub.copyWith(fontSize: 12.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dayChip(DateTime day) {
    final on = _sameDay(day, _selectedDay);
    return GestureDetector(
      onTap: () => _selectDay(day),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: on ? AppColors.ink : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: on ? AppColors.ink : AppColors.lineStrong),
        ),
        child: Text(
          _stripLabel(day),
          style: TextStyle(
            fontFamily: AppFonts.sans,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: on ? AppColors.paper : AppColors.muted,
          ),
        ),
      ),
    );
  }

  Widget _meetingRow(MeetingRecord meeting) {
    final live = _armed && meeting.id == _sessionId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              if (live) {
                setState(() => _showLive = true);
              } else {
                _openMeeting(meeting);
              }
            },
            onLongPress: () => _openMeeting(meeting, developer: true),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 13, 10, 13),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (live) ...[
                        const _PulseDot(),
                        const SizedBox(width: 6),
                        Text('LIVE', style: AppText.microAccent),
                        const SizedBox(width: 10),
                      ],
                      Text(
                        meeting.timeRangeLabel(now: DateTime.now()),
                        style: AppText.monoSmall.copyWith(fontSize: 11),
                      ),
                      const Spacer(),
                      const Icon(LucideIcons.chevronRight,
                          size: 15, color: AppColors.faint),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    meeting.preview.isEmpty
                        ? (meeting.transcribing || meeting.live
                            ? 'Transcribing…'
                            : 'No transcript yet')
                        : meeting.preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(
                      fontSize: 14,
                      height: 1.45,
                      color: meeting.preview.isEmpty
                          ? AppColors.faint
                          : AppColors.ink,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const Divider(indent: 10, endIndent: 10),
      ],
    );
  }

  Widget _noteRow(SpokenNote n, Map<String, MeetingRecord> meetingById) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 12, 4, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      noteTextWithoutSpeakers(n.text),
                      style: AppText.body.copyWith(fontSize: 14, height: 1.45),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _noteSubtitle(n, meetingById),
                      style: AppText.sub.copyWith(
                        fontSize: 11,
                        color: AppColors.faint,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(LucideIcons.x,
                    size: 14, color: AppColors.faint),
                tooltip: 'Delete note',
                onPressed: () async {
                  await _store.deleteNote(n.id);
                  await _reload();
                },
              ),
            ],
          ),
        ),
        const Divider(indent: 10, endIndent: 10),
      ],
    );
  }

  Widget _liveScreen() {
    final meeting = _currentMeeting;
    final segs = meeting?.segments ?? const <TranscriptSegment>[];
    final imuSleep = _dbg?.imuSleep == true;
    String statusLabel;
    var statusWarn = false;
    if (!_usingDeviceMic && !_connected) {
      statusLabel = 'Pendant out of range, reconnecting';
      statusWarn = true;
    } else if (imuSleep && !_usingDeviceMic) {
      statusLabel = 'Resting · mic paused';
    } else if (_usingDeviceMic) {
      statusLabel = '$_hostMicLabel mic · listening';
    } else {
      statusLabel = 'Pendant · listening';
    }
    final headline = meeting?.recap?.headline.trim().isNotEmpty == true
        ? meeting!.recap!.headline.trim()
        : 'your meeting';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Row(
            children: [
              CircleIconButton(
                icon: LucideIcons.chevronDown,
                onTap: () => setState(() => _showLive = false),
                tooltip: 'Back, keeps recording',
              ),
              const Spacer(),
              _livePill(),
              const Spacer(),
              const SizedBox(width: 38),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'Recording',
          textAlign: TextAlign.center,
          style: AppText.body.copyWith(
            fontSize: 18,
            fontWeight: FontWeight.w500,
            color: AppColors.muted,
          ),
        ),
        Text(
          headline,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.headline.copyWith(fontSize: 20),
        ),
        SizedBox(
          height: 190,
          child: Center(
            child: AuroraOrb(size: 240, level: _liveLevel),
          ),
        ),
        Text(
          _meetingElapsed().isEmpty ? '00:00' : _meetingElapsed(),
          textAlign: TextAlign.center,
          style: AppText.timer.copyWith(fontSize: 36),
        ),
        const SizedBox(height: 13),
        Center(child: _statusPill(statusLabel, warn: statusWarn)),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(28, 10, 28, 8),
            children: [
              TranscriptThread(
                segments: segs,
                dark: true,
                pending: segs.every((s) => s.text.trim().isEmpty) ||
                    (meeting?.transcribing ?? false) ||
                    _sttBusy ||
                    _sttQueue.isNotEmpty,
                pendingLabel: 'Transcribing…',
                empty: 'No speech in this meeting yet.',
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _liveCircleButton(
                icon: LucideIcons.bookmarkPlus,
                label: 'Mark',
                onTap: _markMoment,
              ),
              const SizedBox(width: 30),
              _stopButton(),
              const SizedBox(width: 30),
              _liveCircleButton(
                icon: _noteHolding ? LucideIcons.circleStop : LucideIcons.mic,
                label: 'Note',
                active: _noteHolding,
                onTap: _busy ? null : _toggleVoiceNote,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 16, top: 2),
          child: Text(
            _connected
                ? 'Stop ends the meeting, or press the pendant once'
                : 'Stop ends the meeting',
            textAlign: TextAlign.center,
            style: AppText.sub.copyWith(fontSize: 11.5),
          ),
        ),
      ],
    );
  }

  Widget _livePill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0x14FFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _PulseDot(),
          const SizedBox(width: 7),
          Text('LIVE', style: AppText.micro.copyWith(color: AppColors.ink)),
        ],
      ),
    );
  }

  Widget _statusPill(String label, {bool warn = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: warn ? const Color(0x66FF4D00) : AppColors.lineStrong,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: warn ? AppColors.accent : const Color(0xFF5FBF82),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: AppText.sub.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: warn ? const Color(0xFFFFA37D) : AppColors.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _stopButton() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: AppColors.accent,
          shape: const CircleBorder(),
          elevation: 0,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _busy ? null : _toggleMeeting,
            child: Container(
              width: 70,
              height: 70,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Color(0x4DFF4D00),
                    blurRadius: 26,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Center(
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text('STOP', style: AppText.micro.copyWith(fontSize: 10)),
      ],
    );
  }

  Widget _liveCircleButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool active = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: active ? AppColors.accent : const Color(0x14FFFFFF),
            shape: CircleBorder(
              side: BorderSide(
                color: active ? AppColors.accent : AppColors.lineStrong,
              ),
            ),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: 52,
                height: 52,
                child: Icon(
                  icon,
                  size: 20,
                  color: active ? Colors.white : AppColors.ink,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label.toUpperCase(),
            style: AppText.micro.copyWith(fontSize: 10),
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

/// A small dot that breathes. Live and recording indicators.
class _PulseDot extends StatefulWidget {
  const _PulseDot();

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.3).animate(
        CurvedAnimation(parent: _c, curve: Curves.easeInOut),
      ),
      child: Container(
        width: 7,
        height: 7,
        decoration: const BoxDecoration(
          color: AppColors.accent,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
