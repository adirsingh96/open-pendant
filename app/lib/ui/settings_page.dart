import 'package:flutter/material.dart';

import '../stt/api_key_store.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _key = TextEditingController();
  bool _loaded = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    ApiKeyStore.read().then((v) {
      _key.text = v;
      if (mounted) {
        setState(() => _loaded = true);
      }
    });
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ApiKeyStore.write(_key.text);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('API key saved on this computer only')),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save key: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'OpenAI API key for /v1/audio/transcriptions. '
              'Never stored on the pendant.',
            ),
            const SizedBox(height: 12),
            if (!_loaded) const LinearProgressIndicator(),
            TextField(
              controller: _key,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'OPENAI_API_KEY',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save'),
            ),
            const SizedBox(height: 24),
            const Text(
              'Named voices are on the home screen (Voices). '
              'Samples stay on this computer and are sent with each diarized transcription.',
            ),
          ],
        ),
      ),
    );
  }
}
