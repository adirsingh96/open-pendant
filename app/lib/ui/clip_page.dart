import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/models.dart';

class ClipPage extends StatelessWidget {
  const ClipPage({
    super.key,
    required this.clips,
    this.sessionLabel,
    this.rangeSegments,
  });

  factory ClipPage.single({required ClipRecord clip}) {
    return ClipPage(clips: [clip]);
  }

  factory ClipPage.session({required SessionGroup session}) {
    return ClipPage(
      clips: session.clips,
      sessionLabel: 'Session · ${session.clips.length} chunks',
    );
  }

  factory ClipPage.range({
    required List<TranscriptSegment> segments,
    required String title,
  }) {
    return ClipPage(
      clips: const [],
      sessionLabel: title,
      rangeSegments: segments,
    );
  }

  final List<ClipRecord> clips;
  final String? sessionLabel;
  final List<TranscriptSegment>? rangeSegments;

  @override
  Widget build(BuildContext context) {
    final clock = DateFormat.Hms();
    final segs = rangeSegments ??
        [
          for (final c in clips) ...c.segments,
        ];
    final full = clips
        .map((c) => c.fullText.trim())
        .where((t) => t.isNotEmpty)
        .join('\n\n');
    final title = clips.isNotEmpty
        ? DateFormat.yMMMd().add_Hms().format(clips.first.startedAt.toLocal())
        : (sessionLabel ?? 'Transcript');
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (clips.isNotEmpty) ...[
            Text(
              '${clips.length} chunk${clips.length == 1 ? '' : 's'}  '
              '${sessionLabel ?? clips.first.sttModel ?? ''}  ${clips.first.status}',
            ),
            const SizedBox(height: 6),
            Text(
              SessionGroup(sessionId: 'view', clips: clips).usageLine,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (clips.length > 1) ...[
              const SizedBox(height: 8),
              for (final c in clips)
                if (c.status == 'ok' || c.removedS > 0 || c.billedS > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '#${c.seq}  ${c.sttModel ?? c.status}  ${c.usageLine}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
            ],
          ] else
            Text('${segs.length} lines  ${sessionLabel ?? ''}'),
          const SizedBox(height: 12),
          if (segs.isEmpty) Text(full.isEmpty ? 'No speech in this range.' : full),
          for (final s in segs)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 88,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          clock.format(s.spokenAt.toLocal()),
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        if ((s.speaker ?? '').trim().isNotEmpty)
                          Text(
                            s.speaker!.trim(),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                      ],
                    ),
                  ),
                  Expanded(child: Text(s.text)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
