import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../macos/cursor_composer.dart';
import '../mem0/mem0_store.dart';
import '../notes/note_prefs.dart';
import '../stt/api_key_store.dart';
import '../stt/cursor_prefs.dart';
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
  });

  final VoidCallback? onOpenDeveloper;
  final VoidCallback? onOpenCalibrate;
  final VoidCallback? onOpenVoices;
  final VoidCallback? onOpenMemories;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _key = TextEditingController();
  final _sarvam = TextEditingController();
  final _mem0 = TextEditingController();
  String _stt = SttPrefs.openai;
  String _tab = 'transcription';
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
      Text('ENGINE', style: AppText.micro),
      const SizedBox(height: 12),
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: SttPrefs.openai, label: Text('OpenAI')),
          ButtonSegment(value: SttPrefs.saarasV4, label: Text('Saaras')),
          ButtonSegment(value: SttPrefs.both, label: Text('Both')),
        ],
        selected: {_stt},
        onSelectionChanged: !_loaded
            ? null
            : (s) async {
                setState(() => _stt = s.first);
                await SttPrefs.save(_stt);
              },
      ),
      const SizedBox(height: 10),
      Text(
        _stt == SttPrefs.both
            ? 'Each clip goes to OpenAI and Saaras v4. Journal, Clean, and Memories use OpenAI when it succeeds. Both keys required, about twice the STT cost.'
            : _stt == SttPrefs.saarasV4
                ? 'Saaras v4 for Indic text. A small on-device speaker model tags People from their voice samples.'
                : 'OpenAI file transcription. Named voices use diarization.',
        style: AppText.sub.copyWith(fontSize: 12),
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
        controller: _key,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'OpenAI API key'),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _sarvam,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: 'Sarvam API key',
          hintText: 'indus.sarvam.ai',
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
          'Hold the pendant button and talk, release to save. A click starts or ends a meeting.',
        ),
        value: _notesOn,
        onChanged: !_loaded
            ? null
            : (v) async {
                setState(() => _notesOn = v);
                await NotePrefs.save(on: v);
              },
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
        'Clean this day rewrites the selected day and stores a structured recap. Raw transcription is always kept.',
        style: AppText.sub.copyWith(fontSize: 11.5),
      ),
    ];
  }
}
