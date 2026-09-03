import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../core/error/exceptions.dart';
import '../../../core/utils/ics_parser.dart';
import '../../../core/utils/online_meeting_url.dart';
import '../../../core/utils/rrule.dart';
import '../../../domain/entities/attendee_availability.dart';
import '../../../domain/entities/calendar_event.dart';
import '../../../domain/entities/calendar_event_attendee.dart';
import '../../../domain/entities/calendar_recurrence.dart';
import '../../../domain/entities/meeting_invite.dart';
import '../../../domain/entities/meeting_room.dart';
import '../../../domain/usecases/create_calendar_event.dart';
import '../../../domain/entities/meeting_notify_scope.dart';
import '../../../domain/usecases/update_calendar_event.dart';
import '../../../infrastructure/http/google_calendar_http_client.dart';
import '../../models/calendar_event_model.dart';
import 'calendar_remote_datasource.dart';

class GoogleCalendarDatasourceImpl implements CalendarRemoteDatasource {
  GoogleCalendarDatasourceImpl({
    required GoogleCalendarHttpClient client,
    required String accountEmail,
  })  : _dio = client.dio,
        _accountEmail = accountEmail;

  final Dio _dio;

  /// This account's own address. Google does not add the organizer to
  /// `attendees` on an API-created event the way its own web UI does, so we
  /// have to send it ourselves — see [_buildEventBody]. Mirrors
  /// `GraphApiDatasourceImpl.mailboxAddress`.
  final String _accountEmail;

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
        roomEmails: params.roomEmails,
        recurrence: params.recurrence,
        reminderMinutes: params.reminderMinutes,
        isOnlineMeeting: params.isOnlineMeeting,
      );

      final response = await _dio.post<Map<String, dynamic>>(
        '/calendars/primary/events',
        data: body,
        queryParameters: const {
          // Always 1, not only when creating a conference. Version 0 declares
          // that this client has no conference support, and Google then leaves
          // `conferenceData` out of the *response* — so the event we cache and
          // paint from would have no join link even though the meeting has one.
          'conferenceDataVersion': 1,
          // A create always notifies everyone invited, which is what
          // `_computeNotifyScope` already returns for one. Google's default
          // here is `sendUpdates=false`: guests on Google Calendar were still
          // written onto their own calendars silently, so the meeting looked
          // like it had gone out, but nobody was *emailed* an invitation —
          // and a guest who is not a Google user got nothing at all.
          'sendUpdates': 'all',
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
        roomEmails: params.roomEmails,
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
          // Always 1 — see createCalendarEvent. Editing an existing Meet with
          // version 0 returned an event with no `conferenceData`, and the cache
          // was rewritten from that response, so the join link vanished from the
          // app the moment anything else about the meeting was saved.
          'conferenceDataVersion': 1,
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
      // Omitted when the invitation has no title; Google shows an untitled
      // event as "(No title)" itself, and nothing here knows the covering
      // email's subject to offer a better one.
      if (event.summary != null) 'summary': event.summary,
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

  /// Google has no forward endpoint, so forwarding is done as what it actually
  /// is: adding a guest to the organizer's event. Google lets a guest do that
  /// when the organizer left `guestsCanInviteOthers` on (its default) and then
  /// sends the invitation itself, from the event — which is exactly the
  /// on-behalf-of-the-organizer outcome Graph's `/forward` produces.
  ///
  /// Everything else here follows from the attendee array being a **whole-list
  /// replace**: the existing roster has to be read and re-sent, or adding one
  /// guest would silently uninvite everybody else and drop every RSVP already
  /// given.
  @override
  Future<void> forwardCalendarEvent({
    required String eventId,
    required List<String> toAddresses,
    String? comment,
  }) async {
    final Map<String, dynamic> event;
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/calendars/primary/events/$eventId',
      );
      final data = resp.data;
      if (data == null) {
        throw const ServerException(message: 'Empty response from server');
      }
      event = data;
    } on DioException catch (e) {
      throw _mapException(e);
    }

    // The organizer may always add guests to their own event; everyone else
    // needs the permission. Google reports it as `false` only when it has been
    // turned off, so an absent field means allowed.
    final isOrganizer = (event['organizer'] as Map<String, dynamic>?)?['self'] ==
        true;
    if (!isOrganizer && event['guestsCanInviteOthers'] == false) {
      throw const MeetingForwardUnsupportedException(
        message: 'The organizer has not allowed guests to invite others',
      );
    }

    final existing =
        (event['attendees'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final known = <String>{
      for (final a in existing)
        if (a['email'] is String) (a['email'] as String).toLowerCase(),
    };
    final additions = <String>[];
    for (final address in toAddresses) {
      final trimmed = address.trim();
      if (trimmed.isEmpty || !known.add(trimmed.toLowerCase())) continue;
      additions.add(trimmed);
    }
    // Everyone asked for is already on it — nothing to send, and re-patching an
    // unchanged roster would email the whole guest list an update for no reason.
    if (additions.isEmpty) return;

    final attendees = <Map<String, dynamic>>[
      // Rebuilt field by field rather than echoed: Google rejects a PATCH that
      // carries back its own output-only flags (`self`, `organizer`,
      // `responseStatus` on a resource).
      for (final a in existing)
        {
          'email': a['email'],
          if (a['displayName'] != null) 'displayName': a['displayName'],
          if (a['responseStatus'] != null)
            'responseStatus': a['responseStatus'],
          if (a['optional'] == true) 'optional': true,
          if (a['resource'] == true) 'resource': true,
        },
      for (final email in additions) {'email': email},
    ];

    try {
      await _dio.patch<void>(
        '/calendars/primary/events/$eventId',
        data: {'attendees': attendees},
        queryParameters: {
          // 'all', not 'externalOnly': the point of the call is that the new
          // guest is told about the meeting, and Google scopes this by *guest
          // type* (external vs Google Calendar) rather than by who changed, so
          // anything narrower would silently skip a Google-using recipient.
          'sendUpdates': 'all',
          // Sent on every update, not just when attaching a Meet: version 0
          // declares no conference support and makes Google omit conferenceData
          // from the response, which is what the cache is rewritten from.
          'conferenceDataVersion': 1,
        },
      );
    } on DioException catch (e) {
      // 403 here is the permission answer arriving late — the event allowed
      // guest invitations when read, but the domain or the calendar's own ACL
      // refused the write. Same settled "no" as the flag itself.
      if (e.response?.statusCode == 403) {
        throw MeetingForwardUnsupportedException(
          message:
              _extractGoogleErrorMessage(e) ?? 'Adding a guest was refused',
        );
      }
      throw _mapException(e);
    }
  }

  @override
  Future<void> forwardMeetingFromEmail({
    required String emailId,
    required List<String> toAddresses,
    String? icsData,
    DateTime? meetingStart,
    String? comment,
  }) async {
    // No UID means no way to find the calendar copy, and Gmail messages carry
    // no navigation to one the way Graph's eventMessages do. Rather than fail,
    // report it as unsupported so the invitation is emailed on instead.
    if (icsData == null) {
      throw const MeetingForwardUnsupportedException(
        message: 'The invitation carries no calendar data to match against '
            'your calendar',
      );
    }
    final uid = IcsParser.parse(icsData).uid;
    if (uid == null) {
      throw const MeetingForwardUnsupportedException(
        message: 'The invitation carries no iCalendar UID',
      );
    }

    final String eventId;
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/calendars/primary/events',
        queryParameters: {'iCalUID': uid, 'maxResults': 1},
      );
      final items = (resp.data?['items'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      if (items.isEmpty) {
        throw const MeetingForwardUnsupportedException(
          message: 'This meeting is not on your calendar',
        );
      }
      eventId = items.first['id'] as String;
    } on DioException catch (e) {
      throw _mapException(e);
    }

    await forwardCalendarEvent(
      eventId: eventId,
      toAddresses: toAddresses,
      comment: comment,
    );
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

  /// Calendars per `freeBusy` query. Google caps the `items` array, and the
  /// room picker asks about every room it is showing at once.
  static const _freeBusyBatchSize = 50;

  @override
  Future<List<AttendeeAvailability>> getAttendeesSchedule({
    required List<String> emails,
    required DateTime start,
    required DateTime end,
  }) async {
    if (emails.length <= _freeBusyBatchSize) {
      return _getAttendeesScheduleBatch(emails: emails, start: start, end: end);
    }

    final batches = <List<String>>[];
    for (var i = 0; i < emails.length; i += _freeBusyBatchSize) {
      batches.add(
          emails.sublist(i, (i + _freeBusyBatchSize).clamp(0, emails.length)));
    }
    final results = await Future.wait(batches.map((batch) =>
        _getAttendeesScheduleBatch(emails: batch, start: start, end: end)));
    return results.expand((r) => r).toList();
  }

  Future<List<AttendeeAvailability>> _getAttendeesScheduleBatch({
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

  /// Rooms by lower-cased address, once [getMeetingRooms] has run. Only used to
  /// name a booked room in the event's free-text `location`.
  final Map<String, MeetingRoom> _roomsByEmail = {};

  /// Google marks every resource calendar with this address suffix, which is the
  /// only signal available without the Admin SDK.
  static const _resourceCalendarSuffix = '@resource.calendar.google.com';

  /// Rooms per directory page. The Admin SDK caps `maxResults` at 500.
  static const _roomPageSize = 500;

  /// Guard against a pathological tenant (or a pageToken loop) turning the room
  /// picker into an unbounded fetch.
  static const _maxRoomPages = 10;

  @override
  Future<List<MeetingRoom>> getMeetingRooms() async {
    // The directory is the real answer when we can have it: it covers every
    // room in the tenant, not only the ones this user happens to have added.
    final directory = await _fetchRoomsFromDirectory();
    final rooms = directory ?? await _fetchRoomsFromCalendarList();
    _roomsByEmail
      ..clear()
      ..addEntries(rooms.map((r) => MapEntry(r.email.toLowerCase(), r)));
    return rooms;
  }

  /// Admin SDK `resources.calendars.list` — every calendar resource in the
  /// Workspace tenant, with capacity, building and floor.
  ///
  /// Returns null when the tenant will not answer, so the caller can tell "no
  /// permission" from "no rooms". Two ordinary reasons to land there, neither of
  /// them an error worth surfacing:
  ///  * the signed-in user is not a Workspace administrator — this endpoint is
  ///    admin-only, and there is no user-level equivalent;
  ///  * the token predates `admin.directory.resource.calendar.readonly`, which
  ///    is only requested for accounts already known to be on a Workspace
  ///    domain (see `GmailAuthService`), so it is absent for every account added
  ///    before the room picker existed.
  ///
  /// Absolute URL because the Admin SDK lives on a different host to the
  /// Calendar API this client is based at; the auth interceptor still applies.
  Future<List<MeetingRoom>?> _fetchRoomsFromDirectory() async {
    final rooms = <MeetingRoom>[];
    String? pageToken;

    for (var page = 0; page < _maxRoomPages; page++) {
      final Response<Map<String, dynamic>> response;
      try {
        response = await _dio.get<Map<String, dynamic>>(
          'https://admin.googleapis.com/admin/directory/v1/customer/my_customer'
          '/resources/calendars',
          queryParameters: {
            'maxResults': _roomPageSize,
            if (pageToken != null) 'pageToken': pageToken,
          },
        );
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        if (status == 401 || status == 403 || status == 404) {
          debugPrint('[GoogleCalendar] resource directory denied ($status) — '
              'the account is either not a Workspace admin or predates the '
              'admin.directory.resource.calendar.readonly scope; falling back '
              'to subscribed resource calendars.');
          return null;
        }
        if (rooms.isEmpty) return null;
        debugPrint('[GoogleCalendar] room paging stopped early: ${e.message}');
        return rooms;
      }

      final items = response.data?['items'] as List<dynamic>? ?? const [];
      rooms.addAll(items
          .cast<Map<String, dynamic>>()
          .map(_roomFromCalendarResource)
          .whereType<MeetingRoom>());

      pageToken = response.data?['nextPageToken'] as String?;
      if (pageToken == null || pageToken.isEmpty) return rooms;
    }
    return rooms;
  }

  /// The rooms this user has added to their own calendar list, identified by
  /// Google's resource-calendar address suffix.
  ///
  /// The fallback for the (common) non-admin case. It needs only the
  /// `calendar.calendarlist.readonly` scope the app already holds, but it can
  /// only see rooms the user — or a domain-wide default — has subscribed to, and
  /// it carries no capacity or building. An empty result here means the user has
  /// no room calendars added, which is a real and unremarkable state.
  Future<List<MeetingRoom>> _fetchRoomsFromCalendarList() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/users/me/calendarList',
        queryParameters: {'maxResults': 250, 'minAccessRole': 'freeBusyReader'},
      );
      final items = response.data?['items'] as List<dynamic>? ?? const [];
      return items
          .cast<Map<String, dynamic>>()
          .where((c) => (c['id'] as String? ?? '')
              .toLowerCase()
              .endsWith(_resourceCalendarSuffix))
          .map((c) {
            final id = c['id'] as String;
            final name = (c['summaryOverride'] as String?) ??
                (c['summary'] as String?) ??
                id;
            return MeetingRoom(email: id, displayName: name);
          })
          .toList();
    } on DioException catch (e) {
      // Nothing left to try. An empty dropdown must not stop the user saving.
      debugPrint('[GoogleCalendar] calendarList unavailable: ${e.message}');
      return const [];
    }
  }

  MeetingRoom? _roomFromCalendarResource(Map<String, dynamic> json) {
    final email = json['resourceEmail'] as String? ?? '';
    if (email.isEmpty) return null;
    // `generatedResourceName` is what Google Calendar itself shows — it folds in
    // the building and floor ("SYD-2-Boardroom (10)"). Prefer the plain name and
    // let building/floor render as the dropdown's own subtitle instead.
    final name = (json['resourceName'] as String?)?.trim();
    return MeetingRoom(
      email: email,
      displayName: name != null && name.isNotEmpty
          ? name
          : (json['generatedResourceName'] as String? ?? email),
      capacity: json['capacity'] as int?,
      building: json['buildingId'] as String?,
      floorLabel: json['floorName'] as String?,
    );
  }

  /// The directory name for a booked room, falling back to the address' local
  /// part when the room directory was never read. A Google resource address'
  /// local part is an opaque id, so the bare address is the better fallback.
  String _roomDisplayName(String email) =>
      _roomsByEmail[email.toLowerCase()]?.displayName ?? email;

  /// Whether the free-text location is just a room's name repeated, which is
  /// what happens when the form shows the room in the field and also books it.
  bool _locationNamesARoom(String location, List<String> roomEmails) {
    final needle = location.trim().toLowerCase();
    return roomEmails.any((e) =>
        _roomDisplayName(e).trim().toLowerCase() == needle ||
        e.trim().toLowerCase() == needle);
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
    List<String> roomEmails = const [],
    CalendarRecurrence? recurrence,
    int? reminderMinutes,
    bool isOnlineMeeting = false,
    bool isUpdate = false,
  }) {
    // Google has no structured location — `location` is one free-text string —
    // so a booked room has to be named in it as well as invited, or the event
    // reads as having no place at all. Rooms first, then any typed-in text.
    //
    // Except when the location *is* a join link. `_parseLocation` hands the
    // conference URL up as the location, so that is what comes back down here
    // for an online meeting; prefixing a room name to it would leave a location
    // that no longer starts with `https://`, which is the signal the whole app
    // uses for "this meeting is joinable" (`_isJoinable`, the Join Meeting menu
    // item, the tile's join chip). Adding a room to a Meet would silently take
    // the join button away. The room is booked as a resource attendee either
    // way, and both Google's UI and ours show it from there.
    final keepJoinUrl = isOnlineMeetingUrl(location);
    final locationText = keepJoinUrl
        ? location!.trim()
        : [
            ...roomEmails.map(_roomDisplayName),
            if (location != null &&
                location.isNotEmpty &&
                !_locationNamesARoom(location, roomEmails))
              location,
          ].join(', ');

    final body = <String, dynamic>{
      'summary': subject,
      // Sent even when empty, unlike most fields here: on a PATCH an omitted
      // field means "leave unchanged", so clearing the location or releasing the
      // last room would otherwise not take effect server-side.
      'location': locationText,
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

    // `resource: true` is what makes Google run the room's booking policy —
    // auto-accepting or declining on conflict — instead of treating the room
    // calendar as a person who was invited. Always sent for the same
    // PATCH-semantics reason as `location` above.
    //
    // The organizer is sent as an attendee of their own meeting. Google's web
    // UI does that for every event it creates; the API does not — `organizer`
    // is set from the calendar posted to, and `attendees` is taken verbatim.
    // Every guest list is rendered from `attendees` alone, on both sides, so
    // an organizer left out of it does not appear as a guest of their own
    // meeting anywhere — not in the invitation, not beside the acceptances
    // coming back, and not in this app (`_parseEvent` already notes Google
    // "inconsistently omits the organizer from attendees"; this is the half
    // of that we cause). `responseStatus` is explicit because the default is
    // `needsAction`, which would feed `_parseStatus` and make our own meetings
    // stop counting as busy for conflict detection.
    //
    // Only when somebody else is involved: an event with no guests and no
    // rooms must stay attendee-less, or every private appointment becomes a
    // one-guest meeting. `organizer`/`self` are output-only and left to Google.
    // Self is *replaced* rather than skipped when the caller already names it.
    // A roster read back off the server now contains the organizer — which is
    // exactly what `CalendarBloc`'s drag-to-reschedule rebuilds its
    // `attendeeEmails` from — and passing that entry through the guest loop
    // would send it bare, i.e. back to `needsAction` and out of the busy count.
    final selfEmail = _accountEmail.trim();
    final self = selfEmail.toLowerCase();
    final guests =
        attendeeEmails.where((e) => e.trim().toLowerCase() != self).toList();
    final invited = [...attendeeEmails, ...roomEmails]
        .where((e) => e.trim().isNotEmpty);

    body['attendees'] = [
      if (invited.isNotEmpty && selfEmail.isNotEmpty)
        {'email': selfEmail, 'responseStatus': 'accepted'},
      for (final e in guests) {'email': e},
      for (final e in roomEmails) {'email': e, 'resource': true},
    ];

    if (recurrence != null) {
      body['recurrence'] = [buildRRule(recurrence)];
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

  /// Inverse of [buildRRule]: parses an iCalendar RRULE line into a
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
              // Google flags a booked room on the attendee itself. Fall back to
              // the resource-calendar address suffix for a room added by another
              // client that omitted the flag.
              isResource: a['resource'] as bool? ??
                  (a['email'] as String? ?? '')
                      .toLowerCase()
                      .endsWith(_resourceCalendarSuffix),
            ))
        .where((a) => a.email.isNotEmpty)
        .toList();

    final description = json['description'] as String?;
    final split = splitMeetingLocation(
      rawLocation: json['location'] as String?,
      onlineMeetingUrl: _conferenceJoinUrl(json),
      description: description,
    );
    return CalendarEventModel(
      id: json['id'] as String? ?? '',
      subject: json['summary'] as String? ?? '(No title)',
      start: start,
      end: end,
      isAllDay: isAllDay,
      iCalUid: json['iCalUID'] as String?,
      location: split.location,
      onlineMeetingUrl: split.onlineMeetingUrl,
      bodyPreview: description,
      status: status,
      participation: participation,
      isOrganizer: isOrganizer,
      organizerEmail: organizerEmail,
      organizerName: organizerMap?['displayName'] as String?,
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
    // The same unwrap for a proactive refresh that never reached the token
    // endpoint: offline is neither a credential problem nor a server error, and
    // falling through would replace it with Dio's own boilerplate message.
    if (e.error is NetworkException) return e.error as NetworkException;

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

