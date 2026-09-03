import '../db/day_recap.dart';
import '../db/models.dart';

String recapTaskId({
  required String scope,
  required String kind,
  required String text,
}) {
  var hash = 0x811c9dc5;
  for (final unit in text.trim().toLowerCase().codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return '$kind:$scope:${hash.toRadixString(16).padLeft(8, '0')}';
}

List<SpokenNote> notesFromRecap({
  required DayRecap recap,
  required String scope,
  String? meetingId,
  DateTime? createdAt,
}) {
  final at = createdAt ?? DateTime.now().toUtc();
  return [
    for (final followUp in recap.followUps)
      SpokenNote(
        id: recapTaskId(
          scope: scope,
          kind: 'task',
          text: followUp.action,
        ),
        createdAt: at,
        text: followUp.action,
        meetingId: meetingId,
      ),
    for (final loop in recap.openLoops)
      SpokenNote(
        id: recapTaskId(scope: scope, kind: 'loop', text: loop),
        createdAt: at,
        text: loop,
        meetingId: meetingId,
      ),
  ];
}
