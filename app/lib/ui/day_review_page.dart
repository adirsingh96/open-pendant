import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../db/day_recap.dart';
import '../db/models.dart';
import '../notes/recap_tasks.dart';
import 'app_theme.dart';
import 'circle_button.dart';
import 'page_scaffold.dart';

class DayReviewPage extends StatefulWidget {
  const DayReviewPage({
    super.key,
    required this.recap,
    required this.notes,
    required this.onTaskDone,
    required this.onRefresh,
  });

  final DayRecap recap;
  final List<SpokenNote> notes;
  final Future<void> Function(String id, bool done) onTaskDone;
  final Future<DayRecap?> Function() onRefresh;

  @override
  State<DayReviewPage> createState() => _DayReviewPageState();
}

class _DayReviewPageState extends State<DayReviewPage> {
  late DayRecap _recap = widget.recap;
  bool _refreshing = false;
  late final Map<String, bool> _done = {
    for (final note in widget.notes) note.id: note.done,
  };

  Future<void> _refresh() async {
    final replace = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Refresh today’s recap?'),
        content: const Text(
          'This uses OpenAI again and replaces the current recap with a fresh '
          'one that includes anything recorded since the last run.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Refresh'),
          ),
        ],
      ),
    );
    if (replace != true || !mounted) {
      return;
    }
    setState(() => _refreshing = true);
    final recap = await widget.onRefresh();
    if (!mounted) {
      return;
    }
    setState(() {
      if (recap != null) {
        _recap = recap;
      }
      _refreshing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final recap = _recap;
    String actualNoteId(String expected, String text) {
      for (final note in widget.notes) {
        if (note.id == expected) {
          return expected;
        }
      }
      final normalized = text.trim().toLowerCase();
      for (final note in widget.notes) {
        if (note.text.trim().toLowerCase() == normalized) {
          return note.id;
        }
      }
      return expected;
    }

    final tasks = <({String id, String text, String meta})>[
      for (final item in recap.followUps)
        (
          id: actualNoteId(
            recapTaskId(
              scope: recap.dayKey,
              kind: 'task',
              text: item.action,
            ),
            item.action,
          ),
          text: item.action,
          meta: [item.owner, item.when]
              .where((part) => part.trim().isNotEmpty)
              .join(' · '),
        ),
      for (final item in recap.openLoops)
        (
          id: actualNoteId(
            recapTaskId(
              scope: recap.dayKey,
              kind: 'loop',
              text: item,
            ),
            item,
          ),
          text: item,
          meta: 'Open loop',
        ),
    ];
    return PageScaffold(
      title: recap.headline.isEmpty ? 'Day review' : recap.headline,
      caption: recap.dayKey,
      actions: [
        CircleIconButton(
          icon: LucideIcons.refreshCw,
          onTap: _refreshing ? null : _refresh,
          tooltip: _refreshing ? 'Refreshing recap' : 'Refresh recap',
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(28, 8, 28, 32),
        children: [
          if (recap.arc.isNotEmpty)
            Text(recap.arc, style: AppText.body.copyWith(height: 1.55)),
          if (tasks.isNotEmpty) ...[
            const SizedBox(height: 28),
            Text('OPEN LOOPS', style: AppText.micro),
            const SizedBox(height: 8),
            for (final task in tasks)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _done[task.id] ?? false,
                onChanged: (value) async {
                  final done = value == true;
                  setState(() => _done[task.id] = done);
                  await widget.onTaskDone(task.id, done);
                },
                title: Text(
                  task.text,
                  style: TextStyle(
                    decoration: (_done[task.id] ?? false)
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
                subtitle: task.meta.isEmpty ? null : Text(task.meta),
              ),
          ],
          if (recap.chapters.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('THE DAY', style: AppText.micro),
            const SizedBox(height: 14),
            for (final chapter in recap.chapters) ...[
              Text(
                chapter.when.isEmpty
                    ? chapter.title
                    : '${chapter.when}  ${chapter.title}',
                style: AppText.label,
              ),
              const SizedBox(height: 5),
              Text(
                chapter.what,
                style: AppText.sub.copyWith(fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 20),
            ],
          ],
          if (recap.decisions.isNotEmpty) ...[
            Text('DECISIONS', style: AppText.micro),
            const SizedBox(height: 10),
            for (final decision in recap.decisions)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('• $decision', style: AppText.body),
              ),
          ],
        ],
      ),
    );
  }
}
