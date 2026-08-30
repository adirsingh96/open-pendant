import 'dart:async';

import 'package:flutter/material.dart';

import '../audio/wav_writer.dart';
import '../ble/pendant_ble.dart';
import '../stt/voice_store.dart';

class VoicesPage extends StatefulWidget {
  const VoicesPage({
    super.key,
    required this.ble,
    required this.connected,
    required this.armed,
  });

  final PendantBle ble;
  final bool connected;
  final bool armed;

  @override
  State<VoicesPage> createState() => _VoicesPageState();
}

class _VoicesPageState extends State<VoicesPage> {
  static const _script =
      'Hello. This is my voice sample for OpenPendant. '
      'I am speaking clearly at a normal pace so you can tell who is talking later. '
      'The weather is fine today, and I am glad to record this. Thank you.';

  final _name = TextEditingController();
  List<VoiceProfile> _voices = [];
  bool _recording = false;
  int _seconds = 0;
  Timer? _tick;
  String? _status;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _name.dispose();
    if (_recording) {
      widget.ble.stopRecording();
    }
    super.dispose();
  }

  Future<void> _reload() async {
    final v = await VoiceStore.list();
    if (mounted) {
      setState(() => _voices = v);
    }
  }

  Future<void> _startSample() async {
    if (widget.armed) {
      setState(() => _status = 'Stop Record on the home screen first.');
      return;
    }
    if (!widget.connected) {
      setState(() => _status = 'Connect the pendant first.');
      return;
    }
    if (_voices.length >= VoiceStore.maxVoices) {
      setState(() => _status = 'Remove a voice first (max ${VoiceStore.maxVoices}).');
      return;
    }
    final name = VoiceStore.sanitizeName(_name.text);
    if (name.isEmpty) {
      setState(() => _status = 'Enter a name, then record 2–10 seconds of speech.');
      return;
    }
    setState(() {
      _recording = true;
      _seconds = 0;
      _status = 'Read the script out loud, near the pendant.';
    });
    try {
      await widget.ble.startRecording(() {
        if (mounted) {
          setState(() {});
        }
      });
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          return;
        }
        setState(() => _seconds = t.tick);
        if (t.tick >= 10) {
          _stopSample();
        }
      });
    } catch (e) {
      setState(() {
        _recording = false;
        _status = '$e';
      });
    }
  }

  Future<void> _stopSample() async {
    _tick?.cancel();
    _tick = null;
    if (!_recording) {
      return;
    }
    setState(() => _recording = false);
    try {
      await widget.ble.stopRecording();
      final pcm = widget.ble.reassembler.pcmBytes();
      widget.ble.reassembler.reset();
      final dur = pcm.length / 2 / 16000;
      if (dur < 2) {
        setState(() => _status = 'Need at least 2 seconds (got ${dur.toStringAsFixed(1)}s).');
        return;
      }
      var clip = pcm;
      if (dur > 10) {
        clip = pcm.sublist(0, 10 * 16000 * 2);
      }
      await VoiceStore.add(name: _name.text, wavBytes: pcmToWav(pcm: clip));
      _name.clear();
      await _reload();
      setState(() => _status = 'Saved. This clip is sent with each transcription.');
    } catch (e) {
      setState(() => _status = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Voices')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Type a name, then tap Record and read the script below out loud. '
            'Aim for the full paragraph (about 8–10 seconds). Up to 4 voices. '
            'A local speaker model matches these samples; Saaras only writes the words.',
          ),
          const SizedBox(height: 12),
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Read this aloud',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _script,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          height: 1.45,
                        ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            enabled: !_recording,
            decoration: const InputDecoration(
              labelText: 'Name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          if (_recording)
            FilledButton(
              onPressed: _stopSample,
              child: Text('Stop (${_seconds}s)'),
            )
          else
            FilledButton(
              onPressed: _startSample,
              child: const Text('Record sample'),
            ),
          if (_status != null) ...[
            const SizedBox(height: 8),
            Text(_status!),
          ],
          const SizedBox(height: 16),
          Text('Saved (${_voices.length}/${VoiceStore.maxVoices})',
              style: Theme.of(context).textTheme.titleSmall),
          for (final v in _voices)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(v.name),
              subtitle: const Text('Reference clip on this computer'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  await VoiceStore.remove(v.id);
                  await _reload();
                },
              ),
            ),
        ],
      ),
    );
  }
}
