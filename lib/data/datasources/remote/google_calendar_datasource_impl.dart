import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/error/exceptions.dart';
import '../../../core/utils/ics_parser.dart';
import '../../../domain/entities/attendee_availability.dart';
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

  // Cached popup-reminder minutes from the primary calendar's settings, used
  // when an event has reminders.useDefault == true (events.list carries no
  // minutes value for that case — the default lives on the CalendarList
  // resource, not the Events resource). Refreshed at most once per hour.
  List<int>? _defaultReminderMinutes;
  DateTime? _defaultReminderFetchedAt;

  Future<List<int>> _getDefaultReminderMinutes() async {
    final now = DateTime.now();
    if (_defaultReminderMinutes != null &&
        _defaultReminderFetchedAt != null &&
        now.difference(_defaultReminderFetchedAt!) < const Duration(hours: 1)) {
      return _defaultReminderMinutes!;
    }
    try {
      final resp = await _dio
          .get<Map<String, dynamic>>('/users/me/calendarList/primary');
      final defaults = (resp.data?['defaultReminders'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>()
          .where((r) => r['method'] == 'popup')
          .map((r) => r['minutes'] as int)
          .toList();
      _defaultReminderMinutes = defaults;
      _defaultReminderFetchedAt = now;
      return defaults;
    } catch (_) {
      return _defaultReminderMinutes ?? const [];
    }
  }

  @override
  Future<List<CalendarEventModel>> getCalendarEvents({
    required DateTime startDateTime,
    required DateTime endDateTime,
  }) async {
    try {
      final defaultReminderMinutes = await _getDefaultReminderMinutes();
      final response = await _dio.get<Map<String, dynamic>>(
        '/calendars/primary/events',
        queryParameters: {
          'timeMin': startDateTime.toUtc().toIso8601String(),
          'timeMax': endDateTime.toUtc().toIso8601String(),
          'singleEvents': true,
          'orderBy': 'startTime',
          'maxResults': 250,
          'fields':
              'items(id,summary,start,end,description,location,status,organizer,attendees,hangoutLink,conferenceData,reminders)',
        },
      );

      final data = response.data;
      if (data == null) return [];

      final items = data['items'] as List<dynamic>? ?? [];
      return items
          .map((e) => _parseEvent(
              e as Map<String, dynamic>, defaultReminderMinutes))
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
        reminderMinutes: params.reminderMinutes,
      );

      final response = await _dio.post<Map<String, dynamic>>(
        '/calendars/primary/events',
        data: body,
      );

      if (response.data == null) {
        throw const ServerException(message: 'Empty response from server');
      }
      return _parseEvent(response.data!, const []);
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
        reminderMinutes: params.reminderMinutes,
        isUpdate: true,
      );

      final response = await _dio.patch<Map<String, dynamic>>(
        '/calendars/primary/events/${params.id}',
        data: body,
      );

      if (response.data == null) {
        throw const ServerException(message: 'Empty response from server');
      }
      return _parseEvent(response.data!, const []);
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
    String? message,
  }) async {
    if (icsData == null) {
      throw const ServerException(
          message: 'Cannot accept meeting invite: no iCalendar data');
    }

    final event = IcsParser.parse(icsData);
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

    // Google auto-adds invite events to the calendar with needsAction status,
    // so the event almost always already exists. Look it up by iCalUID and PATCH
    // the attendee response — POSTing a new event returns 403 if the UID exists.
    if (event.uid != null) {
      try {
        final searchResp = await _dio.get<Map<String, dynamic>>(
          '/calendars/primary/events',
          queryParameters: {'iCalUID': event.uid, 'maxResults': 1},
        );
        final items = (searchResp.data?['items'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();
        if (items.isNotEmpty) {
          final eventId = items.first['id'] as String;
          await _dio.patch<void>(
            '/calendars/primary/events/$eventId',
            data: {if (attendees.isNotEmpty) 'attendees': attendees},
            queryParameters: {'sendUpdates': 'all'},
          );
          return;
        }
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        if (status == 401 || status == 403) throw _mapException(e);
        // Search failed — fall through to create.
      }
    }

    // Fallback: create the event (invite not yet auto-added to calendar).
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
  Future<void> removeMeetingFromCalendar({
    required String emailId,
    String? icsData,
    DateTime? meetingStart,
  }) async {
    if (icsData == null) {
      throw const ServerException(
          message: 'Cannot remove meeting: no iCalendar data');
    }
    final event = IcsParser.parse(icsData);
    if (event.uid == null) {
      throw const ServerException(
          message: 'Cannot remove meeting: iCalendar UID missing');
    }
    try {
      final searchResp = await _dio.get<Map<String, dynamic>>(
        '/calendars/primary/events',
        queryParameters: {'iCalUID': event.uid, 'maxResults': 1},
      );
      final items = (searchResp.data?['items'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      if (items.isEmpty) return; // Not in calendar — nothing to remove.
      final eventId = items.first['id'] as String;
      await _dio.delete<void>('/calendars/primary/events/$eventId');
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<void> cancelMeetingFromEmail({
    required String emailId,
    DateTime? meetingStart,
  }) async {
    throw const ServerException(
        message: 'Cancel from decline notification is not supported for Google Calendar');
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

  @override
  Future<void> proposeNewTimeFromEmail({
    required String emailId,
    required DateTime newStart,
    required DateTime newEnd,
    String? icsData,
    DateTime? meetingStart,
    String? userEmail,
    String? message,
  }) async {
    // Google Calendar has no native propose-new-time API; decline the invite.
    await respondToMeetingInvite(
      emailId: emailId,
      response: MeetingInviteResponseType.decline,
      icsData: icsData,
      meetingStart: meetingStart,
      userEmail: userEmail,
    );
  }

  @override
  Future<List<AttendeeAvailability>> getAttendeesSchedule({
    required List<String> emails,
    required DateTime start,
    required DateTime end,
  }) async {
    // Google Calendar FreeBusy API requires OAuth scope not currently requested;
    // return unknown status so the UI omits availability indicators.
    return emails
        .map((e) => AttendeeAvailability(
              email: e,
              status: AttendeeAvailabilityStatus.unknown,
            ))
        .toList();
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
    int? reminderMinutes,
    bool isUpdate = false,
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

    // On create, omitting `reminders` when unset just means "use the
    // calendar's default" — an acceptable default for a fresh event. On
    // update, always send it explicitly: omitting a field on PATCH means
    // "leave unchanged", so clearing a reminder in the edit dialog would
    // otherwise silently fail to take effect server-side.
    if (reminderMinutes != null) {
      body['reminders'] = {
        'useDefault': false,
        'overrides': [
          {'method': 'popup', 'minutes': reminderMinutes},
        ],
      };
    } else if (isUpdate) {
      body['reminders'] = {'useDefault': false, 'overrides': []};
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

  CalendarEventModel _parseEvent(
    Map<String, dynamic> json,
    List<int> defaultReminderMinutes,
  ) {
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

    final description = json['description'] as String?;
    return CalendarEventModel(
      id: json['id'] as String? ?? '',
      subject: json['summary'] as String? ?? '(No title)',
      start: start,
      end: end,
      isAllDay: isAllDay,
      location: _parseLocation(
        json['location'] as String?,
        description,
        _conferenceJoinUrl(json),
      ),
      bodyPreview: description,
      status: status,
      isOrganizer: isOrganizer,
      timezone: startMap['timeZone'] as String?,
      attendees: attendees,
      reminderMinutes:
          _parseReminderMinutes(json['reminders'], defaultReminderMinutes),
    );
  }

  /// Resolves a single reminder-minutes value from Google's `reminders`
  /// object. NightMail's domain model holds one reminder per event, so when
  /// several are present the earliest (minimum minutes) wins.
  static int? _parseReminderMinutes(
    dynamic remindersJson,
    List<int> defaultReminderMinutes,
  ) {
    if (remindersJson is! Map<String, dynamic>) return null;
    final useDefault = remindersJson['useDefault'] as bool? ?? false;
    if (useDefault) {
      if (defaultReminderMinutes.isEmpty) return null;
      return defaultReminderMinutes.reduce((a, b) => a < b ? a : b);
    }
    final overrides = (remindersJson['overrides'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()
        .where((o) => o['method'] == 'popup')
        .map((o) => o['minutes'] as int)
        .toList();
    if (overrides.isEmpty) return null;
    return overrides.reduce((a, b) => a < b ? a : b);
  }

  /// Extracts the video join URL from `conferenceData.entryPoints`
  /// (falls back to the deprecated top-level `hangoutLink`).
  static String? _conferenceJoinUrl(Map<String, dynamic> json) {
    final conferenceData = json['conferenceData'] as Map<String, dynamic>?;
    final entryPoints =
        conferenceData?['entryPoints'] as List<dynamic>?;
    if (entryPoints != null) {
      final video = entryPoints
          .cast<Map<String, dynamic>>()
          .where((e) => e['entryPointType'] == 'video')
          .firstOrNull;
      final uri = video?['uri'] as String?;
      if (uri != null && uri.isNotEmpty) return uri;
    }
    return json['hangoutLink'] as String?;
  }

  static String? _parseLocation(
    String? location,
    String? description,
    String? conferenceJoinUrl,
  ) {
    if (conferenceJoinUrl != null && conferenceJoinUrl.isNotEmpty) {
      return conferenceJoinUrl;
    }
    if (location != null && location.startsWith('https://')) return location;
    if (description != null) {
      final match = RegExp(
        r'https://(?:teams\.microsoft\.com/l/meetup-join|meet\.google\.com)/[^\s<>"]*',
      ).firstMatch(description);
      if (match != null) return match.group(0);
    }
    return (location != null && location.isNotEmpty) ? location : null;
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
    // AuthInterceptor.onRequest can throw AuthException directly (e.g. no
    // stored token, or a failed proactive refresh) before any HTTP request
    // is sent. Dio wraps that throw in a DioException with no response, so
    // it must be unwrapped here or it falls through to a generic
    // ServerException and the UI never learns re-authentication is needed.
    if (e.error is AuthException) return e.error as AuthException;

    debugPrint('[GoogleCalendar] ${e.requestOptions.method} '
        '${e.requestOptions.path} failed: status=${e.response?.statusCode} '
        'body=${e.response?.data} requestBody=${e.requestOptions.data}');

    final statusCode = e.response?.statusCode;
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return NetworkException(message: e.message ?? 'Network error');
    }
    if (statusCode == 401) {
      final msg = _extractGoogleErrorMessage(e) ?? 'Authentication required';
      return AuthException(message: msg);
    }
    // Deliberately do not fall back to e.message here: for a bad HTTP
    // response Dio's default message is its own internal boilerplate
    // ("...RequestOptions.validateStatus was configured to throw..."),
    // which is meaningless to a user and must never reach the UI.
    final msg = _extractGoogleErrorMessage(e) ??
        (statusCode != null ? 'Server error ($statusCode)' : e.message) ??
        'Unknown server error';
    return ServerException(message: msg, statusCode: statusCode);
  }

  String? _extractGoogleErrorMessage(DioException e) {
    try {
      final data = e.response?.data;
      if (data is Map) {
        final error = data['error'];
        if (error is Map) return error['message'] as String?;
      }
    } catch (_) {}
    return null;
  }
}

