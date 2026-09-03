/// What the user asked to be reminded of, and when (local clock).
class ParsedNoteReminder {
  const ParsedNoteReminder({required this.title, this.dueAt});

  final String title;
  final DateTime? dueAt;
}

const reminderLead = Duration(minutes: 15);
const reminderLeadShort = Duration(minutes: 5);

final _clock = RegExp(
  r"(?:\b(?:at|by|around|@)\s*)?"
  r"(?:"
  r"(?<clock>noon|midnight)|"
  r"(?<hour>\d{1,2})(?:\s*[:.]\s*(?<min>\d{2}))?"
  r"(?:\s*(?<mer>a\.?\s*m\.?|p\.?\s*m\.?))?"
  r"(?:\s*o['’]?\s*clock)?"
  r")"
  r"\b",
  caseSensitive: false,
);

final _day = RegExp(
  r'\b(today|tonight|tomorrow|this\s+(?:morning|afternoon|evening))\b',
  caseSensitive: false,
);

final _remindPrefix = RegExp(
  r'^(?:(?:hey|hi|okay|ok|please)\s+)*'
  r'(?:remind\s+me\s+(?:to\s+|that\s+i\s+(?:need\s+to\s+|have\s+to\s+|should\s+)?)?)?',
  caseSensitive: false,
);

String reminderLabel(String text) {
  final parsed = parseNoteReminder(text);
  final title = parsed.title.trim();
  return title.isEmpty ? text.trim() : title;
}

/// Pull a local due time out of a spoken note. No clock → [dueAt] is null
/// (those go to the next-morning pending digest).
ParsedNoteReminder parseNoteReminder(String text, {DateTime? now}) {
  final clockNow = now ?? DateTime.now();
  var raw = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (raw.isEmpty) {
    return const ParsedNoteReminder(title: '');
  }

  final dayMatch = _day.firstMatch(raw);
  final clockMatch = _bestClock(raw);
  final due = _dueAt(
    now: clockNow,
    dayWord: dayMatch?.group(1),
    clock: clockMatch,
  );
  var title = raw;
  final spans = <List<int>>[
    if (clockMatch != null) [clockMatch.start, clockMatch.end],
    if (dayMatch != null) [dayMatch.start, dayMatch.end],
  ]..sort((a, b) => b[0].compareTo(a[0]));
  for (final s in spans) {
    title = title.replaceRange(s[0], s[1], ' ');
  }
  title = title.replaceAll(_remindPrefix, '');
  title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
  title = title.replaceAll(RegExp(r'^[\s,.:;\-]+|[\s,.:;\-]+$'), '');
  if (title.isEmpty) {
    title = raw;
  }
  if (title.isNotEmpty) {
    title = '${title[0].toUpperCase()}${title.substring(1)}';
  }
  return ParsedNoteReminder(title: title, dueAt: due);
}

/// When the notification should fire. 15 minutes before the due time, or
/// 5 minutes if that would already have passed, or at due if even that is late.
DateTime? reminderFireAt({required DateTime due, required DateTime now}) {
  final floor = now.add(const Duration(seconds: 20));
  final long = due.subtract(reminderLead);
  if (long.isAfter(floor)) {
    return long;
  }
  final short = due.subtract(reminderLeadShort);
  if (short.isAfter(floor)) {
    return short;
  }
  if (due.isAfter(floor)) {
    return due;
  }
  return null;
}

DateTime nextDigestAt(DateTime now, {int hour = 8}) {
  var at = DateTime(now.year, now.month, now.day, hour);
  if (!at.isAfter(now)) {
    at = at.add(const Duration(days: 1));
  }
  return at;
}

RegExpMatch? _bestClock(String raw) {
  RegExpMatch? best;
  var bestScore = -1;
  for (final m in _clock.allMatches(raw)) {
    if (!_clockOk(m, raw)) {
      continue;
    }
    final mer = m.namedGroup('mer');
    final word = m.namedGroup('clock');
    var score = 1;
    if (word != null && word.isNotEmpty) {
      score = 3;
    } else if (mer != null && mer.isNotEmpty) {
      score = 2;
    }
    if (score > bestScore) {
      best = m;
      bestScore = score;
    }
  }
  return best;
}

bool _clockOk(RegExpMatch m, String raw) {
  final word = m.namedGroup('clock') ?? '';
  if (word.isNotEmpty) {
    return true;
  }
  final mer = m.namedGroup('mer') ?? '';
  if (mer.isNotEmpty) {
    return true;
  }
  final g = (m.group(0) ?? '').trim();
  if (RegExp(r"o['’]?\s*clock", caseSensitive: false).hasMatch(g)) {
    return true;
  }
  if (RegExp(r'^(?:at|by|around|@)\b', caseSensitive: false).hasMatch(g)) {
    return true;
  }
  final before = raw.substring(0, m.start).toLowerCase();
  return RegExp(r'(?:at|by|around|@)\s*$').hasMatch(before);
}

DateTime? _dueAt({
  required DateTime now,
  required String? dayWord,
  required RegExpMatch? clock,
}) {
  final day = (dayWord ?? '').toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  var date = DateTime(now.year, now.month, now.day);
  var forced = false;
  if (day == 'tomorrow') {
    date = date.add(const Duration(days: 1));
    forced = true;
  } else if (day == 'tonight' || day == 'this evening') {
    forced = true;
  } else if (day == 'this morning' || day == 'this afternoon') {
    forced = true;
  } else if (day == 'today') {
    forced = true;
  }

  int? hour;
  var minute = 0;
  if (clock != null) {
    final named = (clock.namedGroup('clock') ?? '').toLowerCase();
    if (named == 'noon') {
      hour = 12;
    } else if (named == 'midnight') {
      hour = 0;
      if (!forced) {
        if (now.hour == 0 && now.minute < 1) {
          date = DateTime(now.year, now.month, now.day);
        } else {
          date = DateTime(now.year, now.month, now.day).add(
            const Duration(days: 1),
          );
        }
        forced = true;
      }
    } else {
      hour = int.tryParse(clock.namedGroup('hour') ?? '');
      minute = int.tryParse(clock.namedGroup('min') ?? '') ?? 0;
    }
  }

  if (hour == null) {
    if (day == 'tonight' || day == 'this evening') {
      hour = 20;
    } else if (day == 'this morning') {
      hour = 9;
    } else if (day == 'this afternoon') {
      hour = 15;
    } else if (day == 'tomorrow') {
      return null;
    } else {
      return null;
    }
  }

  if (hour > 24 || minute > 59) {
    return null;
  }

  final mer = (clock?.namedGroup('mer') ?? '')
      .toLowerCase()
      .replaceAll('.', '')
      .replaceAll(' ', '');
  if (mer.startsWith('p') && hour < 12) {
    hour += 12;
  } else if (mer.startsWith('a') && hour == 12) {
    hour = 0;
  } else if (mer.isEmpty &&
      hour >= 1 &&
      hour <= 12 &&
      clock?.namedGroup('clock') == null) {
    final am = DateTime(date.year, date.month, date.day, hour, minute);
    final pm = DateTime(
        date.year, date.month, date.day, hour == 12 ? 12 : hour + 12, minute);
    if (!forced) {
      if (am.isAfter(now.add(const Duration(seconds: 30)))) {
        hour = am.hour;
      } else if (pm.isAfter(now.add(const Duration(seconds: 30))) &&
          hour != 12) {
        hour = pm.hour;
      } else {
        date = date.add(const Duration(days: 1));
      }
    }
  }

  if (hour == 24) {
    hour = 0;
    date = date.add(const Duration(days: 1));
  }

  var due = DateTime(date.year, date.month, date.day, hour, minute);
  if (!forced && !due.isAfter(now.add(const Duration(seconds: 30)))) {
    due = due.add(const Duration(days: 1));
  }
  if (forced &&
      !due.isAfter(now.add(const Duration(seconds: 30))) &&
      day != 'tomorrow') {
    if (day == 'tonight' || day == 'this evening') {
      due = due.add(const Duration(days: 1));
    } else if (day == 'today' ||
        day == 'this morning' ||
        day == 'this afternoon') {
      due = due.add(const Duration(days: 1));
    }
  }
  return due;
}
