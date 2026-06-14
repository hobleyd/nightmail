import 'package:flutter/services.dart';

import '../../../core/error/exceptions.dart';
import '../../../domain/entities/attendee_availability.dart';
import '../../../domain/entities/meeting_invite.dart';
import '../../../domain/usecases/create_calendar_event.dart';
import '../../../domain/usecases/update_calendar_event.dart';
import '../../models/calendar_event_model.dart';
import 'calendar_remote_datasource.dart';

class EventKitCalendarDatasourceImpl implements CalendarRemoteDatasource {
  static const _channel =
      MethodChannel('au.com.sharpblue.nightmail/eventkit');

  Future<void> _ensurePermission() async {
    final status =
        await _channel.invokeMethod<String>('requestPermission');
    if (status != 'granted') {
      throw const ServerException(message: 'Calendar access not granted');
    }
  }

  @override
  Future<List<CalendarEventModel>> getCalendarEvents({
    required DateTime startDateTime,
    required DateTime endDateTime,
  }) async {
    try {
      await _ensurePermission();
      final raw = await _channel.invokeMethod<List<dynamic>>('getEvents', {
        'startMs': startDateTime.millisecondsSinceEpoch,
        'endMs': endDateTime.millisecondsSinceEpoch,
      });
      if (raw == null) return [];
      return raw
          .cast<Map<dynamic, dynamic>>()
          .map(_parseEvent)
          .toList();
    } on PlatformException catch (e) {
      throw ServerException(message: e.message ?? 'EventKit error');
    }
  }

  @override
  Future<CalendarEventModel> createCalendarEvent({
    required CreateCalendarEventParams params,
  }) async {
    try {
      final result =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('createEvent', {
        'title': params.subject,
        'startMs': params.start.millisecondsSinceEpoch,
        'endMs': params.end.millisecondsSinceEpoch,
        'isAllDay': params.isAllDay,
        if (params.location != null) 'location': params.location,
        if (params.description != null) 'notes': params.description,
      });
      if (result == null) {
        throw const ServerException(message: 'No result from EventKit');
      }
      return _parseEvent(result);
    } on PlatformException catch (e) {
      throw ServerException(message: e.message ?? 'EventKit error');
    }
  }

  @override
  Future<CalendarEventModel> updateCalendarEvent({
    required UpdateCalendarEventParams params,
  }) async {
    try {
      final result =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('updateEvent', {
        'id': params.id,
        'title': params.subject,
        'startMs': params.start.millisecondsSinceEpoch,
        'endMs': params.end.millisecondsSinceEpoch,
        'isAllDay': params.isAllDay,
        if (params.location != null) 'location': params.location,
        if (params.description != null) 'notes': params.description,
      });
      if (result == null) {
        throw const ServerException(message: 'No result from EventKit');
      }
      return _parseEvent(result);
    } on PlatformException catch (e) {
      throw ServerException(message: e.message ?? 'EventKit error');
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

    final event = _parseIcs(icsData);
    try {
      await _channel.invokeMethod<void>('createEvent', {
        'title': event.summary,
        'startMs': event.start.millisecondsSinceEpoch,
        'endMs': event.end.millisecondsSinceEpoch,
        'isAllDay': event.isAllDay,
        if (event.location != null) 'location': event.location,
      });
    } on PlatformException {
      // Best-effort
    }
  }

  @override
  Future<void> cancelCalendarEvent({required String eventId}) async {
    try {
      await _channel.invokeMethod<void>('deleteEvent', {'id': eventId});
    } on PlatformException catch (e) {
      throw ServerException(message: e.message ?? 'EventKit error');
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
    await cancelCalendarEvent(eventId: eventId);
  }

  @override
  Future<List<AttendeeAvailability>> getAttendeesSchedule({
    required List<String> emails,
    required DateTime start,
    required DateTime end,
  }) async {
    // EventKit does not expose organisation free/busy data; return unknown.
    return emails
        .map((e) => AttendeeAvailability(
              email: e,
              status: AttendeeAvailabilityStatus.unknown,
            ))
        .toList();
  }

  // ─── Helpers ────────────────────────────────────────────────────────────────

  CalendarEventModel _parseEvent(Map<dynamic, dynamic> map) {
    final startMs = map['startMs'] as int? ?? 0;
    final endMs = map['endMs'] as int? ?? 0;
    return CalendarEventModel(
      id: map['id'] as String? ?? '',
      subject: map['title'] as String? ?? '(No title)',
      start: DateTime.fromMillisecondsSinceEpoch(startMs, isUtc: true),
      end: DateTime.fromMillisecondsSinceEpoch(endMs, isUtc: true),
      isAllDay: map['isAllDay'] as bool? ?? false,
      location: map['location'] as String?,
      bodyPreview: map['notes'] as String?,
      isOrganizer: true,
    );
  }

  _IcsEvent _parseIcs(String icsData) {
    final unfolded = icsData.replaceAll(RegExp(r'\r?\n[ \t]'), '');

    String? summary;
    DateTime? start;
    DateTime? end;
    bool isAllDay = false;
    String? location;

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
      } else if (namePart.startsWith('DTSTART')) {
        final (dt, allDay) = _parseIcsDateTime(namePart, value);
        if (dt != null) { start = dt; isAllDay = allDay; }
      } else if (namePart.startsWith('DTEND')) {
        final (dt, _) = _parseIcsDateTime(namePart, value);
        if (dt != null) end = dt;
      } else if (namePart == 'LOCATION') {
        location = value.isNotEmpty ? value : null;
      }
    }

    return _IcsEvent(
      summary: summary ?? '(No title)',
      start: start ?? DateTime.now().toUtc(),
      end: end ?? (start ?? DateTime.now().toUtc()).add(const Duration(hours: 1)),
      isAllDay: isAllDay,
      location: location,
    );
  }

  (DateTime?, bool) _parseIcsDateTime(String namePart, String value) {
    final isDate =
        namePart.contains('VALUE=DATE') && !namePart.contains('DATE-TIME');
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
      if (y != null &&
          mo != null &&
          d != null &&
          h != null &&
          mi != null &&
          s != null) {
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
    this.location,
  });

  final String summary;
  final DateTime start;
  final DateTime end;
  final bool isAllDay;
  final String? location;
}
