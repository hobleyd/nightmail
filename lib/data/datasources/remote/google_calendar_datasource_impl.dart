import 'package:dio/dio.dart';

import '../../../core/error/exceptions.dart';
import '../../../domain/entities/calendar_event.dart';
import '../../../domain/entities/calendar_event_attendee.dart';
import '../../../domain/entities/calendar_recurrence.dart';
import '../../../domain/entities/meeting_invite.dart';
import '../../../domain/usecases/create_calendar_event.dart';
import '../../../domain/usecases/update_calendar_event.dart';
import '../../../infrastructure/http/google_calendar_http_client.dart';
import '../../models/calendar_event_model.dart';
import 'calendar_remote_datasource.dart';

class GoogleCalendarDatasourceImpl implements CalendarRemoteDatasource {
  GoogleCalendarDatasourceImpl({required GoogleCalendarHttpClient client})
      : _dio = client.dio;

  final Dio _dio;

  @override
  Future<List<CalendarEventModel>> getCalendarEvents({
    required DateTime startDateTime,
    required DateTime endDateTime,
  }) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/calendars/primary/events',
        queryParameters: {
          'timeMin': startDateTime.toUtc().toIso8601String(),
          'timeMax': endDateTime.toUtc().toIso8601String(),
          'singleEvents': true,
          'orderBy': 'startTime',
          'maxResults': 250,
          'fields':
              'items(id,summary,start,end,description,location,status,organizer,attendees,allDayEvent,recurrence)',
        },
      );

      final data = response.data;
      if (data == null) return [];

      final items = data['items'] as List<dynamic>? ?? [];
      return items
          .map((e) => _parseEvent(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<CalendarEventModel> createCalendarEvent({
    required CreateCalendarEventParams params,
  }) async {
    try {
      final body = _buildEventBody(
        subject: params.subject,
        start: params.start,
        end: params.end,
        isAllDay: params.isAllDay,
        timezone: params.timezone,
        location: params.location,
        description: params.description,
        attendeeEmails: params.attendeeEmails,
        recurrence: params.recurrence,
      );

      final response = await _dio.post<Map<String, dynamic>>(
        '/calendars/primary/events',
        data: body,
      );

      if (response.data == null) {
        throw const ServerException(message: 'Empty response from server');
      }
      return _parseEvent(response.data!);
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<CalendarEventModel> updateCalendarEvent({
    required UpdateCalendarEventParams params,
  }) async {
    try {
      final body = _buildEventBody(
        subject: params.subject,
        start: params.start,
        end: params.end,
        isAllDay: params.isAllDay,
        timezone: params.timezone,
        location: params.location,
        description: params.description,
        attendeeEmails: params.attendeeEmails,
        recurrence: params.recurrence,
      );

      final response = await _dio.patch<Map<String, dynamic>>(
        '/calendars/primary/events/${params.id}',
        data: body,
      );

      if (response.data == null) {
        throw const ServerException(message: 'Empty response from server');
      }
      return _parseEvent(response.data!);
    } on DioException catch (e) {
      throw _mapException(e);
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
    if (icsData == null) {
      throw const ServerException(
          message: 'Cannot accept meeting invite: no iCalendar data');
    }

    final event = _parseIcs(icsData);
    final responseStatus = switch (response) {
      MeetingInviteResponseType.accept => 'accepted',
      MeetingInviteResponseType.tentative => 'tentative',
      MeetingInviteResponseType.decline => 'declined',
    };

    // Build attendee list: include ICS attendees plus self with the chosen status.
    final attendees = <Map<String, dynamic>>[
      ...event.attendees.where((a) => a != userEmail).map((a) => {'email': a}),
      if (userEmail != null) {'email': userEmail, 'responseStatus': responseStatus},
    ];

    final body = <String, dynamic>{
      'summary': event.summary,
      'start': event.isAllDay
          ? {'date': _formatDate(event.start)}
          : {'dateTime': event.start.toUtc().toIso8601String(), 'timeZone': 'UTC'},
      'end': event.isAllDay
          ? {'date': _formatDate(event.end)}
          : {'dateTime': event.end.toUtc().toIso8601String(), 'timeZone': 'UTC'},
      if (event.location != null) 'location': event.location,
      if (attendees.isNotEmpty) 'attendees': attendees,
    };

    try {
      await _dio.post<void>(
        '/calendars/primary/events',
        data: body,
        queryParameters: {'sendUpdates': 'all'},
      );
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<void> cancelCalendarEvent({required String eventId}) async {
    try {
      await _dio.delete<void>(
        '/calendars/primary/events/$eventId',
        queryParameters: {'sendUpdates': 'all'},
      );
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<void> declineCalendarEvent({
    required String eventId,
    String? userEmail,
  }) async {
    final attendees = <Map<String, dynamic>>[
      if (userEmail != null) {'email': userEmail, 'responseStatus': 'declined'},
    ];
    try {
      await _dio.patch<void>(
        '/calendars/primary/events/$eventId',
        data: {if (attendees.isNotEmpty) 'attendees': attendees},
        queryParameters: {'sendUpdates': 'all'},
      );
    } on DioException catch (e) {
      throw _mapException(e);
    }
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
    // Google Calendar has no native propose-new-time API; decline the original.
    await declineCalendarEvent(eventId: eventId, userEmail: userEmail);
  }

  /// Minimal iCalendar parser — extracts the first VEVENT's key properties.
  _IcsEvent _parseIcs(String icsData) {
    // Unfold continuation lines (RFC 5545: CRLF followed by whitespace).
    final unfolded =
        icsData.replaceAll(RegExp(r'\r?\n[ \t]'), '');

    String? summary;
    DateTime? start;
    DateTime? end;
    bool isAllDay = false;
    String? location;
    final attendees = <String>[];

    bool inVEvent = false;
    for (final rawLine in unfolded.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.toUpperCase() == 'BEGIN:VEVENT') {
        inVEvent = true;
        continue;
      }
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
        if (dt != null) {
          start = dt;
          isAllDay = allDay;
        }
      } else if (namePart.startsWith('DTEND')) {
        final (dt, _) = _parseIcsDateTime(namePart, value);
        if (dt != null) end = dt;
      } else if (namePart == 'LOCATION') {
        location = value.isNotEmpty ? value : null;
      } else if (namePart.startsWith('ATTENDEE')) {
        // Value format: mailto:email@example.com
        final mailto = value.toLowerCase().startsWith('mailto:')
            ? value.substring('mailto:'.length)
            : value;
        if (mailto.contains('@')) attendees.add(mailto);
      }
    }

    return _IcsEvent(
      summary: summary ?? '(No title)',
      start: start ?? DateTime.now().toUtc(),
      end: end ?? (start ?? DateTime.now().toUtc()).add(const Duration(hours: 1)),
      isAllDay: isAllDay,
      location: location,
      attendees: attendees,
    );
  }

  (DateTime?, bool) _parseIcsDateTime(String namePart, String value) {
    // All-day: VALUE=DATE or name contains ;VALUE=DATE
    final isDate = namePart.contains('VALUE=DATE') && !namePart.contains('DATE-TIME');
    if (isDate) {
      // Format: YYYYMMDD
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

    // UTC datetime: 20260615T100000Z
    // Local datetime with TZID: DTSTART;TZID=America/New_York:20260615T100000
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

  Map<String, dynamic> _buildEventBody({
    required String subject,
    required DateTime start,
    required DateTime end,
    required bool isAllDay,
    required String timezone,
    String? location,
    String? description,
    List<String> attendeeEmails = const [],
    CalendarRecurrence? recurrence,
  }) {
    final body = <String, dynamic>{
      'summary': subject,
      if (location != null && location.isNotEmpty) 'location': location,
      if (description != null && description.isNotEmpty)
        'description': description,
    };

    if (isAllDay) {
      body['start'] = {'date': _formatDate(start)};
      body['end'] = {'date': _formatDate(end)};
    } else {
      body['start'] = {
        'dateTime': _formatLocalDateTime(start),
        'timeZone': timezone,
      };
      body['end'] = {
        'dateTime': _formatLocalDateTime(end),
        'timeZone': timezone,
      };
    }

    if (attendeeEmails.isNotEmpty) {
      body['attendees'] =
          attendeeEmails.map((e) => {'email': e}).toList();
    }

    if (recurrence != null) {
      body['recurrence'] = [_buildRRule(recurrence)];
    }

    return body;
  }

  String _buildRRule(CalendarRecurrence r) {
    final parts = <String>['RRULE'];
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
      rule += ';UNTIL=${_formatRRuleDate(r.endDate!)}';
    } else if (r.count != null) {
      rule += ';COUNT=${r.count}';
    }

    parts.add(rule);
    return parts.join(':');
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  String _formatLocalDateTime(DateTime dt) {
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final mo = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final h = local.hour.toString().padLeft(2, '0');
    final mi = local.minute.toString().padLeft(2, '0');
    final s = local.second.toString().padLeft(2, '0');
    return '$y-$mo-${d}T$h:$mi:$s';
  }

  String _formatRRuleDate(DateTime dt) {
    final utc = dt.toUtc();
    final y = utc.year.toString().padLeft(4, '0');
    final m = utc.month.toString().padLeft(2, '0');
    final d = utc.day.toString().padLeft(2, '0');
    return '$y$m${d}T000000Z';
  }

  CalendarEventModel _parseEvent(Map<String, dynamic> json) {
    final startMap = json['start'] as Map<String, dynamic>? ?? {};
    final endMap = json['end'] as Map<String, dynamic>? ?? {};

    final isAllDay =
        startMap.containsKey('date') && !startMap.containsKey('dateTime');

    final start = isAllDay
        ? DateTime.parse('${startMap['date']}T00:00:00Z')
        : DateTime.parse(startMap['dateTime'] as String? ??
                DateTime.now().toIso8601String())
            .toUtc();

    final end = isAllDay
        ? DateTime.parse('${endMap['date']}T00:00:00Z')
        : DateTime.parse(endMap['dateTime'] as String? ??
                DateTime.now().toIso8601String())
            .toUtc();

    final organizerEmail =
        (json['organizer'] as Map<String, dynamic>?)?['email'] as String?;
    final rawAttendees =
        (json['attendees'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final selfAttendee =
        rawAttendees.where((a) => a['self'] == true).firstOrNull;
    final selfStatus = selfAttendee?['responseStatus'] as String?;

    final status = _parseStatus(selfStatus ?? json['status'] as String?);
    final isOrganizer = selfAttendee?['organizer'] == true ||
        (organizerEmail != null &&
            rawAttendees.any(
                (a) => a['email'] == organizerEmail && a['self'] == true));

    final attendees = rawAttendees
        .map((a) => CalendarEventAttendee(
              email: a['email'] as String? ?? '',
              displayName: a['displayName'] as String?,
              responseStatus: _parseAttendeeStatus(a['responseStatus'] as String?),
            ))
        .where((a) => a.email.isNotEmpty)
        .toList();

    return CalendarEventModel(
      id: json['id'] as String? ?? '',
      subject: json['summary'] as String? ?? '(No title)',
      start: start,
      end: end,
      isAllDay: isAllDay,
      location: json['location'] as String?,
      bodyPreview: json['description'] as String?,
      status: status,
      isOrganizer: isOrganizer,
      timezone: startMap['timeZone'] as String?,
      attendees: attendees,
    );
  }

  CalendarEventStatus _parseStatus(String? value) {
    return switch (value?.toLowerCase()) {
      'free' || 'accepted' => CalendarEventStatus.free,
      'tentative' || 'needsaction' => CalendarEventStatus.tentative,
      'declined' => CalendarEventStatus.free,
      _ => CalendarEventStatus.busy,
    };
  }

  AttendeeResponseStatus _parseAttendeeStatus(String? value) {
    return switch (value?.toLowerCase()) {
      'accepted' => AttendeeResponseStatus.accepted,
      'tentative' => AttendeeResponseStatus.tentative,
      'declined' => AttendeeResponseStatus.declined,
      _ => AttendeeResponseStatus.none,
    };
  }

  Exception _mapException(DioException e) {
    final statusCode = e.response?.statusCode;
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return NetworkException(message: e.message ?? 'Network error');
    }
    if (statusCode == 401) {
      return const AuthException(message: 'Authentication required');
    }
    return ServerException(
        message: e.message ?? 'Server error ($statusCode)',
        statusCode: statusCode);
  }
}

class _IcsEvent {
  const _IcsEvent({
    required this.summary,
    required this.start,
    required this.end,
    required this.isAllDay,
    this.location,
    this.attendees = const [],
  });

  final String summary;
  final DateTime start;
  final DateTime end;
  final bool isAllDay;
  final String? location;
  final List<String> attendees;
}
