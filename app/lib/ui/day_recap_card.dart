import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/day_recap.dart';
import '../stt/stt_pricing.dart';

class DayRecapCard extends StatelessWidget {
  const DayRecapCard({
    super.key,
    required this.day,
    this.recap,
    this.stale = false,
  });

  final DateTime day;
  final DayRecap? recap;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final recap = this.recap;
    final dayLabel = DateFormat.yMMMMEEEEd().format(day);
    final when = recap?.updatedAt?.toLocal();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Day', style: Theme.of(context).textTheme.labelSmall),
            Text(dayLabel, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text('Summarized', style: Theme.of(context).textTheme.labelSmall),
            Text(
              when == null
                  ? 'Not yet — tap Clean this day'
                  : DateFormat.MMMd().add_jm().format(when),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (when != null && recap != null && recap.costUsd > 0)
              Text(
                SttPricing.formatUsd(recap.costUsd),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            if (stale) ...[
              const SizedBox(height: 8),
              Text(
                'New recordings since this recap. Clean this day again to refresh.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
              ),
            ],
            if (recap == null) ...[
              const SizedBox(height: 10),
              Text('No recap yet for $dayLabel.'),
            ] else ...[
              const SizedBox(height: 12),
              Text(
                recap.headline.isEmpty ? 'Day recap' : recap.headline,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (recap.people.isNotEmpty || recap.languages.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    [
                      if (recap.people.isNotEmpty) recap.people.join(', '),
                      if (recap.languages.isNotEmpty)
                        recap.languages.join(' · '),
                    ].join('  ·  '),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (recap.arc.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Story', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(recap.arc),
              ],
              if (recap.chapters.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text('Chapters', style: Theme.of(context).textTheme.titleSmall),
              ],
              for (final c in recap.chapters) ...[
                const SizedBox(height: 10),
                Text(
                  [
                    if (c.when.isNotEmpty) c.when,
                    if (c.title.isNotEmpty) c.title,
                  ].join(' · '),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(c.what),
              ],
              if (recap.decisions.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  'Decisions',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                for (final d in recap.decisions) Text('• $d'),
              ],
              if (recap.followUps.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  'Follow-ups',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                for (final f in recap.followUps)
                  Text(
                    '• ${[
                      if (f.owner.isNotEmpty) f.owner,
                      f.action,
                      if (f.when.isNotEmpty) f.when,
                    ].join(' — ')}',
                  ),
              ],
              if (recap.openLoops.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text('Open loops',
                    style: Theme.of(context).textTheme.titleSmall),
                for (final o in recap.openLoops) Text('• $o'),
              ],
              if (recap.noise.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(recap.noise, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
