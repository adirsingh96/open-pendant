import '../stt/stt_pricing.dart';

class TranscriptSegment {
  TranscriptSegment({
    required this.startS,
    required this.endS,
    required this.spokenAt,
    required this.text,
    this.speaker,
  });

  final double startS;
  final double endS;
  final DateTime spokenAt;
  final String text;
  final String? speaker;

  String get labeledText {
    final t = text.trim();
    if (t.isEmpty) {
      return '';
    }
    final who = speaker?.trim();
    if (who == null || who.isEmpty) {
      return t;
    }
    return '$who: $t';
  }
}

class TranscriptResult {
  TranscriptResult({
    required this.text,
    required this.model,
    required this.segments,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.costUsd = 0,
  });

  final String text;
  final String model;
  final List<TranscriptSegment> segments;
  final int inputTokens;
  final int outputTokens;
  final double costUsd;
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
    this.sessionId,
    this.seq = 0,
    this.billedS = 0,
    this.removedS = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.costUsd = 0,
    this.segments = const [],
  });

  final String id;
  final DateTime startedAt;
  final double durationS;
  final String fullText;
  final String? wavPath;
  final String? sttModel;
  final String status;
  final String? sessionId;
  final int seq;
  final double billedS;
  final double removedS;
  final int inputTokens;
  final int outputTokens;
  final double costUsd;
  final List<TranscriptSegment> segments;

  int get totalTokens => inputTokens + outputTokens;

  String get usageLine {
    final captured = durationS.toStringAsFixed(1);
    final sent = billedS.toStringAsFixed(1);
    final cut = removedS.toStringAsFixed(1);
    final tok = totalTokens > 0
        ? '  $inputTokens in / $outputTokens out tok'
        : '';
    final name = sttModel;
    final model = (name != null && name.isNotEmpty) ? ' · $name' : '';
    return 'Captured ${captured}s · removed ${cut}s · sent ${sent}s'
        '$tok$model  ${SttPricing.formatUsd(costUsd)}';
  }

  ClipRecord copyWith({
    String? fullText,
    String? sttModel,
    String? status,
    List<TranscriptSegment>? segments,
    double? billedS,
    double? removedS,
    int? inputTokens,
    int? outputTokens,
    double? costUsd,
  }) {
    return ClipRecord(
      id: id,
      startedAt: startedAt,
      durationS: durationS,
      fullText: fullText ?? this.fullText,
      wavPath: wavPath,
      sttModel: sttModel ?? this.sttModel,
      status: status ?? this.status,
      sessionId: sessionId,
      seq: seq,
      billedS: billedS ?? this.billedS,
      removedS: removedS ?? this.removedS,
      inputTokens: inputTokens ?? this.inputTokens,
      outputTokens: outputTokens ?? this.outputTokens,
      costUsd: costUsd ?? this.costUsd,
      segments: segments ?? this.segments,
    );
  }
}

/// One Record-arm session: clips in seq order, text stitched for the home list.
class SessionGroup {
  SessionGroup({required this.sessionId, required this.clips});

  final String sessionId;
  final List<ClipRecord> clips;

  DateTime get startedAt => clips.first.startedAt;

  double get durationS => clips.fold(0, (a, c) => a + c.durationS);

  double get billedS => clips.fold(0.0, (a, c) => a + c.billedS);

  double get removedS => clips.fold(0.0, (a, c) => a + c.removedS);

  int get inputTokens => clips.fold(0, (a, c) => a + c.inputTokens);

  int get outputTokens => clips.fold(0, (a, c) => a + c.outputTokens);

  double get costUsd => clips.fold(0.0, (a, c) => a + c.costUsd);

  String get fullText {
    final parts = clips
        .map((c) => c.fullText.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    return parts.join(' ');
  }

  String get status {
    if (clips.any((c) => c.status == 'transcribing')) {
      return 'transcribing';
    }
    if (clips.any((c) => c.status == 'error')) {
      return 'error';
    }
    if (clips.every((c) => c.status == 'silence')) {
      return 'silence';
    }
    if (clips.any((c) => c.status == 'ok')) {
      return 'ok';
    }
    return clips.last.status;
  }

  List<TranscriptSegment> get segments {
    final out = <TranscriptSegment>[];
    for (final c in clips) {
      out.addAll(c.segments);
    }
    return out;
  }

  String get usageLine {
    final tok = (inputTokens + outputTokens) > 0
        ? '  $inputTokens in / $outputTokens out tok'
        : '';
    final models = clips
        .map((c) => c.sttModel)
        .whereType<String>()
        .where((m) => m.isNotEmpty)
        .toSet()
        .join(', ');
    final model = models.isEmpty ? '' : ' · $models';
    return 'Captured ${durationS.toStringAsFixed(1)}s · removed ${removedS.toStringAsFixed(1)}s · '
        'sent ${billedS.toStringAsFixed(1)}s$tok$model  ${SttPricing.formatUsd(costUsd)}';
  }
}
