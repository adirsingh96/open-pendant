import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../macos/cursor_composer.dart';
import '../mem0/mem0_store.dart';
import '../notes/note_prefs.dart';
import '../stt/api_key_store.dart';
import '../stt/cursor_prefs.dart';
import '../stt/sarvam_key_store.dart';
import '../stt/stt_prefs.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    this.onOpenDeveloper,
    this.onOpenCalibrate,
  });

  final VoidCallback? onOpenDeveloper;
  final VoidCallback? onOpenCalibrate;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _key = TextEditingController();
  final _sarvam = TextEditingController();
  final _mem0 = TextEditingController();
  String _stt = SttPrefs.openai;
  bool _cursorOn = false;
  bool _cursorPaste = true;
  bool _cursorSend = true;
  bool _notesOn = true;
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
    ]).then((vals) {
      _key.text = vals[0] as String;
      _sarvam.text = vals[1] as String;
      _mem0.text = vals[2] as String;
      _stt = SttPrefs.provider;
      _cursorOn = CursorPrefs.enabled;
      _cursorPaste = CursorPrefs.pasteIntoCursor;
      _cursorSend = CursorPrefs.autoSend;
      _notesOn = NotePrefs.enabled;
      if (mounted) {
        setState(() => _loaded = true);
      }
    });
  }

  @override
  void dispose() {
    _key.dispose();
    _sarvam.dispose();
    _mem0.dispose();
    super.dispose();
  }

  Future<void> _persist() async {
    await ApiKeyStore.write(_key.text);
    await SarvamKeyStore.write(_sarvam.text);
    await SttPrefs.save(_stt);
    await CursorPrefs.save(
      on: _cursorOn,
      paste: _cursorPaste,
      send: _cursorSend,
    );
    await NotePrefs.save(on: _notesOn);
    await Mem0Store.writeKey(_mem0.text);
    await Mem0Store.userId();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _persist();
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
      child: Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Transcription engine. OpenAI still needed for Clean this day and Memories. '
            'Never stored on the pendant.',
          ),
          const SizedBox(height: 12),
          if (!_loaded) const LinearProgressIndicator(),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: SttPrefs.openai,
                label: Text('OpenAI'),
              ),
              ButtonSegment(
                value: SttPrefs.saarasV4,
                label: Text('Saaras'),
              ),
              ButtonSegment(
                value: SttPrefs.both,
                label: Text('Both'),
              ),
            ],
            selected: {_stt},
            onSelectionChanged: !_loaded
                ? null
                : (s) async {
                    setState(() => _stt = s.first);
                    await SttPrefs.save(_stt);
                  },
          ),
          const SizedBox(height: 8),
          Text(
            _stt == SttPrefs.both
                ? 'Each clip is sent to OpenAI and Saaras v4. Journal, Clean, and Memories use OpenAI when it succeeds. Open a conversation to compare side by side. Both API keys required. About 2× STT cost.'
                : _stt == SttPrefs.saarasV4
                    ? 'Saaras v4 REST for Indic transcription. No speaker names on REST. Journal uses Saaras only.'
                    : 'OpenAI file transcription. Named voices use gpt-4o-transcribe-diarize.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _key,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'OPENAI_API_KEY',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _sarvam,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'SARVAM_API_KEY',
              hintText: 'indus.sarvam.ai',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Mem0 hobby key. Recaps (not audio) are sent after Clean this day '
            'so facts can grow. Search uses retrieval quota. Never on the pendant.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _mem0,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'MEM0_API_KEY',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
          const SizedBox(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Cursor commands (macOS)'),
            subtitle: const Text(
              'Say “Cursor, …” or tap Command on Home. Clips end ~1.5s after you stop talking (not 8s). Uses a faster STT model. Journal still saves.',
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
              'Ignore Automation. After each flutter rebuild, Accessibility may need a new openpendant toggle (remove the old row, add the Debug app). Cmd+V always works.',
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
            subtitle: const Text(
              'After paste, press Return in Composer. Click the chat input first. Shift+Enter still adds a newline if you type yourself.',
            ),
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
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Spoken notes'),
            subtitle: const Text(
              'Say “take a note, …” to save a note on Home for that day. You can also type one. Nothing is sent to Google.',
            ),
            value: _notesOn,
            onChanged: !_loaded
                ? null
                : (v) async {
                    setState(() => _notesOn = v);
                    await NotePrefs.save(on: v);
                  },
          ),
          const SizedBox(height: 8),
          const Text(
            'Home → Clean this day rewrites the selected day’s transcript and writes a structured recap (gpt-4o-mini). Raw STT is kept. An empty Mem0 key does not block Clean.',
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Mic calibrate'),
            subtitle: const Text('Wear the pendant and read the script'),
            trailing: const Icon(Icons.chevron_right),
            onTap: widget.onOpenCalibrate,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Developer'),
            subtitle: const Text('IMU, STT spend, PCM, custom time range'),
            trailing: const Icon(Icons.chevron_right),
            onTap: widget.onOpenDeveloper,
          ),
          const SizedBox(height: 16),
          const Text(
            'Named voices are on the People screen. '
            'Samples stay on this computer and are sent with OpenAI diarized transcription.',
          ),
        ],
        ),
      ),
    );
  }
}
