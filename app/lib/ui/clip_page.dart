import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/models.dart';

class ClipPage extends StatelessWidget {
  const ClipPage({super.key, required this.clip});

  final ClipRecord clip;

  @override
  Widget build(BuildContext context) {
    final clock = DateFormat.Hms();
    return Scaffold(
      appBar: AppBar(title: Text(DateFormat.yMMMd().add_Hms().format(clip.startedAt.toLocal()))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('${clip.durationS.toStringAsFixed(1)}s  ${clip.sttModel ?? ''}  ${clip.status}'),
          const SizedBox(height: 12),
          if (clip.segments.isEmpty) Text(clip.fullText),
          for (final s in clip.segments)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 88,
                    child: Text(
                      clock.format(s.spokenAt.toLocal()),
                      style: Theme.of(context).textTheme.labelLarge,
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
