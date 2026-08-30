import 'dart:convert';

import '../stt/stt_pricing.dart';

class TranscriptSegment {
  TranscriptSegment({
    required this.startS,
    required this.endS,
    required this.spokenAt,
    required this.text,
    this.speaker,
    this.id,
    this.clipId,
    this.rawText = '',
  });

  final int? id;
  final String? clipId;
  final double startS;
  final double endS;
  final DateTime spokenAt;
  final String text;
  final String rawText;
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

  String get rawLabeledText {
    final t = (rawText.trim().isEmpty ? text : rawText).trim();
    if (t.isEmpty) {
      return '';
    }
    final who = speaker?.trim();
    if (who == null || who.isEmpty) {
      return t;
    }
    return '$who: $t';
  }

  TranscriptSegment copyWith({
    String? text,
    String? rawText,
    String? speaker,
  }) {
    return TranscriptSegment(
      id: id,
      clipId: clipId,
      startS: startS,
      endS: endS,
      spokenAt: spokenAt,
      text: text ?? this.text,
      rawText: rawText ?? this.rawText,
      speaker: speaker ?? this.speaker,
    );
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

String describeSttModels(Iterable<String?> models) {
  final names = models
      .whereType<String>()
      .map((m) => m.trim())
      .where((m) => m.isNotEmpty)
      .toSet()
      .toList()
    ..sort();
  return names.map(prettySttModel).join(' · ');
}

String prettySttModel(String model) {
  if (model.contains('saaras')) {
    if (model.contains('diar')) {
      return 'Sarvam Saaras v4 + diarize';
    }
    return 'Sarvam Saaras v4';
  }
  return model;
}

List<Map<String, Object?>> encodeAltSegments(List<TranscriptSegment> segs) {
  return [
    for (final s in segs)
      {
        'start_s': s.startS,
        'end_s': s.endS,
        'spoken_at': s.spokenAt.toUtc().toIso8601String(),
        'text': s.text,
        'raw_text': s.rawText,
        'speaker': s.speaker,
      },
  ];
}

List<TranscriptSegment> decodeAltSegments(String json, {String? clipId}) {
  if (json.trim().isEmpty) {
    return [];
  }
  final raw = jsonDecode(json);
  if (raw is! List) {
    return [];
  }
  final out = <TranscriptSegment>[];
  for (final item in raw) {
    if (item is! Map) {
      continue;
    }
    final m = Map<String, dynamic>.from(item);
    final text = '${m['text'] ?? ''}'.trim();
    final spoken = DateTime.tryParse('${m['spoken_at'] ?? ''}');
    if (spoken == null) {
      continue;
    }
    out.add(
      TranscriptSegment(
        clipId: clipId,
        startS: (m['start_s'] as num?)?.toDouble() ?? 0,
        endS: (m['end_s'] as num?)?.toDouble() ?? 0,
        spokenAt: spoken,
        text: text,
        rawText: '${m['raw_text'] ?? text}',
        speaker: m['speaker'] as String?,
      ),
    );
  }
  return out;
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
    this.refineInputTokens = 0,
    this.refineOutputTokens = 0,
    this.refineCostUsd = 0,
    this.segments = const [],
    this.altFullText = '',
    this.altSttModel,
    this.altCostUsd = 0,
    this.altError = '',
    this.altSegments = const [],
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
  final int refineInputTokens;
  final int refineOutputTokens;
  final double refineCostUsd;
  final List<TranscriptSegment> segments;
  final String altFullText;
  final String? altSttModel;
  final double altCostUsd;
  final String altError;
  final List<TranscriptSegment> altSegments;

  bool get hasAltStt =>
      altFullText.trim().isNotEmpty || altSegments.isNotEmpty || altError.isNotEmpty;

  double get spendUsd => costUsd + refineCostUsd + altCostUsd;

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
    int? refineInputTokens,
    int? refineOutputTokens,
    double? refineCostUsd,
    String? altFullText,
    String? altSttModel,
    double? altCostUsd,
    String? altError,
    List<TranscriptSegment>? altSegments,
    bool clearAlt = false,
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
      refineInputTokens: refineInputTokens ?? this.refineInputTokens,
      refineOutputTokens: refineOutputTokens ?? this.refineOutputTokens,
      refineCostUsd: refineCostUsd ?? this.refineCostUsd,
      segments: segments ?? this.segments,
      altFullText: clearAlt ? '' : (altFullText ?? this.altFullText),
      altSttModel: clearAlt ? null : (altSttModel ?? this.altSttModel),
      altCostUsd: clearAlt ? 0 : (altCostUsd ?? this.altCostUsd),
      altError: clearAlt ? '' : (altError ?? this.altError),
      altSegments: clearAlt ? const [] : (altSegments ?? this.altSegments),
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
    if (clips.any((c) => c.status == 'transcribing' || c.status == 'refining')) {
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

  double get spendUsd =>
      clips.fold(0.0, (a, c) => a + c.spendUsd);
}

class SpokenNote {
  SpokenNote({
    required this.id,
    required this.createdAt,
    required this.text,
    this.clipId,
    this.meetingId,
  });

  final String id;
  final DateTime createdAt;
  final String text;
  final String? clipId;
  final String? meetingId;
}
