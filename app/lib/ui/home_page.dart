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
import 'clip_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AppLifecycleListener? _lifecycle;
  final _ble = PendantBle();
  final _store = ClipStore();
  final _stt = OpenAiStt();
  final _search = TextEditingController();

  String _status = 'Disconnected. Force-quit nRF Connect first.';
  bool _busy = false;
  bool _connected = false;
  bool _recording = false;
  DateTime? _startedAt;
  DateTime? _lastSpeechAt;
  bool _silenceStopping = false;
  bool _autoReconnect = false;
  bool _resumeAfterReconnect = false;
  PendantStatus? _dbg;
  int _bytes = 0;
  List<ClipRecord> _clips = [];

  @override
  void initState() {
    super.initState();
    _ble.onConnectionLost = _onConnectionLost;
    _ble.onStatus = (s) {
      if (mounted) {
        setState(() => _dbg = s);
      }
    };
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
    _lifecycle?.dispose();
    _search.dispose();
    _ble.disconnect();
    super.dispose();
  }

  Future<void> _reload() async {
    final clips = await _store.listClips(query: _search.text);
    if (mounted) {
      setState(() => _clips = clips);
    }
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
            'Connected to ${d.platformName}. Notify on = recording; LED will be solid.';
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
    final wasRecording = _recording;
    _resumeAfterReconnect = wasRecording;
    setState(() {
      _connected = false;
      _recording = false;
      _dbg = null;
      _status = 'Connection lost. Reconnecting…';
    });
    Future(() async {
      if (wasRecording) {
        await _stop();
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
          await _start();
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
    if (_recording) {
      await _stop();
    } else {
      await _start();
    }
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _status = 'Recording — speak near the pendant. LED should be on.';
    });
    try {
      _startedAt = DateTime.now().toUtc();
      _lastSpeechAt = DateTime.now();
      _silenceStopping = false;
      _bytes = 0;
      await _ble.startRecording(() {
        if (!mounted || !_recording) {
          return;
        }
        final last = _ble.reassembler.lastComplete;
        if (pcmRms(last) >= 450) {
          _lastSpeechAt = DateTime.now();
        }
        final quiet = DateTime.now().difference(_lastSpeechAt ?? DateTime.now());
        if (!_silenceStopping && !_busy && quiet.inMilliseconds >= 8000) {
          _silenceStopping = true;
          Future.microtask(_stop);
          return;
        }
        setState(() => _bytes = _ble.reassembler.pcmByteLength);
      });
      setState(() => _recording = true);
    } catch (e) {
      setState(() => _status = '$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    setState(() {
      _busy = true;
      _recording = false;
      _status = 'Stopping…';
    });
    try {
      await _ble.stopRecording();
      final started = _startedAt ?? DateTime.now().toUtc();
      final pcm = _ble.reassembler.pcmBytes();
      final duration = pcm.length / 2 / 16000;
      final id = const Uuid().v4();
      final dir = await getApplicationDocumentsDirectory();
      final wavPath = p.join(dir.path, 'clips', '$id.wav');
      await Directory(p.dirname(wavPath)).create(recursive: true);
      await File(wavPath).writeAsBytes(pcmToWav(pcm: pcm), flush: true);

      var clip = ClipRecord(
        id: id,
        startedAt: started,
        durationS: duration,
        fullText: '',
        wavPath: wavPath,
        sttModel: null,
        status: 'transcribing',
      );
      await _store.upsertClip(clip);
      await _reload();
      await _transcribeClip(clip);
      await _reload();
    } catch (e) {
      setState(() => _status = '$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _transcribeClip(ClipRecord clip) async {
    final key = await ApiKeyStore.read();
    final wavPath = clip.wavPath;
    if (key.isEmpty || wavPath == null || !File(wavPath).existsSync()) {
      await _store.upsertClip(
        ClipRecord(
          id: clip.id,
          startedAt: clip.startedAt,
          durationS: clip.durationS,
          fullText: '',
          wavPath: wavPath,
          sttModel: null,
          status: 'error',
        ),
      );
      setState(() => _status = 'Saved WAV but no API key. Add it in Settings, then Retry.');
      return;
    }

    final full = await File(wavPath).readAsBytes();
    // Strip 44-byte WAV header if present.
    final pcm = full.length > 44 &&
            String.fromCharCodes(full.sublist(0, 4)) == 'RIFF'
        ? full.sublist(44)
        : full;
    final speech = extractSpeech(pcm);
    if (speech.speechDurationS < 0.25) {
      await _store.upsertClip(
        ClipRecord(
          id: clip.id,
          startedAt: clip.startedAt,
          durationS: clip.durationS,
          fullText: '',
          wavPath: wavPath,
          sttModel: null,
          status: 'silence',
        ),
      );
      setState(
        () => _status =
            'No speech detected (${clip.durationS.toStringAsFixed(1)}s kept, 0s sent to API).',
      );
      return;
    }

    final speechPath = p.join(p.dirname(wavPath), '${clip.id}_speech.wav');
    await File(speechPath).writeAsBytes(pcmToWav(pcm: speech.speechPcm), flush: true);
    setState(() {
      _status =
          'Sending ${speech.speechDurationS.toStringAsFixed(1)}s speech '
          '(of ${speech.originalDurationS.toStringAsFixed(1)}s) to OpenAI…';
    });
    try {
      final result = await _stt.transcribe(
        wav: File(speechPath),
        apiKey: key,
        startedAt: clip.startedAt,
        speech: speech,
      );
      await _store.upsertClip(
        ClipRecord(
          id: clip.id,
          startedAt: clip.startedAt,
          durationS: clip.durationS,
          fullText: result.text,
          wavPath: wavPath,
          sttModel: result.model,
          status: 'ok',
          segments: result.segments,
        ),
      );
      setState(() {
        _status =
            'Transcribed ${result.model}: billed ~${speech.speechDurationS.toStringAsFixed(1)}s '
            'of ${clip.durationS.toStringAsFixed(1)}s.';
      });
    } catch (e) {
      await _store.upsertClip(
        ClipRecord(
          id: clip.id,
          startedAt: clip.startedAt,
          durationS: clip.durationS,
          fullText: '',
          wavPath: wavPath,
          sttModel: null,
          status: 'error',
        ),
      );
      setState(() => _status = 'WAV saved; STT failed: $e');
    }
  }

  Future<void> _retry(ClipRecord clip) async {
    setState(() => _busy = true);
    try {
      await _transcribeClip(clip);
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
    if (_recording) {
      await _stop();
    }
    await _ble.disconnect();
    if (!mounted) {
      return;
    }
    setState(() {
      _connected = false;
      _recording = false;
      _dbg = null;
      _status = 'Sleeping. Notify off, LED blinks. Connect to wake.';
    });
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
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
            Text('IMU: $imuLabel'),
            if (s != null) ...[
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
              'Test: Connect, leave the board still ~10s → IMU SLEEP. '
              'Pick it up → AWAKE. Mic noise does not keep it awake.',
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final recLabel = _recording ? 'Stop' : 'Record';
    return Scaffold(
      appBar: AppBar(
        title: const Text('OpenPendant'),
        actions: [
          IconButton(
            tooltip: 'API key and settings',
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
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
          Wrap(
            spacing: 8,
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
                onPressed: _busy || (!_connected && !_recording) ? null : _sleep,
                child: const Text('Sleep'),
              ),
              OutlinedButton(
                onPressed: _openSettings,
                child: const Text('Settings'),
              ),
            ],
          ),
          if (_recording)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('PCM bytes: $_bytes'),
            ),
          _debugCard(),
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
          Expanded(
            child: ListView.builder(
              itemCount: _clips.length,
              itemBuilder: (context, i) {
                final c = _clips[i];
                final when = DateFormat.yMMMd().add_Hms().format(c.startedAt.toLocal());
                return ListTile(
                  title: Text(
                    c.fullText.isEmpty ? '(${c.status})' : c.fullText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('$when  ${c.durationS.toStringAsFixed(1)}s  ${c.status}'),
                  trailing: c.status == 'error'
                      ? TextButton(
                          onPressed: _busy ? null : () => _retry(c),
                          child: const Text('Retry'),
                        )
                      : null,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => ClipPage(clip: c)),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
