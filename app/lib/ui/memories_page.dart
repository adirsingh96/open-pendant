import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../db/clip_store.dart';
import '../db/memory_chat.dart';
import '../db/models.dart';
import '../mem0/mem0_client.dart';
import '../mem0/mem0_store.dart';
import '../stt/api_key_store.dart';
import '../stt/openai_refine.dart';
import 'md_text.dart';

class MemoriesPage extends StatefulWidget {
  const MemoriesPage({
    super.key,
    required this.onOpenDay,
    required this.store,
  });

  final Future<void> Function(DateTime day) onOpenDay;
  final ClipStore store;

  @override
  State<MemoriesPage> createState() => _MemoriesPageState();
}

class _MemoriesPageState extends State<MemoriesPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _mem0 = Mem0Client();
  final _refine = OpenAiRefine();
  final _turns = <MemoryChatTurn>[];
  bool _ready = false;
  bool _sending = false;
  String _mem0Key = '';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  ClipStore get _store => widget.store;

  Future<void> _boot() async {
    try {
      final keys = await Future.wait([
        Mem0Store.readKey(),
        ApiKeyStore.read(),
      ]);
      if (!mounted) {
        return;
      }
      setState(() {
        _mem0Key = keys[0];
        _ready = true;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _ready = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load keys: $e')),
        );
      }
      return;
    }
    try {
      final history = await _store.listMemoryChats();
      if (mounted) {
        setState(() {
          _turns
            ..clear()
            ..addAll(history);
        });
        _jumpToEnd();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load chat history: $e')),
        );
      }
    }
    if (_mem0Key.isEmpty) {
      return;
    }
    await _pushRecaps(force: false);
  }

  Future<void> _pushRecaps({required bool force}) async {
    final key = (await Mem0Store.readKey()).trim();
    if (key.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Paste MEM0_API_KEY in Settings (second field) and tap Save.',
            ),
          ),
        );
      }
      return;
    }
    try {
      final recaps = await _store.listDayRecaps();
      if (recaps.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No cleaned days yet. Run Clean this day first.'),
            ),
          );
        }
        return;
      }
      final n = await _mem0.syncRecaps(
        apiKey: key,
        userId: await Mem0Store.userId(),
        recaps: recaps,
        force: force,
      );
      if (!mounted) {
        return;
      }
      if (n > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Sent $n day recap${n == 1 ? '' : 's'} to Mem0.',
            ),
          ),
        );
      } else if (force) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nothing to send.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Memory sync failed: $e')),
        );
      }
    }
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) {
        return;
      }
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear chat?'),
        content: const Text(
          'This removes saved Memories questions on this computer. Journal days stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    await _store.clearMemoryChats();
    if (!mounted) {
      return;
    }
    setState(() => _turns.clear());
  }

  Future<void> _send() async {
    final q = _input.text.trim();
    if (q.isEmpty || _sending || !_ready) {
      return;
    }
    final mem0Key = (await Mem0Store.readKey()).trim();
    final openaiKey = (await ApiKeyStore.read()).trim();
    if (!mounted) {
      return;
    }
    setState(() {
      _mem0Key = mem0Key;
    });
    if (mem0Key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Paste MEM0_API_KEY in Settings (second field) and tap Save.',
          ),
        ),
      );
      return;
    }
    if (openaiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add an OpenAI API key in Settings first.')),
      );
      return;
    }
    _input.clear();
    final turn = MemoryChatTurn(
      id: const Uuid().v4(),
      askedAt: DateTime.now().toUtc(),
      question: q,
    );
    setState(() {
      _turns.add(turn);
      _sending = true;
    });
    _jumpToEnd();
    await _store.upsertMemoryChat(turn);
    try {
      final userId = await Mem0Store.userId();
      final recaps = await _store.listDayRecaps();
      final recentSegs = await _store.listSpeechSinceRecaps(recaps);
      final recentSpeech = _formatRecentSpeech(recentSegs);
      var remote = <Mem0Hit>[];
      try {
        remote = await _mem0.search(
          apiKey: mem0Key,
          userId: userId,
          query: q,
        );
      } catch (e) {
        debugPrint('Mem0 search failed: $e');
      }
      final hits = mergeMemoryHits(recaps: recaps, remote: remote);
      if (hits.isEmpty && recentSpeech.isEmpty) {
        turn.answer =
            'No memories yet. Clean a day first so facts can land here.';
        turn.dayKeys = [];
      } else {
        turn.answer = await _refine.answerFromMemories(
          apiKey: openaiKey,
          question: q,
          memories: [
            for (final h in hits) (memory: h.memory, dayKey: h.dayKey),
          ],
          recentSpeech: recentSpeech,
        );
        final keys = <String>{};
        for (final h in hits) {
          if (h.dayKey != null && looksLikeDayKey(h.dayKey!)) {
            keys.add(h.dayKey!);
          }
        }
        for (final s in recentSegs) {
          final k = _dayKeyOf(s.spokenAt);
          if (looksLikeDayKey(k)) {
            keys.add(k);
          }
        }
        turn.dayKeys = keys.toList()..sort();
      }
    } catch (e) {
      turn.error = '$e';
    } finally {
      await _store.upsertMemoryChat(turn);
      if (mounted) {
        setState(() => _sending = false);
        _jumpToEnd();
      }
    }
  }

  String _formatRecentSpeech(List<TranscriptSegment> segs) {
    final buf = StringBuffer();
    for (final s in segs) {
      final t = s.labeledText.trim();
      if (t.isEmpty) {
        continue;
      }
      final when = DateFormat('EEE d MMM HH:mm').format(s.spokenAt.toLocal());
      var line = '$when $t';
      if (line.length > 480) {
        line = '${line.substring(0, 480)}…';
      }
      buf.writeln(line);
    }
    return buf.toString().trim();
  }

  String _dayKeyOf(DateTime t) {
    final d = t.toLocal();
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  Future<void> _openDay(String dayKey) async {
    final day = parseDayKey(dayKey);
    if (day == null) {
      return;
    }
    Navigator.of(context).pop();
    await widget.onOpenDay(day);
  }

  String _chipLabel(String dayKey) {
    final day = parseDayKey(dayKey);
    if (day == null) {
      return 'Open $dayKey';
    }
    return 'Open ${DateFormat('EEE d MMM').format(day)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Memories'),
        actions: [
          IconButton(
            tooltip: 'Send recaps to Mem0',
            icon: const Icon(Icons.cloud_upload_outlined),
            onPressed: _sending ? null : () => _pushRecaps(force: true),
          ),
          if (_turns.isNotEmpty)
            IconButton(
              tooltip: 'Clear chat',
              icon: const Icon(Icons.delete_outline),
              onPressed: _sending ? null : _clear,
            ),
        ],
      ),
      body: Column(
        children: [
          if (_ready && _mem0Key.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                'Add a Mem0 hobby key in Settings. Clean still works locally.',
              ),
            ),
          Expanded(
            child: !_ready
                ? const Center(child: CircularProgressIndicator())
                : _turns.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Ask about people, decisions, or follow-ups. '
                            'One search per send. Answers cite journal days you can open.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        itemCount: _turns.length,
                        itemBuilder: (context, i) {
                          final t = _turns[i];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 520),
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primaryContainer,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Text(t.question),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                if (t.error != null)
                                  Text(
                                    t.error!,
                                    style: TextStyle(
                                      color: Theme.of(context).colorScheme.error,
                                    ),
                                  )
                                else if (t.answer == null)
                                  const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 8),
                                    child: LinearProgressIndicator(),
                                  )
                                else ...[
                                  MdText(t.answer!),
                                  if (t.dayKeys.isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        for (final k in t.dayKeys)
                                          ActionChip(
                                            label: Text(_chipLabel(k)),
                                            onPressed: () => _openDay(k),
                                          ),
                                      ],
                                    ),
                                  ],
                                ],
                              ],
                            ),
                          );
                        },
                      ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: _ready && !_sending,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Ask your memories…',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: (_ready && !_sending) ? _send : null,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
