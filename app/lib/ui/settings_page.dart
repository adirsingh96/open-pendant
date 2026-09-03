import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ble/pendant_prefs.dart';
import '../macos/cursor_composer.dart';
import '../mem0/mem0_store.dart';
import '../notes/note_prefs.dart';
import '../stt/api_key_store.dart';
import '../stt/cursor_prefs.dart';
import '../stt/local_whisper_stt.dart';
import '../stt/sarvam_key_store.dart';
import '../stt/stt_prefs.dart';
import 'app_page.dart';
import 'app_theme.dart';
import 'circle_button.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    this.onOpenDeveloper,
    this.onOpenCalibrate,
    this.onOpenVoices,
    this.onOpenMemories,
    this.onOpenFindPendant,
  });

  final VoidCallback? onOpenDeveloper;
  final VoidCallback? onOpenCalibrate;
  final VoidCallback? onOpenVoices;
  final VoidCallback? onOpenMemories;
  final VoidCallback? onOpenFindPendant;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _key = TextEditingController();
  final _sarvam = TextEditingController();
  final _mem0 = TextEditingController();
  bool _diarize = true;
  SttEngine _engine = SttEngine.saaras;
  bool _whisperReady = false;
  bool _whisperBusy = false;
  int _whisperGot = 0;
  int _whisperTotal = 0;
  String? _whisperMsg;
  String _tab = 'transcription';
  bool _cursorOn = false;
  bool _cursorPaste = true;
  bool _cursorSend = true;
  bool _notesOn = true;
  bool _autoConnect = false;
  bool _loaded = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    Future.wait([
      ApiKeyStore.read(),
      SarvamKeyStore.read(),
      Mem0Store.readKey(),
      SttPrefs.load(),
      CursorPrefs.load(),
      NotePrefs.load(),
      PendantPrefs.load(),
    ]).then((vals) {
      _key.text = vals[0] as String;
      _sarvam.text = vals[1] as String;
      _mem0.text = vals[2] as String;
      _diarize = SttPrefs.diarize;
      _engine = SttPrefs.engine;
      _cursorOn = CursorPrefs.enabled;
      _cursorPaste = CursorPrefs.pasteIntoCursor;
      _cursorSend = CursorPrefs.autoSend;
      _notesOn = NotePrefs.enabled;
      _autoConnect = PendantPrefs.autoConnect;
      if (mounted) {
        setState(() => _loaded = true);
      }
      unawaited(_refreshWhisper());
    });
  }

  @override
  void dispose() {
    _key.dispose();
    _sarvam.dispose();
    _mem0.dispose();
    super.dispose();
  }

  Future<void> _persist({bool allowClear = false}) async {
    if (allowClear || _key.text.trim().isNotEmpty) {
      await ApiKeyStore.write(_key.text);
    }
    if (allowClear || _sarvam.text.trim().isNotEmpty) {
      await SarvamKeyStore.write(_sarvam.text);
    }
    await SttPrefs.save(diarize: _diarize, engine: _engine);
    await CursorPrefs.save(
      on: _cursorOn,
      paste: _cursorPaste,
      send: _cursorSend,
    );
    await NotePrefs.save(on: _notesOn);
    await PendantPrefs.saveAutoConnect(on: _autoConnect);
    if (allowClear || _mem0.text.trim().isNotEmpty) {
      await Mem0Store.writeKey(_mem0.text);
    }
    await Mem0Store.userId();
  }

  Future<void> _refreshWhisper() async {
    final ready = await LocalWhisperStt.isReady();
    final bytes = await LocalWhisperStt.installedBytes();
    if (!mounted) {
      return;
    }
    setState(() {
      _whisperReady = ready;
      if (ready) {
        _whisperGot = bytes;
        _whisperTotal = bytes;
        _whisperMsg =
            'Ready on this device (~${(bytes / 1e9).toStringAsFixed(2)} GB).';
      }
    });
  }

  Future<void> _setEngine(SttEngine v) async {
    setState(() => _engine = v);
    await SttPrefs.save(engine: v);
    if (v == SttEngine.saaras) {
      LocalWhisperStt.free();
      return;
    }
    if (!_whisperReady && !_whisperBusy) {
      await _downloadWhisper();
    }
  }

  Future<void> _downloadWhisper() async {
    setState(() {
      _whisperBusy = true;
      _whisperMsg = 'Downloading Qwen3-ASR (~1 GB). Use Wi-Fi.';
      _whisperGot = 0;
      _whisperTotal = 0;
    });
    try {
      await LocalWhisperStt.ensureModel(
        onProgress: (got, total) {
          if (!mounted) {
            return;
          }
          setState(() {
            _whisperGot = got;
            _whisperTotal = total;
          });
        },
      );
      await _refreshWhisper();
    } catch (e) {
      if (mounted) {
        setState(() => _whisperMsg = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => _whisperBusy = false);
      }
    }
  }

  Future<void> _deleteWhisper() async {
    await LocalWhisperStt.deleteModel();
    if (!mounted) {
      return;
    }
    setState(() {
      _whisperReady = false;
      _whisperGot = 0;
      _whisperTotal = 0;
      _whisperMsg = 'Model removed.';
      if (_engine == SttEngine.local) {
        _engine = SttEngine.saaras;
      }
    });
    await SttPrefs.save(engine: _engine);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _persist(allowClear: true);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Keys saved on this computer only')),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save keys: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (!_loaded) {
          return;
        }
        Future(_persist);
      },
      child: AppPage(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Row(
                      children: [
                        CircleIconButton(
                          icon: LucideIcons.arrowLeft,
                          iconSize: 16,
                          onTap: () => Navigator.pop(context),
                          tooltip: 'Back',
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 14, 28, 16),
                    child: Text(
                      'Settings',
                      style: AppText.display.copyWith(fontSize: 26),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: _tabs(),
                  ),
                  if (!_loaded)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 28),
                      child: LinearProgressIndicator(minHeight: 1),
                    ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(28, 20, 28, 28),
                      children: switch (_tab) {
                        'behavior' => _behavior(),
                        'more' => _more(),
                        _ => _transcription(),
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabs() {
    Widget seg(String id, String label) {
      final on = _tab == id;
      return Padding(
        padding: const EdgeInsets.only(right: 22),
        child: GestureDetector(
          onTap: () => setState(() => _tab = id),
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

    return Row(
      children: [
        seg('transcription', 'Transcription'),
        seg('behavior', 'Behavior'),
        seg('more', 'More'),
      ],
    );
  }

  List<Widget> _transcription() {
    return [
      Text('TRANSCRIPTION', style: AppText.micro),
      const SizedBox(height: 8),
      Text(
        'Cloud uses Sarvam Saaras v4. On-device uses Qwen3-ASR 0.6B (2026). Both save the model text as returned — Hindi stays in Devanagari when that is what came back.',
        style: AppText.sub.copyWith(fontSize: 12),
      ),
      const SizedBox(height: 10),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Cloud (Saaras)'),
        subtitle:
            const Text('Needs a Sarvam key. Best for Hindi and code-switch.'),
        leading: Icon(
          _engine == SttEngine.saaras
              ? LucideIcons.circleDot
              : LucideIcons.circle,
          size: 18,
          color:
              _engine == SttEngine.saaras ? AppColors.accent : AppColors.faint,
        ),
        onTap: !_loaded ? null : () => unawaited(_setEngine(SttEngine.saaras)),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('On-device (Qwen3-ASR)'),
        subtitle: const Text(
          'Audio stays on this device. Stronger 2026 multilingual model (~1 GB). Diarization is not applied.',
        ),
        leading: Icon(
          _engine == SttEngine.local
              ? LucideIcons.circleDot
              : LucideIcons.circle,
          size: 18,
          color:
              _engine == SttEngine.local ? AppColors.accent : AppColors.faint,
        ),
        onTap: !_loaded || _whisperBusy
            ? null
            : () => unawaited(_setEngine(SttEngine.local)),
      ),
      if (_engine == SttEngine.local || _whisperBusy || _whisperReady) ...[
        const SizedBox(height: 6),
        if (_whisperBusy)
          LinearProgressIndicator(
            minHeight: 3,
            value: _whisperTotal > 0
                ? (_whisperGot / _whisperTotal).clamp(0.0, 1.0)
                : null,
          ),
        if (_whisperMsg != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child:
                Text(_whisperMsg!, style: AppText.sub.copyWith(fontSize: 12)),
          ),
        if (_whisperBusy && _whisperGot > 0)
          Text(
            '${(_whisperGot / 1e6).toStringAsFixed(0)} MB'
            '${_whisperTotal > 0 ? ' / ${(_whisperTotal / 1e6).toStringAsFixed(0)} MB' : ''}',
            style: AppText.sub.copyWith(fontSize: 12),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _whisperBusy
                ? null
                : _whisperReady
                    ? _deleteWhisper
                    : _downloadWhisper,
            child: Text(
                _whisperReady ? 'Remove on-device model' : 'Download model'),
          ),
        ),
      ],
      const SizedBox(height: 12),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Diarization'),
        subtitle: const Text(
          'Saaras meetings also send audio to gpt-4o-transcribe-diarize so turns get speaker names. Enroll People to name them. Adds OpenAI cost. Not used with on-device Whisper.',
        ),
        value: _diarize,
        onChanged: !_loaded
            ? null
            : (v) async {
                setState(() => _diarize = v);
                await SttPrefs.save(diarize: v);
              },
      ),
      const SizedBox(height: 26),
      Text('API KEYS', style: AppText.micro),
      const SizedBox(height: 6),
      Text(
        'Keys stay on this computer. Nothing is ever stored on the pendant.',
        style: AppText.sub.copyWith(fontSize: 12),
      ),
      const SizedBox(height: 14),
      TextField(
        controller: _sarvam,
        obscureText: true,
        decoration: InputDecoration(
          labelText: 'Sarvam API key',
          hintText: 'indus.sarvam.ai',
          helperText: _engine == SttEngine.local
              ? 'Not used while on-device Whisper is selected.'
              : 'Required for cloud transcripts.',
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _key,
        obscureText: true,
        decoration: InputDecoration(
          labelText: 'OpenAI API key',
          helperText: _diarize
              ? 'Required for diarization, recap, and ask-about-this-meeting.'
              : 'Used for recap and ask-about-this-meeting.',
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _mem0,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: 'Mem0 API key',
          helperText: 'Optional. Day recaps sync to Mem0 so facts can grow.',
        ),
      ),
      const SizedBox(height: 18),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: Text(_saving ? 'Saving' : 'Save keys'),
      ),
    ];
  }

  List<Widget> _behavior() {
    return [
      Text('CAPTURE', style: AppText.micro),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Spoken notes'),
        subtitle: const Text(
          'Hold the pendant button and talk, release to save. A click starts or ends a meeting. Double-click rings this phone so you can find it. “Remind me … at 10 AM” notifies 15 minutes before. Notes without a time show up in an 8 AM reminder until you check them off.',
        ),
        value: _notesOn,
        onChanged: !_loaded
            ? null
            : (v) async {
                setState(() => _notesOn = v);
                await NotePrefs.save(on: v);
              },
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Auto-connect'),
        subtitle: const Text(
          'When this app is open, connect if your pendant is nearby after you had tapped Disconnect. An unexpected drop is repaired even if the phone is locked.',
        ),
        value: _autoConnect,
        onChanged: !_loaded
            ? null
            : (v) async {
                setState(() => _autoConnect = v);
                await PendantPrefs.saveAutoConnect(on: v);
              },
      ),
      const SizedBox(height: 8),
      Text(
        'FIND PHONE',
        style: AppText.micro,
      ),
      const SizedBox(height: 8),
      Text(
        'Double-click the pendant while connected. This phone plays a looping tone until you tap the screen, double-click again, or 40 seconds pass. Leave the app in the switcher (force-quit will not wake Bluetooth).',
        style: AppText.sub.copyWith(fontSize: 12),
      ),
      const SizedBox(height: 20),
      Text(
        'FIND PENDANT',
        style: AppText.micro,
      ),
      const SizedBox(height: 8),
      Text(
        'Open Find pendant from the connected sheet or More. Walk and watch the ring: a stronger Bluetooth signal means closer. It cannot point a direction. Flashing LEDs need current firmware.',
        style: AppText.sub.copyWith(fontSize: 12),
      ),
      const SizedBox(height: 20),
      Text('CURSOR (MACOS)', style: AppText.micro),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Cursor commands'),
        subtitle: const Text(
          'Say "Cursor, …" while recording. Clips end about 1.5s after you stop talking.',
        ),
        value: _cursorOn,
        onChanged: !_loaded
            ? null
            : (v) async {
                setState(() => _cursorOn = v);
                await CursorPrefs.save(
                  on: v,
                  paste: _cursorPaste,
                  send: _cursorSend,
                );
              },
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Paste into Cursor'),
        subtitle: const Text(
          'After a rebuild, macOS may need a fresh Accessibility toggle for the app.',
        ),
        value: _cursorPaste,
        onChanged: !_loaded || !_cursorOn
            ? null
            : (v) async {
                setState(() => _cursorPaste = v);
                await CursorPrefs.save(
                  on: _cursorOn,
                  paste: v,
                  send: _cursorSend,
                );
              },
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Auto-send in Cursor'),
        subtitle: const Text('Press Return in Composer after pasting.'),
        value: _cursorSend,
        onChanged: !_loaded || !_cursorOn || !_cursorPaste
            ? null
            : (v) async {
                setState(() => _cursorSend = v);
                await CursorPrefs.save(
                  on: _cursorOn,
                  paste: _cursorPaste,
                  send: v,
                );
              },
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: !_loaded || !_cursorOn || !_cursorPaste
              ? null
              : () async {
                  await Clipboard.setData(
                    const ClipboardData(text: 'OpenPendant paste test'),
                  );
                  final r = await pasteIntoCursorComposer(autoSend: false);
                  if (!mounted) {
                    return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      duration: const Duration(seconds: 8),
                      content: Text(
                        r.ok
                            ? 'Pasted test text. Click Composer first if you do not see it.'
                            : 'Paste failed: ${r.detail}',
                      ),
                    ),
                  );
                },
          child: const Text('Test paste into Cursor'),
        ),
      ),
    ];
  }

  List<Widget> _more() {
    Widget row({
      required IconData icon,
      required String title,
      required String caption,
      required VoidCallback? onTap,
    }) {
      return Column(
        children: [
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
              child: Row(
                children: [
                  Icon(icon, size: 17, color: AppColors.muted),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: AppText.label.copyWith(fontSize: 14)),
                        const SizedBox(height: 2),
                        Text(
                          caption,
                          style: AppText.sub.copyWith(fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                  const Icon(LucideIcons.chevronRight,
                      size: 15, color: AppColors.faint),
                ],
              ),
            ),
          ),
          const Divider(),
        ],
      );
    }

    return [
      row(
        icon: LucideIcons.bluetoothSearching,
        title: 'Find pendant',
        caption: 'Walk toward a stronger Bluetooth signal',
        onTap: widget.onOpenFindPendant,
      ),
      row(
        icon: LucideIcons.mic,
        title: 'People',
        caption: 'Named voices for speaker labels',
        onTap: widget.onOpenVoices,
      ),
      row(
        icon: LucideIcons.sparkles,
        title: 'Memories',
        caption: 'Day recaps and highlights',
        onTap: widget.onOpenMemories,
      ),
      row(
        icon: LucideIcons.audioLines,
        title: 'Mic calibrate',
        caption: 'Wear the pendant and read the script',
        onTap: widget.onOpenCalibrate,
      ),
      row(
        icon: LucideIcons.settings,
        title: 'Developer',
        caption: 'IMU, STT spend, PCM, custom time range',
        onTap: widget.onOpenDeveloper,
      ),
      const SizedBox(height: 16),
      Text(
        'Clean this day rewrites the selected day and stores a structured recap (OpenAI). Meeting Recap uses the same key. Raw transcription is always kept.',
        style: AppText.sub.copyWith(fontSize: 11.5),
      ),
    ];
  }
}
