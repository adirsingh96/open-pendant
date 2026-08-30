import 'day_recap.dart';
import 'models.dart';
import 'scene_group.dart';

class MeetingRecord {
  MeetingRecord({
    required this.id,
    required this.startedAt,
    this.endedAt,
    this.title = '',
    this.recap,
    this.segments = const [],
    this.notes = const [],
    this.clips = const [],
  });

  final String id;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String title;
  final DayRecap? recap;
  final List<TranscriptSegment> segments;
  final List<SpokenNote> notes;
  final List<ClipRecord> clips;

  bool get live => endedAt == null;

  Duration durationAt(DateTime now) {
    final end = endedAt ?? now;
    final d = end.difference(startedAt);
    if (d.isNegative) {
      return Duration.zero;
    }
    return d;
  }

  String timeRangeLabel({DateTime? now}) {
    final a = startedAt.toLocal();
    final end = endedAt ?? now;
    final start = SceneGroup.clock(a);
    if (end == null) {
      return '$start to now';
    }
    final b = end.toLocal();
    if (b.difference(a) < const Duration(minutes: 1)) {
      return start;
    }
    return '$start to ${SceneGroup.clock(b)}';
  }

  List<String> get displaySpeakers {
    if (recap != null && recap!.people.isNotEmpty) {
      return recap!.people;
    }
    return SceneGroup(segments: segments).displaySpeakers;
  }

  String get preview {
    final h = recap?.headline.trim() ?? '';
    if (h.isNotEmpty) {
      return h;
    }
    return SceneGroup(segments: segments).preview;
  }

  MeetingRecord copyWith({
    DateTime? endedAt,
    String? title,
    DayRecap? recap,
    List<TranscriptSegment>? segments,
    List<SpokenNote>? notes,
    List<ClipRecord>? clips,
    bool clearEnded = false,
  }) {
    return MeetingRecord(
      id: id,
      startedAt: startedAt,
      endedAt: clearEnded ? null : (endedAt ?? this.endedAt),
      title: title ?? this.title,
      recap: recap ?? this.recap,
      segments: segments ?? this.segments,
      notes: notes ?? this.notes,
      clips: clips ?? this.clips,
    );
  }
}
