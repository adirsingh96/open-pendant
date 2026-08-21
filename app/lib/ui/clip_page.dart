import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../db/models.dart';
import '../stt/stt_pricing.dart';

class ClipPage extends StatefulWidget {
  const ClipPage({
    super.key,
    required this.clips,
    this.sessionLabel,
    this.rangeSegments,
    this.onRenameSpeaker,
    this.showDeveloper = false,
  });

  factory ClipPage.single({
    required ClipRecord clip,
    Future<void> Function(String from, String to)? onRenameSpeaker,
    bool showDeveloper = false,
  }) {
    return ClipPage(
      clips: [clip],
      onRenameSpeaker: onRenameSpeaker,
      showDeveloper: showDeveloper,
    );
  }

  factory ClipPage.session({
    required SessionGroup session,
    Future<void> Function(String from, String to)? onRenameSpeaker,
    bool showDeveloper = false,
  }) {
    return ClipPage(
      clips: session.clips,
      sessionLabel: 'Session · ${session.clips.length} chunks',
      onRenameSpeaker: onRenameSpeaker,
      showDeveloper: showDeveloper,
    );
  }

  factory ClipPage.range({
    required List<TranscriptSegment> segments,
    required String title,
    List<ClipRecord> clips = const [],
    Future<void> Function(String from, String to)? onRenameSpeaker,
    bool showDeveloper = false,
  }) {
    return ClipPage(
      clips: clips,
      sessionLabel: title,
      rangeSegments: segments,
      onRenameSpeaker: onRenameSpeaker,
      showDeveloper: showDeveloper,
    );
  }

  final List<ClipRecord> clips;
  final String? sessionLabel;
  final List<TranscriptSegment>? rangeSegments;
  final Future<void> Function(String from, String to)? onRenameSpeaker;
  final bool showDeveloper;

  static Color speakerTint(String? name, ColorScheme cs) {
    final n = (name ?? '').trim();
    if (n.isEmpty) {
      return cs.surfaceContainerHighest;
    }
    const hues = [0.45, 0.12, 0.62, 0.08, 0.78, 0.32];
    final h = hues[n.hashCode.abs() % hues.length];
    return HSVColor.fromAHSV(1, h * 360, 0.18, 0.94).toColor();
  }

  @override
  State<ClipPage> createState() => _ClipPageState();
}

class _ClipPageState extends State<ClipPage> {
  late List<TranscriptSegment> _segs;
  String _view = 'journal';

  @override
  void initState() {
    super.initState();
    _segs = widget.rangeSegments ??
        [
          for (final c in widget.clips) ...c.segments,
        ];
    if (widget.clips.any((c) => c.hasAltStt)) {
      _view = 'split';
    }
  }

  List<TranscriptSegment> get _altSegs {
    final out = [
      for (final c in widget.clips) ...c.altSegments,
    ]..sort((a, b) => a.spokenAt.compareTo(b.spokenAt));
    return out;
  }

  String get _altError {
    return widget.clips
        .map((c) => c.altError.trim())
        .where((e) => e.isNotEmpty)
        .join('\n');
  }

  Future<void> _rename(String from, String to) async {
    setState(() {
      _segs = [
        for (final s in _segs)
          (s.speaker ?? '').trim() == from ? s.copyWith(speaker: to) : s,
      ];
    });
    await widget.onRenameSpeaker?.call(from, to);
  }

  Widget _engineColumn({
    required BuildContext context,
    required String title,
    required List<TranscriptSegment> segs,
    required DateFormat clock,
    required bool showDeveloper,
    String empty = 'No speech.',
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        if (segs.isEmpty)
          Text(empty, style: Theme.of(context).textTheme.bodySmall)
        else
          for (var i = 0; i < segs.length; i++)
            _Turn(
              segment: segs[i],
              clock: clock,
              showTime: i == 0 ||
                  segs[i].spokenAt.difference(segs[i - 1].spokenAt) >
                      const Duration(minutes: 1),
              showRaw: showDeveloper,
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final clock = DateFormat.Hm();
    final segs = _segs;
    final clips = widget.clips;
    final sessionLabel = widget.sessionLabel;
    final showDeveloper = widget.showDeveloper;
    final visible = segs.where((s) => s.text.trim().isNotEmpty).toList();
    final title = clips.isNotEmpty
        ? DateFormat.MMMd().add_jm().format(clips.first.startedAt.toLocal())
        : (sessionLabel ?? 'Conversation');
    final copyBody = visible.map((s) => s.labeledText).join('\n');
    final alt = _altSegs;
    final altVisible = alt.where((s) => s.text.trim().isNotEmpty).toList();
    final hasCompare = widget.clips.any((c) => c.hasAltStt);
    final journalEngine = describeSttModels(clips.map((c) => c.sttModel));
    final altEngine = describeSttModels(clips.map((c) => c.altSttModel));
    final altCost = clips.fold(0.0, (a, c) => a + c.altCostUsd);
    final engine = hasCompare
        ? '${journalEngine.isEmpty ? 'Journal' : journalEngine} vs ${altEngine.isEmpty ? 'Sarvam' : altEngine}'
        : journalEngine;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy),
            onPressed: copyBody.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: copyBody));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Copied conversation')),
                      );
                    }
                  },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          if (engine.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                hasCompare ? 'A/B · $engine' : 'Transcribed with $engine',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (hasCompare) ...[
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'split', label: Text('Side by side')),
                ButtonSegment(value: 'journal', label: Text('OpenAI')),
                ButtonSegment(value: 'alt', label: Text('Saaras')),
              ],
              selected: {_view},
              onSelectionChanged: (s) => setState(() => _view = s.first),
            ),
            const SizedBox(height: 8),
            if (altCost > 0)
              Text(
                'Saaras ${SttPricing.formatUsd(altCost)} extra on this conversation',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (_altError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  'Saaras issue: $_altError',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                ),
              ),
            const SizedBox(height: 8),
          ],
          if (showDeveloper && clips.isNotEmpty) ...[
            Text(
              SessionGroup(sessionId: 'view', clips: clips).usageLine,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              'Cleanup ${SttPricing.formatUsd(clips.fold(0.0, (a, c) => a + c.refineCostUsd))}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
          ],
          if (!hasCompare && visible.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No speech in this conversation.'),
            )
          else if (hasCompare && _view == 'split')
            LayoutBuilder(
              builder: (context, box) {
                final stacked = box.maxWidth < 720;
                final openaiCol = _engineColumn(
                  context: context,
                  title: journalEngine.isEmpty ? 'OpenAI' : journalEngine,
                  segs: visible,
                  clock: clock,
                  showDeveloper: showDeveloper,
                );
                final saarasCol = _engineColumn(
                  context: context,
                  title: altEngine.isEmpty ? 'Saaras v4' : altEngine,
                  segs: altVisible,
                  clock: clock,
                  showDeveloper: showDeveloper,
                  empty: 'No Saaras transcript for this conversation.',
                );
                if (stacked) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [openaiCol, const SizedBox(height: 16), saarasCol],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: openaiCol),
                    const SizedBox(width: 12),
                    Expanded(child: saarasCol),
                  ],
                );
              },
            )
          else
            for (var i = 0; i < (_view == 'alt' ? altVisible : visible).length; i++)
              _Turn(
                segment: (_view == 'alt' ? altVisible : visible)[i],
                clock: clock,
                showTime: i == 0 ||
                    (_view == 'alt' ? altVisible : visible)[i]
                            .spokenAt
                            .difference(
                              (_view == 'alt' ? altVisible : visible)[i - 1]
                                  .spokenAt,
                            ) >
                        const Duration(minutes: 1),
                showRaw: showDeveloper,
                onRename: widget.onRenameSpeaker == null || _view == 'alt'
                    ? null
                    : _rename,
              ),
        ],
      ),
    );
  }
}

class _Turn extends StatelessWidget {
  const _Turn({
    required this.segment,
    required this.clock,
    required this.showTime,
    required this.showRaw,
    this.onRename,
  });

  final TranscriptSegment segment;
  final DateFormat clock;
  final bool showTime;
  final bool showRaw;
  final Future<void> Function(String from, String to)? onRename;

  @override
  Widget build(BuildContext context) {
    final who = (segment.speaker ?? '').trim();
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTime)
            Padding(
              padding: const EdgeInsets.only(bottom: 4, left: 4),
              child: Text(
                clock.format(segment.spokenAt.toLocal()),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Material(
                color: ClipPage.speakerTint(who, cs),
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (who.isNotEmpty)
                        InkWell(
                          onTap: onRename == null
                              ? null
                              : () => _rename(context, who),
                          child: Text(
                            who,
                            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                      SelectableText(segment.text),
                      if (showRaw &&
                          segment.rawText.trim().isNotEmpty &&
                          segment.rawText.trim() != segment.text.trim())
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'Raw: ${segment.rawText}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context, String from) async {
    final ctl = TextEditingController(text: from);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this speaker'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctl.dispose();
    final name = next?.trim() ?? '';
    if (name.isEmpty || name == from) {
      return;
    }
    await onRename!(from, name);
  }
}
