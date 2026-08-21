import 'models.dart';

/// Conversation pause: a gap of this length starts a new scene.
const sceneGap = Duration(minutes: 3);

class SceneGroup {
  SceneGroup({required this.segments});

  final List<TranscriptSegment> segments;

  DateTime get startedAt => segments.first.spokenAt;

  DateTime get endedAt => segments.last.spokenAt;

  List<String> get speakers {
    final names = <String>[];
    final seen = <String>{};
    for (final s in segments) {
      final w = (s.speaker ?? '').trim();
      if (w.isEmpty || !seen.add(w.toLowerCase())) {
        continue;
      }
      names.add(w);
    }
    return names;
  }

  List<String> get displaySpeakers =>
      speakers.where(isDisplaySpeaker).toList();

  String timeRangeLabel() {
    final a = startedAt.toLocal();
    final b = endedAt.toLocal();
    final start = _clock(a);
    if (b.difference(a) < const Duration(minutes: 1)) {
      return start;
    }
    return '$start–${_clock(b)}';
  }

  static bool isDisplaySpeaker(String w) {
    final t = w.trim();
    if (t.isEmpty) {
      return false;
    }
    return RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(t);
  }

  static String _clock(DateTime t) {
    final h = t.hour;
    final m = t.minute.toString().padLeft(2, '0');
    final am = h >= 12;
    var hr = h % 12;
    if (hr == 0) {
      hr = 12;
    }
    return '$hr:$m ${am ? 'PM' : 'AM'}';
  }

  String get preview {
    final parts = segments
        .map((s) => s.labeledText)
        .where((t) => t.isNotEmpty)
        .take(3)
        .toList();
    return parts.join(' ');
  }

  static List<SceneGroup> fromSegments(
    List<TranscriptSegment> input, {
    Duration gap = sceneGap,
  }) {
    final segs = input
        .where((s) => s.text.trim().isNotEmpty)
        .toList()
      ..sort((a, b) => a.spokenAt.compareTo(b.spokenAt));
    if (segs.isEmpty) {
      return [];
    }
    final scenes = <SceneGroup>[];
    var bucket = <TranscriptSegment>[segs.first];
    for (var i = 1; i < segs.length; i++) {
      final prev = bucket.last.spokenAt;
      final cur = segs[i].spokenAt;
      if (cur.difference(prev) >= gap) {
        scenes.add(SceneGroup(segments: List.of(bucket)));
        bucket = [segs[i]];
      } else {
        bucket.add(segs[i]);
      }
    }
    scenes.add(SceneGroup(segments: bucket));
    return scenes.reversed.toList();
  }
}
