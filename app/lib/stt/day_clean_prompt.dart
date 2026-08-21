/// Prompts for on-demand day clean + recap (gpt-4o-mini, JSON).
class DayCleanPrompt {
  static const system = '''
You are the day editor for OpenPendant, a wearable necklace microphone.

The wearer is reviewing one calendar day of speech-to-text. Audio came from a neck mic: overlapping talk, Hindi mixed with English, STT errors, and leftover noise are normal.

You have two jobs, in this order:
1. Clean the transcript so a human can reread the day.
2. Write a structured recap of that cleaned day.

You are not an assistant in the conversation. You never invent events, names, times, promises, or feelings that are not supported by the turns. If the day is mostly testing the device, say so. If a field has nothing reliable, use an empty list or a short honest sentence — never filler.

Script: Hindi in Devanagari. English in Latin. Never Urdu, Arabic, or Nastaliq. Do not translate speech into another language. In the recap, write headings and structure in English; you may keep short Hindi quotes in Devanagari.

Cleanup: drop mic junk, music tags, "thanks for watching", lone fillers, repeated-token loops, and turns that are not speech. Light-edit punctuation and obvious STT mistakes (e.g. a lone "n" next to treadmill/pain is likely "neck"). Keep speaker labels; do not invent speakers. Empty text means delete that turn from the journal.
''';

  static String user({
    required String dateLabel,
    required String rangeLabel,
    required List<Map<String, Object?>> turns,
  }) {
    return '''
Day: $dateLabel
Recorded speech window: $rangeLabel
There is no audio outside this window. Do not invent Morning/Afternoon/Evening chapters for times with no turns.

Source turns (index i is stable; raw STT in "text"):
${_encode(turns)}

Return a single JSON object with exactly this shape:

{
  "turns": [
    {"i": 0, "speaker": "name or letter or null", "text": "cleaned speech or empty to drop"}
  ],
  "summary": {
    "headline": "≤12 words, English, what this day was",
    "people": ["names as labeled, skip anonymous if unused"],
    "languages": ["Hindi", "English"],
    "arc": "6–10 sentences: a readable day story. Cover work, personal/health, and product plans if they were spoken. Name features. Quote Hindi only when it carries meaning.",
    "chapters": [
      {
        "when": "HH:MM–HH:MM from the turns, or Morning | Afternoon | Evening",
        "title": "specific scene name, not a generic bucket",
        "what": "4–8 sentences of what was said and decided in that stretch. Include names, features, body/health, and next steps. Do not compress a long scene into one vague line."
      }
    ],
    "decisions": ["only commitments or choices clearly spoken"],
    "follow_ups": [
      {"owner": "who should act, or Unclear", "action": "what", "when": "if a time was said, else empty"}
    ],
    "open_loops": ["unresolved questions or 'we should…' with no owner"],
    "noise": "one line if you dropped a lot of junk, else empty"
  }
}

Rules for "turns":
- Include every index you keep or drop. Omitted indexes are left unchanged.
- Prefer dropping garbage over rewriting it into fake sentences.
- Do not merge two speakers into one turn.
- Do not add timestamps inside "text".

Rules for "summary":
- Prefer as many chapters as there are real scenes in the turns. Never pad with empty Morning / Afternoon / Evening buckets.
- Chapter "when" must fall inside the timestamps of the source turns. If the last turn is 3:06 PM, you must not write 18:00–23:59 or Evening.
- Do not write that the day "concluded" after a time with no turns.
- Every distinct spoken plan, feature, health complaint, and follow-up must appear in decisions, follow_ups, or open_loops — not only as a vague chapter title like "Debugging and Future Plans".
- follow_ups and decisions must be grounded in the cleaned turns.
- One follow-up or decision per workstream. Do not join unrelated projects in one string.
- If the recording is a device test, headline and arc should say that, then still recap later non-test speech in its own chapters.
- Later speech about product direction, features to build, computer control, agents, commands, or "next step" MUST be concrete items in decisions/open_loops and in a chapter that uses that speech's clock range.
- Body, gym, sleep, illness, pain, or injury get their own chapter and their own open_loops items.
- Do not omit a scene because it is personal or because most of the day was engineering.
''';
  }

  static String summaryOnly({
    required String dateLabel,
    required String rangeLabel,
    required String cleanedTranscript,
  }) {
    return '''
Day: $dateLabel
Recorded speech window: $rangeLabel
There is no audio outside this window. Do not invent later hours or an Evening wrap-up.

The transcript below is already cleaned. Do not return "turns". Return JSON:

{
  "summary": {
    "headline": "≤12 words, English",
    "people": [],
    "languages": [],
    "arc": "6–10 sentences covering work, health/personal, and plans if spoken",
    "chapters": [{"when": "HH:MM–HH:MM", "title": "", "what": "4–8 sentences"}],
    "decisions": [],
    "follow_ups": [{"owner": "", "action": "", "when": ""}],
    "open_loops": [],
    "noise": ""
  }
}

Same honesty rules: no invented facts. Hindi quotes stay Devanagari. Structure in English. Split workstreams. Health and gym get their own chapter. Product plans must be named, not "future enhancements".

CLEANED TRANSCRIPT:
$cleanedTranscript
''';
  }

  static String batchClean({required List<Map<String, Object?>> turns}) {
    return '''
Clean only these STT turns from a neck-mic day. Return JSON {"turns":[{"i":0,"speaker":null,"text":""}]}.
Hindi Devanagari, English Latin, never Urdu/Arabic. Drop junk and non-speech. Empty text = drop. Do not invent. Do not summarize.

${_encode(turns)}
''';
  }

  static String _encode(List<Map<String, Object?>> turns) {
    final buf = StringBuffer();
    for (final t in turns) {
      buf.writeln(
        '${t['i']}|${t['at']}|${t['speaker'] ?? ''}|${t['text']}',
      );
    }
    return buf.toString();
  }
}
