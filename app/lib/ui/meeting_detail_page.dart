import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../calendar/note_command.dart';
import '../db/meeting.dart';
import '../db/models.dart';
import '../notes/recap_tasks.dart';
import '../stt/api_key_store.dart';
import '../stt/openai_refine.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'app_theme.dart';
import 'circle_button.dart';
import 'liquid_glass.dart';
import 'mesh_backdrop.dart';
import 'md_text.dart';
import 'transcript_bubbles.dart';

class MeetingDetailPage extends StatefulWidget {
  const MeetingDetailPage({
    super.key,
    required this.meeting,
    required this.onRecap,
    required this.onRename,
    required this.onTaskDone,
    required this.reload,
  });

  final MeetingRecord meeting;
  final Future<void> Function() onRecap;
  final Future<void> Function(String title) onRename;
  final Future<void> Function(String noteId, bool done) onTaskDone;
  final Future<MeetingRecord?> Function() reload;

  @override
  State<MeetingDetailPage> createState() => _MeetingDetailPageState();
}

class _MeetingDetailPageState extends State<MeetingDetailPage> {
  late MeetingRecord _meeting;
  String _tab = 'transcript';
  final _ask = TextEditingController();
  final _searchCtl = TextEditingController();
  final _titleCtl = TextEditingController();
  final _titleFocus = FocusNode();
  final _refine = OpenAiRefine();
  String? _question;
  String? _answer;
  bool _asking = false;
  bool _editingTitle = false;
  Timer? _sttPoll;

  bool get _awaitingTranscript =>
      _meeting.transcribing || (_meeting.live && !_meeting.hasSpokenText);

  @override
  void initState() {
    super.initState();
    _meeting = widget.meeting;
    _titleFocus.addListener(_onTitleFocusChange);
    _sttPoll = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_pollTranscript());
    });
  }

  Future<void> _pollTranscript() async {
    if (!mounted || !_awaitingTranscript) {
      return;
    }
    final next = await widget.reload();
    if (next != null && mounted) {
      setState(() => _meeting = next);
    }
  }

  @override
  void dispose() {
    _sttPoll?.cancel();
    _titleFocus.removeListener(_onTitleFocusChange);
    _titleFocus.dispose();
    _titleCtl.dispose();
    _ask.dispose();
    _searchCtl.dispose();
    super.dispose();
  }

  String get _title {
    final t = _meeting.title.trim();
    if (t.isNotEmpty) {
      return t;
    }
    final h = _meeting.recap?.headline.trim() ?? '';
    if (h.isNotEmpty) {
      return h;
    }
    return 'Meeting';
  }

  void _onTitleFocusChange() {
    if (!_titleFocus.hasFocus && _editingTitle) {
      _commitRename();
    }
  }

  void _beginRename() {
    _titleCtl.text = _title;
    _titleCtl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _titleCtl.text.length,
    );
    setState(() => _editingTitle = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _titleFocus.requestFocus();
      }
    });
  }

  void _cancelRename() {
    if (!_editingTitle) {
      return;
    }
    setState(() => _editingTitle = false);
    _titleCtl.text = _title;
    _titleFocus.unfocus();
  }

  Future<void> _commitRename() async {
    if (!_editingTitle) {
      return;
    }
    final next = _titleCtl.text.trim();
    setState(() => _editingTitle = false);
    if (next.isEmpty || next == _title) {
      return;
    }
    await widget.onRename(next);
    if (mounted) {
      setState(() => _meeting = _meeting.copyWith(title: next));
    }
  }

  String get _meta {
    final start = _meeting.startedAt.toLocal();
    final now = DateTime.now();
    final dur = _meeting.durationAt(now);
    final mins = dur.inMinutes;
    final day = DateFormat.MMMd().format(start);
    final clock = DateFormat.jm().format(start);
    final when = _isToday(start) ? 'Today' : day;
    final length = mins < 1 ? 'under a minute' : '$mins min';
    return '$when · $clock · $length';
  }

  bool _isToday(DateTime t) {
    final n = DateTime.now();
    final l = t.toLocal();
    return l.year == n.year && l.month == n.month && l.day == n.day;
  }

  Widget _titleBlock() {
    final style = AppText.headline.copyWith(
      fontSize: 25,
      height: 1.15,
    );
    if (_editingTitle) {
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _cancelRename,
        },
        child: TextField(
          controller: _titleCtl,
          focusNode: _titleFocus,
          style: style,
          maxLines: 2,
          minLines: 1,
          textInputAction: TextInputAction.done,
          cursorColor: AppColors.accent,
          onSubmitted: (_) => _commitRename(),
          decoration: const InputDecoration(
            filled: false,
            isDense: true,
            contentPadding: EdgeInsets.zero,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.accent, width: 1.5),
            ),
          ),
        ),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onDoubleTap: _beginRename,
        child: Tooltip(
          message: 'Double-click to rename',
          waitDuration: const Duration(milliseconds: 600),
          child: Text(
            _title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ),
    );
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
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _titleBlock(),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Icon(
                                LucideIcons.clock,
                                size: 13,
                                color: AppColors.faint,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                _meta,
                                style: AppText.sub.copyWith(fontSize: 12.5),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: _Tabs(
                        value: _tab,
                        onChanged: (v) => setState(() => _tab = v),
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                        children: [
                          if (_tab == 'overview') _overview(),
                          if (_tab == 'transcript') ...[
                            TextField(
                              onChanged: (v) => setState(() {}),
                              controller: _searchCtl,
                              decoration: const InputDecoration(
                                hintText: 'Search transcript',
                                prefixIcon: Icon(
                                  LucideIcons.search,
                                  size: 17,
                                  color: AppColors.muted,
                                ),
                              ),
                            ),
                            const SizedBox(height: 18),
                            TranscriptThread(
                              segments: _filteredSegs,
                              pending: _awaitingTranscript,
                              pendingLabel: 'Transcribing…',
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
            ),
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
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerLeft,
          child: _GradientPillButton(
            label: recap == null ? 'Generate recap' : 'Refresh recap',
            busy: _recapping,
            onTap: _recapping ? null : _recap,
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
              child: Text('• ${noteTextWithoutSpeakers(n.text)}'),
            ),
        ],
      ],
    );
  }

  Widget _tasks({bool preview = false}) {
    final recap = _meeting.recap;
    final doneById = {for (final note in _meeting.notes) note.id: note.done};
    final items = <({String id, String title, String meta})>[
      if (recap != null) ...[
        for (final f in recap.followUps)
          (
            id: recapTaskId(
              scope: _meeting.id,
              kind: 'task',
              text: f.action,
            ),
            title: f.action,
            meta: [
              if (f.owner.trim().isNotEmpty) f.owner.trim(),
              if (f.when.trim().isNotEmpty) f.when.trim(),
            ].join(' · '),
          ),
        for (final loop in recap.openLoops)
          (
            id: recapTaskId(
              scope: _meeting.id,
              kind: 'loop',
              text: loop,
            ),
            title: loop,
            meta: 'Open',
          ),
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
            value: doneById[items[i].id] ?? false,
            onChanged: (v) async {
              await widget.onTaskDone(items[i].id, v == true);
              final next = await widget.reload();
              if (next != null && mounted) {
                setState(() => _meeting = next);
              }
            },
            title: Text(
              items[i].title,
              style: TextStyle(
                decoration: (doneById[items[i].id] ?? false)
                    ? TextDecoration.lineThrough
                    : null,
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
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: AppColors.lineStrong),
          ),
          padding: const EdgeInsets.fromLTRB(18, 5, 7, 5),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ask,
                  style: AppText.body.copyWith(fontSize: 14.5),
                  cursorColor: AppColors.ink,
                  decoration: InputDecoration(
                    hintText: 'Ask about this meeting…',
                    hintStyle: AppText.body.copyWith(
                      fontSize: 14.5,
                      color: AppColors.faint,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  onSubmitted: (_) => _askMeeting(),
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: AppColors.accent,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _asking ? null : _askMeeting,
                  child: SizedBox(
                    width: 38,
                    height: 38,
                    child: _asking
                        ? const Padding(
                            padding: EdgeInsets.all(10),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(
                            LucideIcons.arrowUp,
                            size: 17,
                            color: Colors.white,
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// White pill with gradient icon + gradient text — the "AI action" button.
class _GradientPillButton extends StatelessWidget {
  const _GradientPillButton({
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool busy;

  static const _gradient = LinearGradient(
    colors: [Color(0xFFFF4D00), Color(0xFFE0577B), Color(0xFF9E6BEF)],
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.lineStrong),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  ShaderMask(
                    blendMode: BlendMode.srcIn,
                    shaderCallback: (r) => _gradient.createShader(r),
                    child: const Icon(LucideIcons.sparkles,
                        size: 14, color: Colors.white),
                  ),
                const SizedBox(width: 8),
                ShaderMask(
                  blendMode: BlendMode.srcIn,
                  shaderCallback: (r) => _gradient.createShader(r),
                  child: Text(
                    busy ? 'Working…' : label,
                    style: AppText.label.copyWith(
                      fontSize: 13.5,
                      color: Colors.white,
                    ),
                  ),
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
    Widget seg(String id, String label) {
      final on = value == id;
      return Padding(
        padding: const EdgeInsets.only(right: 22),
        child: GestureDetector(
          onTap: () => onChanged(id),
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
        seg('transcript', 'Transcript'),
        seg('overview', 'Overview'),
        seg('tasks', 'Tasks'),
      ],
    );
  }
}
