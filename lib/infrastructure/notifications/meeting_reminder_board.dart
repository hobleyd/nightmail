import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/settings/app_settings.dart';
import '../../domain/entities/calendar_event.dart';
import 'notification_service.dart';

/// One meeting in the meeting-reminders dialog, at the latest alert of its
/// countdown that has come due.
@immutable
class MeetingReminderRow {
  const MeetingReminderRow({
    required this.accountId,
    required this.eventId,
    required this.title,
    required this.start,
    required this.end,
    required this.minutesUntilStart,
    this.location,
  });

  final String accountId;
  final String eventId;
  final String title;
  final DateTime start;
  final DateTime end;

  /// The offset of the alert this row stands for — 15, 10, 5, 0 — not a live
  /// countdown. The row changes only when the next alert comes due.
  final int minutesUntilStart;
  final String? location;

  /// Identifies this *alert*, not the meeting: dismissing it hides the row
  /// until the next alert of the countdown, which is a different id. The start
  /// is part of it so a meeting moved after a dismissal announces itself again.
  String get id => '$meetingKey::$minutesUntilStart';

  /// Identifies the meeting at this start, whichever alert it is at — what a
  /// row's close button silences for the rest of the countdown.
  String get meetingKey =>
      '$accountId::$eventId::${start.millisecondsSinceEpoch}';

  String get label => NotificationService.countdownLabel(minutesUntilStart);

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'eventId': eventId,
        'title': title,
        'start': start.toUtc().toIso8601String(),
        'end': end.toUtc().toIso8601String(),
        'minutesUntilStart': minutesUntilStart,
        'location': ?location,
      };

  static MeetingReminderRow? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final start = DateTime.tryParse(raw['start'] as String? ?? '');
    final end = DateTime.tryParse(raw['end'] as String? ?? '');
    if (start == null || end == null) return null;
    return MeetingReminderRow(
      accountId: raw['accountId'] as String? ?? '',
      eventId: raw['eventId'] as String? ?? '',
      title: raw['title'] as String? ?? '',
      start: start,
      end: end,
      minutesUntilStart: (raw['minutesUntilStart'] as num?)?.toInt() ?? 0,
      location: raw['location'] as String?,
    );
  }

  static List<MeetingReminderRow> listFromJson(Object? raw) => [
        if (raw is List)
          for (final r in raw) ?fromJson(r),
      ];
}

/// What the dialog should show now, and whether it should come forward.
@immutable
class MeetingReminderUpdate {
  const MeetingReminderUpdate(this.rows, {required this.alert});

  final List<MeetingReminderRow> rows;

  /// A meeting reached a new alert of its countdown (or first came up) since
  /// the last update. Only this opens or fronts the dialog; a row leaving, or
  /// a dismissal, just updates whatever is already showing — so a user who
  /// closes the dialog is not nagged again until the next alert.
  final bool alert;
}

/// The main window's record of which meetings are due a reminder, behind the
/// single meeting-reminders dialog on every platform.
///
/// Driven from here rather than from OS delivery because only macOS has a
/// delivery hook: nothing on Windows, Linux, iOS or Android tells the app that
/// a scheduled notification just fired. [CalendarReminderService] hands over
/// every account's fetched events on each pass, and a wall-clock tick works out
/// which alert of each meeting's countdown is due — a `Timer` per alert would
/// run on monotonic time and arrive long after the meeting on a Mac that slept
/// through it. Computing the *latest* due alert is also what makes a newer one
/// replace an older one, and what keeps a wake from replaying 15 → 10 → 5.
///
/// A row lasts from its meeting's first alert until [startedGrace] after it
/// starts, or its end if that is sooner. All-day events are left out: they are
/// not meetings to be walked into, and an 18-hour lead with a countdown to
/// midnight would interrupt the night before.
class MeetingReminderBoard {
  MeetingReminderBoard({
    required this._settings,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AppSettings _settings;
  final DateTime Function() _clock;

  static const _tickInterval = Duration(seconds: 15);

  /// How long a meeting stays in the dialog once it has started. Its end would
  /// be the literal reading of "passed", but a day-long event would then hold a
  /// "Starting now" row all day, and every launch during it would announce it
  /// afresh.
  static const startedGrace = Duration(minutes: 10);

  final _events = <String, List<CalendarEvent>>{};
  final _dismissed = <String>{};
  final _silenced = <String>{};
  final _updates = StreamController<MeetingReminderUpdate>.broadcast();

  /// The alert each live meeting is at, by `account::event::start`, whether or
  /// not its row was dismissed — so an alert is announced once, however its row
  /// came and went.
  Map<String, int> _stages = const {};
  List<MeetingReminderRow> _rows = const [];
  bool _enabled = AppSettings.defaultShowMeetingReminders;
  Timer? _ticker;

  Stream<MeetingReminderUpdate> get updates => _updates.stream;
  List<MeetingReminderRow> get rows => _rows;

  /// Starts the wall-clock tick. Main window only: the background isolate also
  /// reconciles, and feeds this, but has nothing to show a dialog in.
  Future<void> start() async {
    _enabled = await _settings.loadShowMeetingReminders();
    _ticker ??= Timer.periodic(_tickInterval, (_) => recompute());
    recompute();
  }

  void stop() {
    _ticker?.cancel();
    _ticker = null;
  }

  /// Turning the setting off closes an open dialog; it does not touch the OS
  /// banners, which stay on.
  void setEnabled(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    recompute();
  }

  /// Replaces the events of every account in [fetched]. An account in [known]
  /// but missing from [fetched] failed to fetch, which is not evidence its
  /// meetings were cancelled, so its previous events stay; an account in
  /// neither has been removed.
  void update(
    Map<String, List<CalendarEvent>> fetched, {
    required Set<String> known,
  }) {
    _events.removeWhere((id, _) => !known.contains(id));
    final now = _clock().toUtc();
    for (final entry in fetched.entries) {
      // A fetch from "now" may leave out a meeting that has already started,
      // and its row is meant to last until it ends — so a started meeting the
      // last fetch knew about survives one that no longer lists it.
      final ids = {for (final e in entry.value) e.id};
      final started = [
        for (final e in _events[entry.key] ?? const <CalendarEvent>[])
          if (!ids.contains(e.id) && !e.start.isAfter(now) && _lastsPast(e, now))
            e,
      ];
      _events[entry.key] = [...entry.value, ...started];
    }
    recompute();
  }

  void removeAccount(String accountId) {
    if (_events.remove(accountId) != null) recompute();
  }

  /// Hides one alert's row until its meeting's next alert comes due.
  void dismiss(String rowId) {
    if (!_dismissed.add(rowId)) return;
    recompute();
  }

  /// Hides a meeting for the rest of its countdown: none of its later alerts
  /// show or front the dialog. Keyed by [MeetingReminderRow.meetingKey], so a
  /// meeting moved afterwards announces itself again.
  void silence(String meetingKey) {
    if (!_silenced.add(meetingKey)) return;
    recompute();
  }

  void recompute() {
    final now = _clock().toUtc();
    final stages = stagesAt(_events, now);
    var alert = false;
    for (final entry in stages.entries) {
      if (_silenced.contains(entry.key)) continue;
      final previous = _stages[entry.key];
      if (previous == null || entry.value < previous) {
        alert = true;
        break;
      }
    }
    _stages = stages;

    final all = rowsAt(_events, now);
    // An id that is no longer current never will be again — a countdown only
    // moves forward — so the set does not grow for the life of the process.
    _dismissed.retainAll({for (final r in all) r.id});
    _silenced.retainAll(stages.keys);
    final rows = _enabled
        ? [
            for (final r in all)
              if (!_dismissed.contains(r.id) &&
                  !_silenced.contains(r.meetingKey))
                r,
          ]
        : const <MeetingReminderRow>[];

    // A new alert whose row is dismissed or hidden is not worth fronting for.
    alert = alert && rows.isNotEmpty;
    final changed = !listEquals(
      [for (final r in rows) '${r.id}|${r.title}|${r.location}'],
      [for (final r in _rows) '${r.id}|${r.title}|${r.location}'],
    );
    _rows = rows;
    if (changed || alert) {
      _updates.add(MeetingReminderUpdate(rows, alert: alert));
    }
  }

  /// The alert each meeting with a reminder is at, at [now]: the smallest
  /// offset of its countdown that has come due, for as long as it has a row.
  @visibleForTesting
  static Map<String, int> stagesAt(
    Map<String, List<CalendarEvent>> events,
    DateTime now,
  ) =>
      {
        for (final r in rowsAt(events, now))
          r.meetingKey: r.minutesUntilStart,
      };

  /// Every meeting due a row at [now], soonest first, before dismissals.
  @visibleForTesting
  static List<MeetingReminderRow> rowsAt(
    Map<String, List<CalendarEvent>> events,
    DateTime now,
  ) {
    final rows = <MeetingReminderRow>[];
    for (final entry in events.entries) {
      for (final e in entry.value) {
        final reminderMinutes = e.reminderMinutes;
        if (reminderMinutes == null || e.isAllDay) continue;
        if (!_lastsPast(e, now)) continue;
        int? due;
        // Furthest from the start first, so the last one due is the latest.
        for (final offset in NotificationService.reminderOffsets(reminderMinutes)) {
          if (e.start.subtract(Duration(minutes: offset)).isAfter(now)) continue;
          due = offset;
        }
        if (due == null) continue;
        rows.add(MeetingReminderRow(
          accountId: entry.key,
          eventId: e.id,
          title: e.subject,
          start: e.start,
          end: e.end,
          minutesUntilStart: due,
          location: e.location,
        ));
      }
    }
    rows.sort((a, b) => a.start.compareTo(b.start));
    return rows;
  }

  /// Whether [e] still has a row at [now]: until [startedGrace] after its
  /// start, or its end if that is sooner.
  static bool _lastsPast(CalendarEvent e, DateTime now) {
    final graceEnd = e.start.add(startedGrace);
    final until = e.end.isBefore(graceEnd) ? e.end : graceEnd;
    return until.isAfter(now);
  }
}
