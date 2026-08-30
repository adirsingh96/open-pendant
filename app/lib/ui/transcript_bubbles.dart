import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/models.dart';
import 'app_theme.dart';

/// Flat transcript thread: speaker + clock line, body text, hairline rule
/// down the left. Reads like a clean court record. Set [dark] on the
/// immersive recording screen.
class TranscriptThread extends StatelessWidget {
  const TranscriptThread({
    super.key,
    required this.segments,
    this.empty = 'Transcript will appear as speech is recognized.',
    this.dark = false,
  });

  final List<TranscriptSegment> segments;
  final String empty;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final segs = segments.where((s) => s.text.trim().isNotEmpty).toList();
    if (segs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          empty,
          textAlign: dark ? TextAlign.center : TextAlign.start,
          style: AppText.sub.copyWith(
            color: dark ? AppColors.onDarkMuted : AppColors.muted,
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final s in segs) TranscriptBubble(segment: s, dark: dark),
      ],
    );
  }
}

class TranscriptBubble extends StatelessWidget {
  const TranscriptBubble({super.key, required this.segment, this.dark = false});

  final TranscriptSegment segment;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final who = (segment.speaker ?? '').trim();
    final label = who.isEmpty ? 'Speaker' : who;
    final clock = DateFormat.Hm().format(segment.spokenAt.toLocal());
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: dark ? AppColors.onDarkLine : AppColors.lineStrong,
              width: 2,
            ),
          ),
        ),
        padding: const EdgeInsets.only(left: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  label,
                  style: AppText.label.copyWith(
                    fontSize: 12.5,
                    color: dark ? AppColors.onDark : AppColors.ink,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  clock,
                  style: AppText.monoSmall.copyWith(
                    fontSize: 10.5,
                    color: dark ? AppColors.onDarkMuted : AppColors.faint,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              segment.text.trim(),
              style: AppText.body.copyWith(
                fontSize: 14.5,
                color: dark ? const Color(0xE0F6F1EA) : AppColors.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
