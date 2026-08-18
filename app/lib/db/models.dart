class TranscriptSegment {
  TranscriptSegment({
    required this.startS,
    required this.endS,
    required this.spokenAt,
    required this.text,
  });

  final double startS;
  final double endS;
  final DateTime spokenAt;
  final String text;
}

class TranscriptResult {
  TranscriptResult({
    required this.text,
    required this.model,
    required this.segments,
  });

  final String text;
  final String model;
  final List<TranscriptSegment> segments;
}

class ClipRecord {
  ClipRecord({
    required this.id,
    required this.startedAt,
    required this.durationS,
    required this.fullText,
    required this.wavPath,
    required this.sttModel,
    required this.status,
    this.segments = const [],
  });

  final String id;
  final DateTime startedAt;
  final double durationS;
  final String fullText;
  final String? wavPath;
  final String? sttModel;
  final String status;
  final List<TranscriptSegment> segments;
}
