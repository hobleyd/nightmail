import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../core/error/exceptions.dart';
import '../../../core/utils/ics_parser.dart';
import '../../../domain/entities/attendee_availability.dart';
import '../../../domain/entities/calendar_event.dart';
import '../../../domain/entities/calendar_event_attendee.dart';
import '../../../domain/entities/calendar_recurrence.dart';
import '../../../domain/entities/meeting_invite.dart';
import '../../../domain/usecases/create_calendar_event.dart';
import '../../../domain/entities/meeting_notify_scope.dart';
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

  // Parsed recurrence (RRULE) per series-master id. We fetch events with
  // `singleEvents=true`, which expands each series into instances that carry
  // only `recurringEventId` — the RRULE lives on the master alone. So to show
  // recurrence when editing an occurrence we fetch its master once and cache
  // the result. Keyed by master id; a null value means "master has no RRULE".
  // Refreshed at most once every 10 minutes, and cleared on any local edit so
  // recurrence changes made in-app are reflected immediately.
  final Map<String, CalendarRecurrence?> _recurrenceByMaster = {};
  DateTime? _recurrenceCacheAt;

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
    } catch (e) {
      debugPrint('GoogleCalendarDatasourceImpl: _getDefaultReminderMinutes failed: $e');
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
          // transparency/eventType/iCalUID feed conflict detection: the first
          // two decide whether an event really occupies its slot, the third
          // identifies the invite's own auto-added copy. A field mask omitting
          // them makes every event look busy and unidentifiable.
          'fields':
              'items(id,iCalUID,summary,start,end,description,location,status,transparency,eventType,organizer,attendees,hangoutLink,conferenceData,reminders,recurringEventId)',
        },
      );

      final data = response.data;
      if (data == null) return [];

      final rawItems =
          (data['items'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

      // Instances of a recurring series don't carry the RRULE — resolve it
      // from each distinct series master so the edit form can show recurrence.
      final masterIds = rawItems
          .map((e) => e['recurringEventId'] as String?)
          .whereType<String>()
          .toSet();
      final recurrenceByMaster = await _recurrencesForMasters(masterIds);

      return rawItems.map((e) {
        final masterId = e['recurringEventId'] as String?;
        return _parseEvent(
          e,
          defaultReminderMinutes,
          recurrence: masterId != null ? recurrenceByMaster[masterId] : null,
        );
      }).toList();
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<CalendarEventModel> getCalendarEvent({required String id}) async {
    try {
      final defaultReminderMinutes = await _getDefaultReminderMinutes();
      final resp = await _dio.get<Map<String, dynamic>>(
        '/calendars/primary/events/$id',
        queryParameters: {
          'fields':
              'id,iCalUID,summary,start,end,description,location,status,transparency,eventType,organizer,attendees,hangoutLink,conferenceData,reminders,recurringEventId,recurrence',
        },
      );
      final json = resp.data;
      if (json == null) {
        throw const ServerException(message: 'Empty response from server');
      }
      // A master event carries its own `recurrence` (RRULE) array directly.
      final rules = (json['recurrence'] as List<dynamic>?)?.cast<String>();
      return _parseEvent(
        json,
        defaultReminderMinutes,
        recurrence: _parseRecurrenceRules(rules),
      );
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
        isOnlineMeeting: params.isOnlineMeeting,
      );

      final response = await _dio.post<Map<String, dynamic>>(
        '/calendars/primary/events',
        data: body,
        queryParameters:
            params.isOnlineMeeting ? {'conferenceDataVersion': 1} : null,
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
    // Recurrence may have changed; drop the cache so the next load refetches.
    _invalidateRecurrenceCache();
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
        isOnlineMeeting: params.isOnlineMeeting,
        isUpdate: true,
      );

      // Google's API can only notify all guests or none — it cannot scope a
      // notification to just the added/removed attendees. So a roster-only
      // change (changedAttendeesOnly) falls back to notifying everyone; the
      // added/removed guests still get the right invite/cancellation, but
      // unchanged guests are also pinged. Graph handles the delta natively.
      final sendUpdates = switch (params.notifyScope) {
        MeetingNotifyScope.all => 'all',
        MeetingNotifyScope.changedAttendeesOnly => 'all',
        MeetingNotifyScope.none => 'none',
      };

      final response = await _dio.patch<Map<String, dynamic>>(
        '/calendars/primary/events/${params.id}',
        data: body,
        queryParameters: {
          'sendUpdates': sendUpdates,
          if (params.isOnlineMeeting) 'conferenceDataVersion': 1,
        },
      );

      if (response.data == null) {
        throw const ServerException(message: 'Empty response from server');
      }
      return _parseEvent(response.data!, const []);
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  /// The RSVP note, as the `comment` field Google shows the organizer next to
  /// our response. Omitted entirely when there is no note — sending
  /// `comment: ''` clears any note already on the attendee.
  Map<String, String> _responseComment(String? message) {
    final note = message?.trim();
    if (note == null || note.isEmpty) return const {};
    return {'comment': note};
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

    // Declining is handled specially so it both notifies the organizer AND clears
    // the event from our calendar. Google has no dedicated decline endpoint:
    //   1. PATCH responseStatus:'declined' with sendUpdates:'all' — this is the
    //      RSVP reply the organizer receives (identical mechanism to accept, which
    //      is confirmed to notify). A guest DELETE alone sends NOTHING, so the
    //      PATCH must happen first and is what actually notifies.
    //   2. DELETE the local copy (sendUpdates:'none') so the declined event no
    //      longer shows on our calendar, without emitting a second notification.
    // Decline never falls through to the create branch below — it must never add
    // an event.
    if (response == MeetingInviteResponseType.decline) {
      if (event.uid == null) return; // Nothing to look up / remove.
      final attendees = <Map<String, dynamic>>[
        ...event.attendees.where((a) => a != userEmail).map((a) => {'email': a}),
        if (userEmail != null)
          {
            'email': userEmail,
            'responseStatus': 'declined',
            ..._responseComment(message),
          },
      ];
      try {
        final searchResp = await _dio.get<Map<String, dynamic>>(
          '/calendars/primary/events',
          queryParameters: {'iCalUID': event.uid, 'maxResults': 1},
        );
        final items = (searchResp.data?['items'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();
        if (items.isEmpty) return; // Not on the calendar — nothing to decline.
        final eventId = items.first['id'] as String;
        // 1. Send the decline RSVP to the organizer.
        await _dio.patch<void>(
          '/calendars/primary/events/$eventId',
          data: {if (attendees.isNotEmpty) 'attendees': attendees},
          queryParameters: {'sendUpdates': 'all'},
        );
        // 2. Remove our now-declined copy from the calendar, silently.
        await _dio.delete<void>(
          '/calendars/primary/events/$eventId',
          queryParameters: {'sendUpdates': 'none'},
        );
      } on DioException catch (e) {
        throw _mapException(e);
      }
      return;
    }

    final responseStatus = switch (response) {
      MeetingInviteResponseType.accept => 'accepted',
      MeetingInviteResponseType.tentative => 'tentative',
      MeetingInviteResponseType.decline => 'declined',
    };

    // Build attendee list: include ICS attendees plus self with the chosen status.
    final attendees = <Map<String, dynamic>>[
      ...event.attendees.where((a) => a != userEmail).map((a) => {'email': a}),
      if (userEmail != null)
        {
          'email': userEmail,
          'responseStatus': responseStatus,
          ..._responseComment(message),
        },
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
  Future<void> acceptProposedTimeFromEmail({
    required String emailId,
    required DateTime newStart,
    required DateTime newEnd,
    String? icsData,
    DateTime? meetingStart,
  }) async {
    // Google has no message→event navigation, so the counter's UID is the only
    // way to find the meeting. It is echoed from the original invitation, so it
    // matches the organizer's own copy.
    if (icsData == null) {
      throw const ServerException(
          message: 'Cannot accept the proposal: the message has no '
              'iCalendar part identifying the meeting');
    }
    final uid = IcsParser.parse(icsData).uid;
    if (uid == null) {
      throw const ServerException(
          message: 'Cannot accept the proposal: iCalendar UID missing');
    }

    try {
      final searchResp = await _dio.get<Map<String, dynamic>>(
        '/calendars/primary/events',
        queryParameters: {'iCalUID': uid, 'maxResults': 1},
      );
      final items = (searchResp.data?['items'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      if (items.isEmpty) {
        throw const ServerException(
            message: 'That meeting is no longer in your calendar');
      }
      final event = items.first;
      // `organizer.self` is Google's marker for "this calendar owns it". Only
      // the organizer can move a meeting for everyone.
      final organizer = event['organizer'] as Map<String, dynamic>?;
      if (organizer?['self'] != true) {
        throw const ServerException(
            message: 'You are not the organizer of this meeting');
      }
      final eventId = event['id'] as String;

      // A recurring master here means the whole series moves — a counter that
      // named a single occurrence would have carried a RECURRENCE-ID, which
      // Google cannot address by UID anyway.
      if (event['recurrence'] != null) _invalidateRecurrenceCache();

      await _dio.patch<Map<String, dynamic>>(
        '/calendars/primary/events/$eventId',
        // sendUpdates=all is what actually re-issues the invitation; without it
        // the time changes and no attendee is told.
        queryParameters: {'sendUpdates': 'all'},
        data: {
          'start': {'dateTime': newStart.toUtc().toIso8601String(), 'timeZone': 'UTC'},
          'end': {'dateTime': newEnd.toUtc().toIso8601String(), 'timeZone': 'UTC'},
        },
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
  Future<void> cancelCalendarEventSeries({
    required String eventId,
    String? seriesMasterId,
    required DateTime occurrenceStart,
  }) async {
    final masterId = seriesMasterId ?? eventId;
    // Truncating the series rewrites the master's RRULE; drop the cache.
    _invalidateRecurrenceCache();
    try {
      // GET the series master to read the existing recurrence rules.
      final masterResp = await _dio.get<Map<String, dynamic>>(
        '/calendars/primary/events/$masterId',
      );
      final recurrenceList =
          (masterResp.data?['recurrence'] as List<dynamic>?)?.cast<String>();
      if (recurrenceList == null || recurrenceList.isEmpty) {
        // Not a recurring event — delete the single event.
        await _dio.delete<void>(
          '/calendars/primary/events/$eventId',
          queryParameters: {'sendUpdates': 'all'},
        );
        return;
      }

      // Set UNTIL to one second before the occurrence start, truncating the series.
      final until = occurrenceStart.toUtc().subtract(const Duration(seconds: 1));
      final updatedRecurrence = recurrenceList.map((rule) {
        if (!rule.startsWith('RRULE:')) return rule;
        var r = rule.replaceAll(RegExp(r';?UNTIL=[^;]*'), '');
        r = r.replaceAll(RegExp(r';?COUNT=\d+'), '');
        return '$r;UNTIL=${_formatRRuleUntil(until)}';
      }).toList();

      await _dio.patch<void>(
        '/calendars/primary/events/$masterId',
        data: {'recurrence': updatedRecurrence},
        queryParameters: {'sendUpdates': 'all'},
      );
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  String _formatRRuleUntil(DateTime dt) {
    final utc = dt.toUtc();
    final y = utc.year.toString().padLeft(4, '0');
    final mo = utc.month.toString().padLeft(2, '0');
    final d = utc.day.toString().padLeft(2, '0');
    final h = utc.hour.toString().padLeft(2, '0');
    final mi = utc.minute.toString().padLeft(2, '0');
    final s = utc.second.toString().padLeft(2, '0');
    return '${y}${mo}${d}T${h}${mi}${s}Z';
  }

  @override
  Future<void> declineCalendarEvent({
    required String eventId,
    String? userEmail,
  }) async {
    // Declining a meeting we were invited to. Google has no dedicated decline
    // endpoint, and a bare DELETE removes our copy WITHOUT notifying the organizer.
    // So we first PATCH our own responseStatus:'declined' with sendUpdates:'all'
    // (the RSVP reply the organizer receives), then DELETE the local copy silently
    // so the declined event no longer shows on our calendar. (Callers only route
    // non-organizer events here; organizer-owned events go through
    // cancelCalendarEvent instead.)
    try {
      if (userEmail != null) {
        await _dio.patch<void>(
          '/calendars/primary/events/$eventId',
          data: {
            'attendees': [
              {'email': userEmail, 'responseStatus': 'declined'},
            ],
          },
          queryParameters: {'sendUpdates': 'all'},
        );
      }
      await _dio.delete<void>(
        '/calendars/primary/events/$eventId',
        queryParameters: {'sendUpdates': 'none'},
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
  bool get supportsNativeProposeNewTime => false;

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
    // The proposed time itself reaches the organizer as the COUNTER reply the
    // repository sends afterwards (see supportsNativeProposeNewTime).
    await respondToMeetingInvite(
      emailId: emailId,
      response: MeetingInviteResponseType.decline,
      icsData: icsData,
      meetingStart: meetingStart,
      userEmail: userEmail,
      message: message,
    );
  }

  @override
  Future<List<AttendeeAvailability>> getAttendeesSchedule({
    required List<String> emails,
    required DateTime start,
    required DateTime end,
  }) async {
    // Google's freeBusy query reports opaque busy intervals only — no subject,
    // and no distinction between busy/tentative/out-of-office (unlike Graph's
    // getSchedule). So every returned interval maps to `busy` with no subject,
    // which the schedule pane renders as an unlabelled red block.
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/freeBusy',
        data: {
          'timeMin': start.toUtc().toIso8601String(),
          'timeMax': end.toUtc().toIso8601String(),
          'items': emails.map((e) => {'id': e}).toList(),
        },
      );

      final calendars =
          response.data?['calendars'] as Map<String, dynamic>? ?? {};

      return emails.map((email) {
        final entry = calendars[email] as Map<String, dynamic>?;
        // A calendar we cannot see comes back with an `errors` array (reason
        // notFound for an address outside the domain, or a sharing restriction)
        // and an empty `busy` list. That is indistinguishable from a genuinely
        // free day unless the errors are checked, so report unknown rather than
        // claiming the guest is free.
        final errors = entry?['errors'] as List<dynamic>?;
        if (entry == null || (errors != null && errors.isNotEmpty)) {
          if (errors != null && errors.isNotEmpty) {
            debugPrint(
                '[GoogleCalendar] freeBusy unavailable for $email: $errors');
          }
          return AttendeeAvailability(
            email: email,
            status: AttendeeAvailabilityStatus.unknown,
          );
        }

        final items = (entry['busy'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>()
            .map((slot) {
              final slotStart = slot['start'] as String?;
              final slotEnd = slot['end'] as String?;
              if (slotStart == null || slotEnd == null) return null;
              return AttendeeScheduleItem(
                start: DateTime.parse(slotStart).toUtc(),
                end: DateTime.parse(slotEnd).toUtc(),
                status: AttendeeAvailabilityStatus.busy,
              );
            })
            .whereType<AttendeeScheduleItem>()
            .toList();

        return AttendeeAvailability(
          email: email,
          status: items.isEmpty
              ? AttendeeAvailabilityStatus.free
              : AttendeeAvailabilityStatus.busy,
          scheduleItems: items,
        );
      }).toList();
    } on DioException catch (e) {
      // A 403 here is the expected state for an account authorised before the
      // calendar.freebusy scope was requested: the stored refresh token simply
      // does not carry it, and Google will not add it on refresh. Degrade to
      // unknown so the rest of the form still works — the user gets free/busy
      // back after signing the account in again.
      if (e.response?.statusCode == 403) {
        debugPrint('[GoogleCalendar] freeBusy denied (403) — the account most '
            'likely predates the calendar.freebusy scope; sign in again to '
            'restore attendee availability.');
        return emails
            .map((email) => AttendeeAvailability(
                  email: email,
                  status: AttendeeAvailabilityStatus.unknown,
                ))
            .toList();
      }
      throw _mapException(e);
    }
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
    bool isOnlineMeeting = false,
    bool isUpdate = false,
  }) {
    final body = <String, dynamic>{
      'summary': subject,
      if (location != null && location.isNotEmpty) 'location': location,
      if (description != null && description.isNotEmpty)
        'description': description,
    };

    // Attach a Google Meet. Requires `conferenceDataVersion=1` on the request
    // (set by the caller); Google fills in the join URL server-side and returns
    // it via conferenceData/hangoutLink. The requestId only needs to be unique
    // per request, so a fresh UUID is fine.
    if (isOnlineMeeting) {
      body['conferenceData'] = {
        'createRequest': {
          'requestId': const Uuid().v4(),
          'conferenceSolutionKey': {'type': 'hangoutsMeet'},
        },
      };
    }

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

  String _buildRRule(CalendarRecurrence rawR) {
    final r = rawR.normalizedForSync();
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

  void _invalidateRecurrenceCache() {
    _recurrenceByMaster.clear();
    _recurrenceCacheAt = null;
  }

  /// Resolves the recurrence rule for each distinct series master, fetching any
  /// not already cached (in parallel) and returning a map of master id →
  /// parsed recurrence (null when the master has no RRULE or the fetch fails).
  Future<Map<String, CalendarRecurrence?>> _recurrencesForMasters(
      Set<String> masterIds) async {
    final now = DateTime.now();
    if (_recurrenceCacheAt == null ||
        now.difference(_recurrenceCacheAt!) > const Duration(minutes: 10)) {
      _recurrenceByMaster.clear();
      _recurrenceCacheAt = now;
    }

    final missing = masterIds
        .where((id) => !_recurrenceByMaster.containsKey(id))
        .toList();
    await Future.wait(missing.map((id) async {
      try {
        _recurrenceByMaster[id] =
            _parseRecurrenceRules(await _fetchRecurrenceRules(id));
      } catch (e) {
        debugPrint(
            'GoogleCalendarDatasourceImpl: recurrence fetch for $id failed: $e');
        _recurrenceByMaster[id] = null;
      }
    }));

    return {for (final id in masterIds) id: _recurrenceByMaster[id]};
  }

  /// GETs a series master's `recurrence` array, tolerating the ids Google
  /// reports for a split series.
  ///
  /// Editing a series as "this and following" splits it: the original master is
  /// truncated and a second master is created with id
  /// `<originalId>_R<UTC occurrence start>`. Later instances point at that
  /// split id via `recurringEventId`, and `events.get` returns **404** for it
  /// whenever this calendar holds no copy of the split master — the usual case
  /// for an attendee, since the split happened on the organizer's calendar.
  /// A 404 here is therefore expected, not a fault: retry the base id, which
  /// often does resolve, and fall back to null (no recurrence shown) rather
  /// than logging. Anything other than a 404 is still worth a line in the log.
  Future<List<String>?> _fetchRecurrenceRules(String id) async {
    try {
      return await _getRecurrenceField(id);
    } on DioException catch (e) {
      if (e.response?.statusCode != 404) {
        debugPrint(
            'GoogleCalendarDatasourceImpl: recurrence fetch for $id failed: $e');
        return null;
      }
    }

    final split = RegExp(r'^(.+)_R\d{8}T\d{6}Z?$').firstMatch(id);
    if (split == null) return null;
    try {
      return await _getRecurrenceField(split.group(1)!);
    } on DioException catch (e) {
      if (e.response?.statusCode != 404) {
        debugPrint('GoogleCalendarDatasourceImpl: recurrence fetch for '
            '${split.group(1)} (base of $id) failed: $e');
      }
      return null;
    }
  }

  Future<List<String>?> _getRecurrenceField(String id) async {
    final resp = await _dio.get<Map<String, dynamic>>(
      '/calendars/primary/events/$id',
      queryParameters: {'fields': 'recurrence'},
    );
    return (resp.data?['recurrence'] as List<dynamic>?)?.cast<String>();
  }

  /// Picks the RRULE line out of a master's `recurrence` array (which may also
  /// contain EXDATE/RDATE/EXRULE lines) and parses it.
  CalendarRecurrence? _parseRecurrenceRules(List<String>? rules) {
    if (rules == null) return null;
    for (final raw in rules) {
      final line = raw.trim();
      if (line.toUpperCase().startsWith('RRULE')) return _parseRRule(line);
    }
    return null;
  }

  /// Inverse of [_buildRRule]: parses an iCalendar RRULE line into a
  /// [CalendarRecurrence]. Returns null if FREQ is missing or unrecognized.
  CalendarRecurrence? _parseRRule(String line) {
    // Drop an optional "RRULE:" prefix, then split the ";"-separated params.
    final body =
        line.contains(':') ? line.substring(line.indexOf(':') + 1) : line;
    final params = <String, String>{};
    for (final part in body.split(';')) {
      final eq = part.indexOf('=');
      if (eq > 0) {
        params[part.substring(0, eq).toUpperCase()] = part.substring(eq + 1);
      }
    }

    final frequency = switch (params['FREQ']?.toUpperCase()) {
      'DAILY' => RecurrenceFrequency.daily,
      'WEEKLY' => RecurrenceFrequency.weekly,
      'MONTHLY' => RecurrenceFrequency.monthly,
      'YEARLY' => RecurrenceFrequency.yearly,
      _ => null,
    };
    if (frequency == null) return null;

    final interval = int.tryParse(params['INTERVAL'] ?? '') ?? 1;

    List<int>? daysOfWeek;
    final byDay = params['BYDAY'];
    if (byDay != null && byDay.isNotEmpty) {
      const dayNumbers = {
        'MO': 1, 'TU': 2, 'WE': 3, 'TH': 4, 'FR': 5, 'SA': 6, 'SU': 7,
      };
      final days = byDay
          .split(',')
          .map((token) {
            // BYDAY entries may carry an ordinal prefix, e.g. "2MO" or "-1FR";
            // the day code is always the trailing two letters.
            final code = token.trim().toUpperCase();
            final key = code.length >= 2 ? code.substring(code.length - 2) : code;
            return dayNumbers[key];
          })
          .whereType<int>()
          .toList();
      if (days.isNotEmpty) daysOfWeek = days;
    }

    DateTime? endDate;
    int? count;
    final until = params['UNTIL'];
    final countStr = params['COUNT'];
    if (until != null && until.isNotEmpty) {
      endDate = _parseUntil(until);
    } else if (countStr != null) {
      count = int.tryParse(countStr);
    }

    return CalendarRecurrence(
      frequency: frequency,
      interval: interval,
      daysOfWeek: daysOfWeek,
      endDate: endDate,
      count: count,
    );
  }

  /// Parses an RRULE UNTIL value (`yyyymmdd`, `yyyymmddThhmmss`, or
  /// `yyyymmddThhmmssZ`) into a local date. Only the calendar date is kept, to
  /// match how the recurrence end date is represented elsewhere (Graph returns
  /// a plain date), and to avoid a timezone shift moving it to an adjacent day.
  DateTime? _parseUntil(String raw) {
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})').firstMatch(raw.trim());
    if (m == null) return null;
    return DateTime(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
    );
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
    List<int> defaultReminderMinutes, {
    CalendarRecurrence? recurrence,
  }) {
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

    final organizerMap = json['organizer'] as Map<String, dynamic>?;
    final organizerEmail = organizerMap?['email'] as String?;
    final rawAttendees =
        (json['attendees'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final selfAttendee =
        rawAttendees.where((a) => a['self'] == true).firstOrNull;
    final selfStatus = selfAttendee?['responseStatus'] as String?;

    // `organizer.self` is Google's authoritative "I own this event" flag and is
    // present even when the event has no other guests (in which case
    // `attendees` is empty and the per-attendee organizer flag can't be
    // consulted). That empty-attendees case — common for self-created and
    // recurring meetings — previously fell through to isOrganizer=false and
    // made the event look read-only / mis-routed delete to "decline".
    final isOrganizer = organizerMap?['self'] == true ||
        selfAttendee?['organizer'] == true ||
        (organizerEmail != null &&
            rawAttendees.any(
                (a) => a['email'] == organizerEmail && a['self'] == true));

    // Free/busy status, used for conflict detection (not colouring).
    final status = _parseStatus(
      eventStatus: json['status'] as String?,
      transparency: json['transparency'] as String?,
      eventType: json['eventType'] as String?,
      selfResponseStatus: selfStatus,
    );

    // Participation drives the tile colour. Google inconsistently omits the
    // organizer from `attendees`, so we lean on the `organizer.self` flag
    // (captured in isOrganizer) rather than a self-attendee RSVP to identify
    // meetings you own.
    final participation = _parseParticipation(
      isOrganizer: isOrganizer,
      responseStatus: selfStatus,
    );

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
      iCalUid: json['iCalUID'] as String?,
      location: _parseLocation(
        json['location'] as String?,
        description,
        _conferenceJoinUrl(json),
      ),
      bodyPreview: description,
      status: status,
      participation: participation,
      isOrganizer: isOrganizer,
      timezone: startMap['timeZone'] as String?,
      attendees: attendees,
      recurrence: recurrence,
      reminderMinutes:
          _parseReminderMinutes(json['reminders'], defaultReminderMinutes),
      seriesMasterId: json['recurringEventId'] as String?,
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

  /// Free/busy status, used for conflict detection (not colouring).
  ///
  /// Google has no single `showAs`-style field, so this combines three
  /// independent signals, in priority order:
  ///
  ///  * `status: 'cancelled'` — called off, so no longer a commitment.
  ///  * `transparency: 'transparent'` — the event's own "show me as available"
  ///    flag (Google's UI calls it Busy/Free). Absent or `opaque` means busy;
  ///    this is the *only* field that genuinely means free.
  ///  * `eventType` — working-location entries are a location marker rather
  ///    than a commitment; out-of-office blocks the day.
  ///  * the user's own RSVP — `declined` releases the slot, `tentative` and
  ///    `needsAction` hold it loosely.
  ///
  /// An RSVP of `accepted` is emphatically **not** free. It used to map to
  /// [CalendarEventStatus.free], which silently disabled conflict detection
  /// against every meeting the user had accepted — i.e. against almost
  /// everything a new invite can realistically clash with.
  CalendarEventStatus _parseStatus({
    String? eventStatus,
    String? transparency,
    String? eventType,
    String? selfResponseStatus,
  }) {
    if (eventStatus?.toLowerCase() == 'cancelled') {
      return CalendarEventStatus.free;
    }
    if (transparency?.toLowerCase() == 'transparent') {
      return CalendarEventStatus.free;
    }
    switch (eventType?.toLowerCase()) {
      case 'outofoffice':
        return CalendarEventStatus.outOfOffice;
      case 'workinglocation':
        return CalendarEventStatus.workingElsewhere;
    }
    return switch (selfResponseStatus?.toLowerCase()) {
      'declined' => CalendarEventStatus.free,
      'tentative' || 'needsaction' => CalendarEventStatus.tentative,
      _ => CalendarEventStatus.busy,
    };
  }

  /// Maps Google's organiser flag + the user's `responseStatus`
  /// (accepted/tentative/needsAction/declined) onto the shared
  /// [MeetingParticipation] enum. `isOrganizer` wins so meetings you own are
  /// always [MeetingParticipation.organizer], even when Google omits you from
  /// the `attendees` list (a common inconsistency for self-created events).
  MeetingParticipation _parseParticipation({
    required bool isOrganizer,
    String? responseStatus,
  }) {
    if (isOrganizer) return MeetingParticipation.organizer;
    return switch (responseStatus?.toLowerCase()) {
      'accepted' => MeetingParticipation.accepted,
      'tentative' => MeetingParticipation.tentative,
      'needsaction' => MeetingParticipation.needsAction,
      'declined' => MeetingParticipation.declined,
      _ => MeetingParticipation.none,
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

