import 'package:googleapis/calendar/v3.dart';

import 'google_oauth.dart';
import 'note_command.dart';

class CalendarNoteResult {
  CalendarNoteResult({required this.ok, this.detail = ''});

  final bool ok;
  final String detail;
}

Future<CalendarNoteResult> addNoteToGoogleCalendar(String note) async {
  final body = note.trim();
  if (body.isEmpty) {
    return CalendarNoteResult(ok: false, detail: 'Empty note');
  }
  final client = await GoogleOAuthStore.authorizedClient();
  try {
    final start = DateTime.now().toUtc();
    final end = start.add(const Duration(minutes: 30));
    final created = await CalendarApi(client).events.insert(
      Event(
        summary: calendarEventTitle(body),
        description: '$body\n\n— OpenPendant',
        start: EventDateTime(dateTime: start, timeZone: 'UTC'),
        end: EventDateTime(dateTime: end, timeZone: 'UTC'),
      ),
      'primary',
    );
    final link = created.htmlLink?.trim() ?? '';
    return CalendarNoteResult(
      ok: true,
      detail: link.isEmpty ? 'Added to Google Calendar' : link,
    );
  } finally {
    client.close();
  }
}
