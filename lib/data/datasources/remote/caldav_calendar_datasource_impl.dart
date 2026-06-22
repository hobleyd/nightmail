import 'package:caldav/caldav.dart' as caldav;
import 'package:uuid/uuid.dart';

import '../../../core/error/exceptions.dart';
import '../../../domain/entities/attendee_availability.dart';
import '../../../domain/entities/calendar_recurrence.dart';
import '../../../domain/entities/meeting_invite.dart';
import '../../../domain/usecases/create_calendar_event.dart';
import '../../../domain/usecases/update_calendar_event.dart';
import '../../models/calendar_event_model.dart';
import 'calendar_remote_datasource.dart';

class CalDavCalendarDatasourceImpl implements CalendarRemoteDatasource {
  CalDavCalendarDatasourceImpl({
    required this._serverUrl,
    required this._username,
    required this._passwordProvider,
  });

  final String _serverUrl;
  final String _username;
  final Future<String?> Function() _passwordProvider;

  caldav.CalDavClient? _client;
  List<caldav.Calendar>? _calendars;

  // Cache events by uid so update/delete can reference the original object with href.
  final Map<String, caldav.CalendarEvent> _eventCache = {};

  Future<caldav.CalDavClient> _getClient() async {
    if (_client != null) return _client!;
    final password = await _passwordProvider();
    if (password == null || password.isEmpty) {
      throw const ServerException(message: 'No CalDAV password configured');
    }
    try {
      _client = await caldav.CalDavClient.connect(
        baseUrl: _serverUrl,
        username: _username,
        password: password,
      );
      return _client!;
    } on caldav.AuthenticationException {
      throw const AuthException(message: 'CalDAV authentication failed');
    } on caldav.DiscoveryException catch (e) {
      throw ServerException(message: 'CalDAV discovery failed: $e');
    }
  }

  Future<List<caldav.Calendar>> _getCalendars() async {
    if (_calendars != null) return _calendars!;
    final client = await _getClient();
    _calendars = await client.getCalendars();
    return _calendars!;
  }

  caldav.Calendar? _writableCalendar(List<caldav.Calendar> calendars) =>
      calendars.where((c) => !c.isReadOnly).firstOrNull;

  @override
  Future<List<CalendarEventModel>> getCalendarEvents({
    required DateTime startDateTime,
    required DateTime endDateTime,
  }) async {
    try {
      final client = await _getClient();
      final calendars = await _getCalendars();

      _eventCache.clear();
      final result = <CalendarEventModel>[];

      for (final cal in calendars) {
        try {
          final events = await client.getEvents(
            cal,
            start: startDateTime.toUtc(),
            end: endDateTime.toUtc(),
          );
          for (final event in events) {
            _eventCache[event.uid] = event;
            result.add(_toModel(event));
          }
        } catch (_) {
          // Skip individual calendar failures
        }
      }
      return result;
    } on AuthException {
      rethrow;
    } on caldav.AuthenticationException {
      throw const AuthException(message: 'CalDAV authentication failed');
    } catch (e) {
      throw ServerException(message: e.toString());
    }
  }

  @override
  Future<CalendarEventModel> createCalendarEvent({
    required CreateCalendarEventParams params,
  }) async {
    try {
      final client = await _getClient();
      final calendars = await _getCalendars();
      final cal = _writableCalendar(calendars);
      if (cal == null) {
        throw const ServerException(message: 'No writable CalDAV calendar found');
      }

      const uuid = Uuid();
      final event = caldav.CalendarEvent(
        uid: uuid.v4(),
        calendarId: cal.uid,
        start: params.start.toUtc(),
        end: params.end.toUtc(),
        summary: params.subject,
        description: params.description,
        location: params.location,
        isAllDay: params.isAllDay,
        rrule: params.recurrence != null ? _buildRRule(params.recurrence!) : null,
      );

      final created = await client.createEvent(cal, event);
      _eventCache[created.uid] = created;
      return _toModel(created);
    } on AuthException {
      rethrow;
    } on caldav.AuthenticationException {
      throw const AuthException(message: 'CalDAV authentication failed');
    } catch (e) {
      throw ServerException(message: e.toString());
    }
  }

  @override
  Future<CalendarEventModel> updateCalendarEvent({
    required UpdateCalendarEventParams params,
  }) async {
    try {
      final client = await _getClient();
      final cached = _eventCache[params.id];
      if (cached == null) {
        throw ServerException(message: 'Event not found in cache: ${params.id}');
      }

      final updated = cached.copyWith(
        summary: params.subject,
        start: params.start.toUtc(),
        end: params.end.toUtc(),
        description: params.description,
        location: params.location,
        isAllDay: params.isAllDay,
        rrule: params.recurrence != null ? _buildRRule(params.recurrence!) : null,
      );

      final result = await client.updateEvent(updated);
      _eventCache[result.uid] = result;
      return _toModel(result);
    } on AuthException {
      rethrow;
    } on caldav.AuthenticationException {
      throw const AuthException(message: 'CalDAV authentication failed');
    } catch (e) {
      throw ServerException(message: e.toString());
    }
  }

  @override
  Future<void> respondToMeetingInvite({
    required String emailId,
    required MeetingInviteResponseType response,
    String? icsData,
    DateTime? meetingStart,
    String? userEmail,
  }) async {
    if (response == MeetingInviteResponseType.decline) return;
    if (icsData == null) return;

    final icsEvent = _parseIcs(icsData);
    try {
      await createCalendarEvent(
        params: CreateCalendarEventParams(
          subject: icsEvent.summary,
          start: icsEvent.start,
          end: icsEvent.end,
          isAllDay: icsEvent.isAllDay,
          timezone: 'UTC',
          location: icsEvent.location,
        ),
      );
    } catch (_) {
      // Best-effort — meeting invite response sends the email reply separately
    }
  }

  @override
  Future<void> removeMeetingFromCalendar({
    required String emailId,
    String? icsData,
    DateTime? meetingStart,
  }) async {
    if (icsData == null) return; // Best-effort — no ICS, nothing to remove.
    final icsEvent = _parseIcs(icsData);
    final uid = icsEvent.uid;
    if (uid == null) return;

    // Check the in-memory cache first (populated during the last calendar load).
    if (_eventCache.containsKey(uid)) {
      await cancelCalendarEvent(eventId: uid);
      return;
    }

    // Cache miss: fetch events around the meeting start to find the event.
    final refTime = meetingStart ?? icsEvent.start;
    try {
      final client = await _getClient();
      final calendars = await _getCalendars();
      for (final cal in calendars) {
        try {
          final events = await client.getEvents(
            cal,
            start: refTime.subtract(const Duration(hours: 1)),
            end: refTime.add(const Duration(hours: 4)),
          );
          for (final e in events) {
            _eventCache[e.uid] = e;
          }
        } catch (_) {}
      }
    } catch (_) {}

    if (_eventCache.containsKey(uid)) {
      await cancelCalendarEvent(eventId: uid);
    }
    // Event not found — it may have already been removed.
  }

  @override
  Future<void> cancelMeetingFromEmail({
    required String emailId,
    DateTime? meetingStart,
  }) async {
    throw const ServerException(
        message: 'Cancel from decline notification is not supported for CalDAV');
  }

  @override
  Future<void> cancelCalendarEvent({required String eventId}) async {
    try {
      final client = await _getClient();
      final event = _eventCache[eventId];
      if (event == null) return;
      await client.deleteEvent(event);
      _eventCache.remove(eventId);
    } on AuthException {
      rethrow;
    } on caldav.AuthenticationException {
      throw const AuthException(message: 'CalDAV authentication failed');
    } catch (e) {
      throw ServerException(message: e.toString());
    }
  }

  @override
  Future<void> declineCalendarEvent({
    required String eventId,
    String? userEmail,
  }) async {
    await cancelCalendarEvent(eventId: eventId);
  }

  @override
  Future<void> proposeNewTime({
    required String eventId,
    required DateTime newStart,
    required DateTime newEnd,
    String? timezone,
    String? userEmail,
    String? message,
  }) async {
    // CalDAV has no propose-new-time mechanism; remove from local calendar.
    await cancelCalendarEvent(eventId: eventId);
  }

  @override
  Future<List<AttendeeAvailability>> getAttendeesSchedule({
    required List<String> emails,
    required DateTime start,
    required DateTime end,
  }) async {
    // CalDAV free/busy requires CalDAV scheduling extensions (RFC 6638) which
    // are not universally supported; return unknown.
    return emails
        .map((e) => AttendeeAvailability(
              email: e,
              status: AttendeeAvailabilityStatus.unknown,
            ))
        .toList();
  }

  // ─── Helpers ────────────────────────────────────────────────────────────────

  CalendarEventModel _toModel(caldav.CalendarEvent e) {
    return CalendarEventModel(
      id: e.uid,
      subject: e.summary,
      start: e.start,
      end: e.end ?? e.start.add(const Duration(hours: 1)),
      isAllDay: e.isAllDay,
      location: e.location,
      bodyPreview: e.description,
      isOrganizer: true,
    );
  }

  String _buildRRule(CalendarRecurrence r) {
    final freq = switch (r.frequency) {
      RecurrenceFrequency.daily => 'DAILY',
      RecurrenceFrequency.weekly => 'WEEKLY',
      RecurrenceFrequency.monthly => 'MONTHLY',
      RecurrenceFrequency.yearly => 'YEARLY',
    };
    var rule = 'FREQ=$freq';
    if (r.interval > 1) rule += ';INTERVAL=${r.interval}';

    if (r.frequency == RecurrenceFrequency.weekly &&
        r.daysOfWeek != null &&
        r.daysOfWeek!.isNotEmpty) {
      const dayNames = ['', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
      final days = r.daysOfWeek!.map((d) => dayNames[d]).join(',');
      rule += ';BYDAY=$days';
    }

    if (r.endDate != null) {
      final utc = r.endDate!.toUtc();
      final y = utc.year.toString().padLeft(4, '0');
      final m = utc.month.toString().padLeft(2, '0');
      final d = utc.day.toString().padLeft(2, '0');
      rule += ';UNTIL=$y$m${d}T000000Z';
    } else if (r.count != null) {
      rule += ';COUNT=${r.count!}';
    }

    return rule;
  }

  _IcsEvent _parseIcs(String icsData) {
    final unfolded = icsData.replaceAll(RegExp(r'\r?\n[ \t]'), '');

    String? summary;
    String? uid;
    DateTime? start;
    DateTime? end;
    bool isAllDay = false;
    String? location;
    final attendees = <String>[];

    bool inVEvent = false;
    for (final rawLine in unfolded.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.toUpperCase() == 'BEGIN:VEVENT') { inVEvent = true; continue; }
      if (line.toUpperCase() == 'END:VEVENT') break;
      if (!inVEvent) continue;

      final colonIdx = line.indexOf(':');
      if (colonIdx == -1) continue;

      final namePart = line.substring(0, colonIdx).toUpperCase();
      final value = line.substring(colonIdx + 1);

      if (namePart == 'SUMMARY') {
        summary = value;
      } else if (namePart == 'UID') {
        uid = value;
      } else if (namePart.startsWith('DTSTART')) {
        final (dt, allDay) = _parseIcsDateTime(namePart, value);
        if (dt != null) { start = dt; isAllDay = allDay; }
      } else if (namePart.startsWith('DTEND')) {
        final (dt, _) = _parseIcsDateTime(namePart, value);
        if (dt != null) end = dt;
      } else if (namePart == 'LOCATION') {
        location = value.isNotEmpty ? value : null;
      } else if (namePart.startsWith('ATTENDEE')) {
        final mailto = value.toLowerCase().startsWith('mailto:')
            ? value.substring('mailto:'.length)
            : value;
        if (mailto.contains('@')) attendees.add(mailto);
      }
    }

    return _IcsEvent(
      summary: summary ?? '(No title)',
      uid: uid,
      start: start ?? DateTime.now().toUtc(),
      end: end ?? (start ?? DateTime.now().toUtc()).add(const Duration(hours: 1)),
      isAllDay: isAllDay,
      location: location,
      attendees: attendees,
    );
  }

  (DateTime?, bool) _parseIcsDateTime(String namePart, String value) {
    final isDate = namePart.contains('VALUE=DATE') && !namePart.contains('DATE-TIME');
    if (isDate) {
      if (value.length >= 8) {
        final y = int.tryParse(value.substring(0, 4));
        final m = int.tryParse(value.substring(4, 6));
        final d = int.tryParse(value.substring(6, 8));
        if (y != null && m != null && d != null) {
          return (DateTime.utc(y, m, d), true);
        }
      }
      return (null, true);
    }

    final isUtc = value.endsWith('Z');
    final digits = value.replaceAll(RegExp(r'[TZ]'), '');
    if (digits.length >= 14) {
      final y = int.tryParse(digits.substring(0, 4));
      final mo = int.tryParse(digits.substring(4, 6));
      final d = int.tryParse(digits.substring(6, 8));
      final h = int.tryParse(digits.substring(8, 10));
      final mi = int.tryParse(digits.substring(10, 12));
      final s = int.tryParse(digits.substring(12, 14));
      if (y != null && mo != null && d != null && h != null && mi != null && s != null) {
        final dt = isUtc
            ? DateTime.utc(y, mo, d, h, mi, s)
            : DateTime(y, mo, d, h, mi, s).toUtc();
        return (dt, false);
      }
    }
    return (null, false);
  }
}

class _IcsEvent {
  const _IcsEvent({
    required this.summary,
    required this.start,
    required this.end,
    required this.isAllDay,
    this.uid,
    this.location,
    this.attendees = const [],
  });

  final String summary;
  final String? uid;
  final DateTime start;
  final DateTime end;
  final bool isAllDay;
  final String? location;
  final List<String> attendees;
}
