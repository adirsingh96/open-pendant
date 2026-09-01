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
    this.pending = false,
    this.pendingLabel = 'Transcribing…',
  });

  final List<TranscriptSegment> segments;
  final String empty;
  final bool dark;
  final bool pending;
  final String pendingLabel;

  @override
  Widget build(BuildContext context) {
    final segs = segments.where((s) => s.text.trim().isNotEmpty).toList();
    if (segs.isEmpty) {
      if (pending) {
        return _TranscriptPending(dark: dark, label: pendingLabel);
      }
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
        if (pending)
          _TranscriptPending(
            dark: dark,
            label: pendingLabel,
            compact: true,
          ),
      ],
    );
  }
}

class _TranscriptPending extends StatelessWidget {
  const _TranscriptPending({
    required this.dark,
    required this.label,
    this.compact = false,
  });

  final bool dark;
  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = dark ? AppColors.onDarkMuted : AppColors.muted;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 12 : 28),
      child: Column(
        children: [
          SizedBox(
            width: compact ? 16 : 22,
            height: compact ? 16 : 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            textAlign: TextAlign.center,
            style: AppText.sub.copyWith(color: color, fontSize: 13),
          ),
        ],
      ),
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
