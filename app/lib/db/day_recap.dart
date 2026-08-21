class DayRecap {
  DayRecap({
    required this.dayKey,
    required this.headline,
    required this.arc,
    required this.people,
    required this.languages,
    required this.chapters,
    required this.decisions,
    required this.followUps,
    required this.openLoops,
    required this.noise,
    this.model,
    this.costUsd = 0,
    this.updatedAt,
  });

  final String dayKey;
  final String headline;
  final String arc;
  final List<String> people;
  final List<String> languages;
  final List<DayChapter> chapters;
  final List<String> decisions;
  final List<DayFollowUp> followUps;
  final List<String> openLoops;
  final String noise;
  final String? model;
  final double costUsd;
  final DateTime? updatedAt;

  factory DayRecap.fromJson({
    required String dayKey,
    required Map<String, dynamic> json,
    String? model,
    double costUsd = 0,
    DateTime? updatedAt,
  }) {
    final s = json['summary'] is Map
        ? Map<String, dynamic>.from(json['summary'] as Map)
        : json;
    List<String> strs(dynamic v) {
      if (v is! List) {
        return [];
      }
      return v.map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList();
    }

    final chapters = <DayChapter>[];
    final rawCh = s['chapters'];
    if (rawCh is List) {
      for (final item in rawCh) {
        if (item is Map) {
          final m = Map<String, dynamic>.from(item);
          final what = '${m['what'] ?? ''}'.trim();
          if (what.isEmpty) {
            continue;
          }
          chapters.add(
            DayChapter(
              when: '${m['when'] ?? ''}'.trim(),
              title: '${m['title'] ?? ''}'.trim(),
              what: what,
            ),
          );
        }
      }
    }
    final follow = <DayFollowUp>[];
    final rawF = s['follow_ups'];
    if (rawF is List) {
      for (final item in rawF) {
        if (item is Map) {
          final m = Map<String, dynamic>.from(item);
          final action = '${m['action'] ?? ''}'.trim();
          if (action.isEmpty) {
            continue;
          }
          follow.add(
            DayFollowUp(
              owner: '${m['owner'] ?? ''}'.trim(),
              action: action,
              when: '${m['when'] ?? ''}'.trim(),
            ),
          );
        }
      }
    }
    return DayRecap(
      dayKey: dayKey,
      headline: '${s['headline'] ?? ''}'.trim(),
      arc: '${s['arc'] ?? ''}'.trim(),
      people: strs(s['people']),
      languages: strs(s['languages']),
      chapters: chapters,
      decisions: strs(s['decisions']),
      followUps: follow,
      openLoops: strs(s['open_loops']),
      noise: '${s['noise'] ?? ''}'.trim(),
      model: model,
      costUsd: costUsd,
      updatedAt: updatedAt,
    );
  }

  DayRecap copyWith({List<DayChapter>? chapters}) {
    return DayRecap(
      dayKey: dayKey,
      headline: headline,
      arc: arc,
      people: people,
      languages: languages,
      chapters: chapters ?? this.chapters,
      decisions: decisions,
      followUps: followUps,
      openLoops: openLoops,
      noise: noise,
      model: model,
      costUsd: costUsd,
      updatedAt: updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'headline': headline,
        'arc': arc,
        'people': people,
        'languages': languages,
        'chapters': [
          for (final c in chapters)
            {'when': c.when, 'title': c.title, 'what': c.what},
        ],
        'decisions': decisions,
        'follow_ups': [
          for (final f in followUps)
            {'owner': f.owner, 'action': f.action, 'when': f.when},
        ],
        'open_loops': openLoops,
        'noise': noise,
      };
}

class DayChapter {
  DayChapter({
    required this.when,
    required this.title,
    required this.what,
  });

  final String when;
  final String title;
  final String what;
}

class DayFollowUp {
  DayFollowUp({
    required this.owner,
    required this.action,
    required this.when,
  });

  final String owner;
  final String action;
  final String when;
}

/// Keep chapters that overlap actual speech. Drops invented evening/night buckets.
DayRecap clipRecapToSpeech({
  required DayRecap recap,
  required DateTime firstSpoken,
  required DateTime lastSpoken,
}) {
  final first = firstSpoken.toLocal();
  final last = lastSpoken.toLocal();
  final firstMin = first.hour * 60 + first.minute;
  final lastMin = last.hour * 60 + last.minute;
  final chapters = recap.chapters
      .where((c) => chapterCoversSpeech(c.when, firstMin, lastMin))
      .toList();
  return recap.copyWith(chapters: chapters);
}

bool chapterCoversSpeech(String when, int firstMin, int lastMin) {
  final range = parseChapterClockRange(when);
  if (range != null) {
    return range.$1 <= lastMin && range.$2 >= firstMin;
  }
  final w = when.toLowerCase();
  if (w.contains('night') || w.contains('evening')) {
    return lastMin >= 17 * 60;
  }
  if (w.contains('afternoon') || w.contains('midday')) {
    return lastMin >= 12 * 60 && firstMin < 18 * 60;
  }
  if (w.contains('morning')) {
    return firstMin < 12 * 60;
  }
  return true;
}

/// Parses `18:00–23:59`, `18:00-23:59`, or `3:02 PM–3:06 PM`.
(int, int)? parseChapterClockRange(String when) {
  final m = RegExp(
    r'(\d{1,2}):(\d{2})\s*(am|pm)?\s*[–\-]\s*(\d{1,2}):(\d{2})\s*(am|pm)?',
    caseSensitive: false,
  ).firstMatch(when);
  if (m == null) {
    return null;
  }
  var h1 = int.parse(m.group(1)!);
  final min1 = int.parse(m.group(2)!);
  var h2 = int.parse(m.group(4)!);
  final min2 = int.parse(m.group(5)!);
  final ap1 = m.group(3)?.toLowerCase();
  final ap2 = m.group(6)?.toLowerCase();
  if (ap1 != null) {
    h1 = _to24(h1, ap1);
  }
  if (ap2 != null) {
    h2 = _to24(h2, ap2);
  }
  return (h1 * 60 + min1, h2 * 60 + min2);
}

int _to24(int hour, String ampm) {
  var h = hour % 12;
  if (ampm == 'pm') {
    h += 12;
  }
  return h;
}
