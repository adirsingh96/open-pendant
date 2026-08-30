import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/meeting.dart';
import '../db/models.dart';
import '../stt/api_key_store.dart';
import '../stt/openai_refine.dart';
import 'app_theme.dart';
import 'liquid_glass.dart';
import 'mesh_backdrop.dart';
import 'md_text.dart';
import 'transcript_bubbles.dart';

class MeetingDetailPage extends StatefulWidget {
  const MeetingDetailPage({
    super.key,
    required this.meeting,
    required this.onRecap,
    required this.reload,
  });

  final MeetingRecord meeting;
  final Future<void> Function() onRecap;
  final Future<MeetingRecord?> Function() reload;

  @override
  State<MeetingDetailPage> createState() => _MeetingDetailPageState();
}

class _MeetingDetailPageState extends State<MeetingDetailPage> {
  late MeetingRecord _meeting;
  String _tab = 'transcript';
  final _ask = TextEditingController();
  final _searchCtl = TextEditingController();
  final _refine = OpenAiRefine();
  String? _question;
  String? _answer;
  bool _asking = false;
  final _done = <int>{};

  @override
  void initState() {
    super.initState();
    _meeting = widget.meeting;
  }

  @override
  void dispose() {
    _ask.dispose();
    _searchCtl.dispose();
    super.dispose();
  }

  String get _title {
    final h = _meeting.recap?.headline.trim() ?? '';
    if (h.isNotEmpty) {
      return h;
    }
    return 'Meeting';
  }

  String get _meta {
    final start = _meeting.startedAt.toLocal();
    final now = DateTime.now();
    final dur = _meeting.durationAt(now);
    final mins = dur.inMinutes;
    final day = DateFormat.MMMd().format(start);
    final clock = DateFormat.jm().format(start);
    final when = _isToday(start) ? 'Today' : day;
    return '$when · $clock · $mins min';
  }

  bool _isToday(DateTime t) {
    final n = DateTime.now();
    final l = t.toLocal();
    return l.year == n.year && l.month == n.month && l.day == n.day;
  }

  bool _recapping = false;

  Future<void> _recap() async {
    setState(() => _recapping = true);
    try {
      await widget.onRecap();
      final next = await widget.reload();
      if (next != null && mounted) {
        setState(() => _meeting = next);
      }
    } finally {
      if (mounted) {
        setState(() => _recapping = false);
      }
    }
  }

  Future<void> _askMeeting() async {
    final q = _ask.text.trim();
    if (q.isEmpty || _asking) {
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
    setState(() {
      _asking = true;
      _question = q;
      _answer = null;
    });
    try {
      final recap = _meeting.recap;
      final recapText = recap == null
          ? ''
          : [
              recap.headline,
              recap.arc,
              ...recap.decisions,
              ...recap.followUps.map((f) => '${f.owner} ${f.action} ${f.when}'),
            ].where((s) => s.trim().isNotEmpty).join('\n');
      final transcript = _meeting.segments.map((s) {
        final who = (s.speaker ?? '').trim();
        final clock = DateFormat.Hm().format(s.spokenAt.toLocal());
        return '${who.isEmpty ? 'Speaker' : who} $clock: ${s.text}';
      }).join('\n');
      final answer = await _refine.answerAboutMeeting(
        apiKey: key,
        question: q,
        recap: recapText,
        transcript: transcript,
      );
      if (!mounted) {
        return;
      }
      setState(() => _answer = answer);
      _ask.clear();
    } catch (e) {
      if (mounted) {
        setState(() => _answer = 'Could not answer: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _asking = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const MeshBackdrop(),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, size: 18),
              onPressed: () => Navigator.pop(context),
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                Text(
                  _meta,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: _Tabs(
                  value: _tab,
                  onChanged: (v) => setState(() => _tab = v),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    if (_tab == 'overview') _overview(),
                    if (_tab == 'transcript') ...[
                      TextField(
                        onChanged: (v) => setState(() {}),
                        controller: _searchCtl,
                        decoration: InputDecoration(
                          hintText: 'Search transcript',
                          prefixIcon: const Icon(Icons.search, size: 20),
                          filled: true,
                          fillColor: AppColors.mint,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: AppColors.line),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: AppColors.line),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TranscriptThread(
                        segments: _filteredSegs,
                        empty: 'No speech in this meeting yet.',
                      ),
                    ],
                    if (_tab == 'tasks') _tasks(),
                    if (_answer != null && _tab != 'tasks') ...[
                      const SizedBox(height: 12),
                      _answerCard(),
                    ],
                  ],
                ),
              ),
              if (_tab != 'tasks') _askBar(),
            ],
          ),
        ),
      ],
    );
  }

  List<TranscriptSegment> get _filteredSegs {
    final q = _searchCtl.text.trim().toLowerCase();
    final segs = _meeting.segments;
    if (q.isEmpty) {
      return segs;
    }
    return segs
        .where(
          (s) =>
              s.text.toLowerCase().contains(q) ||
              (s.speaker ?? '').toLowerCase().contains(q),
        )
        .toList();
  }

  Widget _overview() {
    final recap = _meeting.recap;
    final bullets = <String>[
      if (recap != null) ...[
        if (recap.arc.isNotEmpty) recap.arc,
        ...recap.chapters.map((c) => c.what),
        ...recap.decisions,
      ],
    ].where((s) => s.trim().isNotEmpty).take(4).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LiquidGlass(
          radius: 24,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'In 30 seconds',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 8),
                if (bullets.isEmpty)
                  Text(
                    recap == null
                        ? 'No recap yet. Generate one after the meeting.'
                        : recap.headline.isEmpty
                            ? 'Recap saved, but no summary lines yet.'
                            : recap.headline,
                    style: const TextStyle(height: 1.4),
                  )
                else
                  for (final b in bullets)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('•  ',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          Expanded(
                              child: Text(b,
                                  style: const TextStyle(height: 1.35))),
                        ],
                      ),
                    ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _recapping ? null : _recap,
            icon: _recapping
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_fix_high, size: 18),
            label: Text(
              recap == null ? 'Generate recap' : 'Refresh recap',
            ),
          ),
        ),
        const SizedBox(height: 8),
        _tasks(preview: true),
        if (_meeting.notes.isNotEmpty) ...[
          const SizedBox(height: 20),
          const Text(
            'Private notes',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          const SizedBox(height: 8),
          for (final n in _meeting.notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('• ${n.text}'),
            ),
        ],
      ],
    );
  }

  Widget _tasks({bool preview = false}) {
    final recap = _meeting.recap;
    final items = <({String title, String meta})>[
      if (recap != null) ...[
        for (final f in recap.followUps)
          (
            title: f.action,
            meta: [
              if (f.owner.trim().isNotEmpty) f.owner.trim(),
              if (f.when.trim().isNotEmpty) f.when.trim(),
            ].join(' · '),
          ),
        for (final loop in recap.openLoops) (title: loop, meta: 'Open'),
      ],
    ];
    if (items.isEmpty) {
      if (preview) {
        return const SizedBox.shrink();
      }
      return const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Text(
          'No action items yet. Generate a recap after the meeting.',
          style: TextStyle(color: AppColors.muted),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Action items',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < items.length; i++)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _done.contains(i),
            onChanged: (v) => setState(() {
              if (v == true) {
                _done.add(i);
              } else {
                _done.remove(i);
              }
            }),
            title: Text(
              items[i].title,
              style: TextStyle(
                decoration:
                    _done.contains(i) ? TextDecoration.lineThrough : null,
              ),
            ),
            subtitle: items[i].meta.isEmpty ? null : Text(items[i].meta),
          ),
      ],
    );
  }

  Widget _answerCard() {
    return LiquidGlass(
      radius: 24,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Ask OpenPendant',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            if (_question != null) ...[
              const SizedBox(height: 8),
              Text(
                _question!,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.ink,
                ),
              ),
            ],
            const SizedBox(height: 8),
            MdText(_answer ?? ''),
          ],
        ),
      ),
    );
  }

  Widget _askBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: LiquidGlass(
          radius: 28,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ask,
                    style: const TextStyle(color: AppColors.ink),
                    cursorColor: AppColors.ink,
                    decoration: const InputDecoration(
                      hintText: 'Ask about this meeting…',
                      hintStyle: TextStyle(color: AppColors.muted),
                      border: InputBorder.none,
                    ),
                    onSubmitted: (_) => _askMeeting(),
                  ),
                ),
                IconButton(
                  onPressed: _asking ? null : _askMeeting,
                  icon: _asking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.ink,
                          ),
                        )
                      : const Icon(Icons.arrow_upward, color: AppColors.ink),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget chip(String id, String label) {
      final on = value == id;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChanged(id),
          child: LiquidGlass(
            radius: 20,
            prominent: on,
            blur: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: on ? AppColors.rule : AppColors.muted,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        chip('transcript', 'Transcript'),
        const SizedBox(width: 8),
        chip('overview', 'Overview'),
        const SizedBox(width: 8),
        chip('tasks', 'Tasks'),
      ],
    );
  }
}
