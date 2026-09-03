import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../db/clip_store.dart';
import '../db/models.dart';
import 'reminder_parse.dart';

/// Local reminders for spoken notes.
///
/// Timed notes fire 15 minutes before (or 5, or at due). Untimed and overdue
/// notes go into the next 8 AM digest until they are checked off.
class NoteReminders {
  NoteReminders._();

  static const digestId = 1;
  static const _channelId = 'note_reminders';
  static const _channelName = 'Note reminders';

  static final _plugin = FlutterLocalNotificationsPlugin();
  static var _ready = false;

  static Future<void> init() async {
    if (_ready) {
      return;
    }
    try {
      tzdata.initializeTimeZones();
      try {
        final info = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(info.identifier));
      } catch (_) {}
      const darwin = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_notification'),
          iOS: darwin,
          macOS: darwin,
        ),
      );
      _ready = true;
    } catch (e) {
      debugPrint('NoteReminders.init: $e');
    }
  }

  static Future<void> syncAll(ClipStore store) async {
    await init();
    if (!_ready) {
      return;
    }
    try {
      await _backfillDue(store);
      final pending = await store.listPendingNotes();
      await _plugin.cancelAll();
      if (pending.isEmpty) {
        return;
      }
      await _ensurePermission();
      final now = DateTime.now();
      final timed = pending.where((n) {
        final due = n.dueAt;
        return due != null && due.isAfter(now);
      }).toList()
        ..sort((a, b) => a.dueAt!.compareTo(b.dueAt!));
      for (final n in timed.take(40)) {
        await _scheduleTimed(n, now);
      }
      final digestNotes = pending.where((n) {
        final due = n.dueAt;
        return due == null || !due.isAfter(now);
      }).toList();
      if (digestNotes.isNotEmpty) {
        await _scheduleDigest(digestNotes, now);
      }
    } catch (e) {
      debugPrint('NoteReminders.syncAll: $e');
    }
  }

  static int idForNote(String noteId) {
    var id = noteId.hashCode & 0x7fffffff;
    if (id < 10) {
      id += 10;
    }
    return id;
  }

  static Future<void> _backfillDue(ClipStore store) async {
    final pending = await store.listPendingNotes();
    for (final n in pending) {
      if (n.dueAt != null) {
        continue;
      }
      final due = parseNoteReminder(n.text, now: n.createdAt.toLocal()).dueAt;
      if (due != null) {
        await store.updateNoteDueAt(n.id, due);
      }
    }
  }

  static Future<void> _ensurePermission() async {
    if (Platform.isIOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } else if (Platform.isMacOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } else if (Platform.isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
      await android?.requestExactAlarmsPermission();
    }
  }

  static NotificationDetails get _details {
    const android = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Reminders for spoken notes',
      importance: Importance.max,
      priority: Priority.high,
      icon: 'ic_notification',
    );
    const darwin = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    return const NotificationDetails(
      android: android,
      iOS: darwin,
      macOS: darwin,
    );
  }

  static tz.TZDateTime _when(DateTime local) {
    return tz.TZDateTime.from(local, tz.local);
  }

  static Future<void> _zoned({
    required int id,
    required String title,
    required String body,
    required DateTime at,
  }) async {
    if (!at.isAfter(DateTime.now().add(const Duration(seconds: 5)))) {
      return;
    }
    Future<void> run(AndroidScheduleMode mode) {
      return _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: _when(at),
        notificationDetails: _details,
        androidScheduleMode: mode,
      );
    }

    try {
      await run(AndroidScheduleMode.exactAllowWhileIdle);
    } catch (_) {
      await run(AndroidScheduleMode.inexactAllowWhileIdle);
    }
  }

  static Future<void> _scheduleTimed(SpokenNote note, DateTime now) async {
    final due = note.dueAt;
    if (due == null) {
      return;
    }
    final fire = reminderFireAt(due: due, now: now);
    if (fire == null) {
      return;
    }
    final title = reminderLabel(note.text);
    await _zoned(
      id: idForNote(note.id),
      title: 'Reminder',
      body: title,
      at: fire,
    );
  }

  static Future<void> _scheduleDigest(
    List<SpokenNote> notes,
    DateTime now,
  ) async {
    final titles = [
      for (final n in notes) reminderLabel(n.text),
    ].where((t) => t.isNotEmpty).toList();
    if (titles.isEmpty) {
      return;
    }
    const max = 4;
    final shown = titles.take(max).toList();
    final extra = titles.length - shown.length;
    final body = [
      ...shown.map((t) => '• $t'),
      if (extra > 0) '• and $extra more',
    ].join('\n');
    final heading =
        titles.length == 1 ? 'Still open' : '${titles.length} notes still open';
    await _zoned(
      id: digestId,
      title: heading,
      body: body,
      at: nextDigestAt(now),
    );
  }
}
