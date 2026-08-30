import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/models.dart';
import 'app_theme.dart';
import 'liquid_glass.dart';

class TranscriptThread extends StatelessWidget {
  const TranscriptThread({
    super.key,
    required this.segments,
    this.empty = 'Transcript will appear as speech is recognized.',
  });

  final List<TranscriptSegment> segments;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final segs = segments.where((s) => s.text.trim().isNotEmpty).toList();
    if (segs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          empty,
          style: const TextStyle(color: AppColors.muted),
        ),
      );
    }
    return Column(
      children: [
        for (final s in segs) TranscriptBubble(segment: s),
      ],
    );
  }
}

class TranscriptBubble extends StatelessWidget {
  const TranscriptBubble({super.key, required this.segment});

  final TranscriptSegment segment;

  @override
  Widget build(BuildContext context) {
    final who = (segment.speaker ?? '').trim();
    final label = who.isEmpty ? 'Speaker' : who;
    final clock = DateFormat.Hm().format(segment.spokenAt.toLocal());
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: LiquidGlass(
        radius: 22,
        blur: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: label,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: AppColors.ink,
                      ),
                    ),
                    TextSpan(
                      text: '  $clock',
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontWeight: FontWeight.w500,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                segment.text.trim(),
                style: const TextStyle(
                  height: 1.4,
                  color: AppColors.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
