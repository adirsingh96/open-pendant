class MemoryChatTurn {
  MemoryChatTurn({
    required this.id,
    required this.askedAt,
    required this.question,
    this.answer,
    this.error,
    this.dayKeys = const [],
  });

  final String id;
  final DateTime askedAt;
  final String question;
  String? answer;
  String? error;
  List<String> dayKeys;
}
