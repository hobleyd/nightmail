import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/error/exceptions.dart';
import '../../../domain/entities/local_attachment.dart';
import '../../../domain/entities/attendee_availability.dart';
import '../../../domain/entities/email.dart';
import '../../../domain/entities/calendar_recurrence.dart';
import '../../../domain/entities/meeting_invite.dart';
import '../../../domain/entities/todo_task.dart';
import '../../../domain/usecases/create_calendar_event.dart';
import '../../../domain/usecases/update_calendar_event.dart';
import '../../../infrastructure/http/graph_http_client.dart';
import '../../models/calendar_event_model.dart';
import '../../models/email_folder_model.dart';
import '../../models/email_model.dart';
import '../../models/mail_delta_result.dart';
import '../../models/todo_task_attachment_model.dart';
import '../../models/todo_task_list_model.dart';
import '../../models/todo_task_model.dart';
import 'calendar_remote_datasource.dart';
import 'email_remote_datasource.dart';
import 'graph_delta_datasource.dart';
import 'tasks_remote_datasource.dart';

final _emailListSelect = [
  'id',
  'subject',
  'from',
  'toRecipients',
  'ccRecipients',
  'bodyPreview',
  'isRead',
  'receivedDateTime',
  'sentDateTime',
  'importance',
  'conversationId',
  'hasAttachments',
  'parentFolderId',
].join(',');


class GraphApiDatasourceImpl
    implements
        EmailRemoteDatasource,
        CalendarRemoteDatasource,
        TasksRemoteDatasource,
        GraphDeltaDatasource {
  GraphApiDatasourceImpl({required GraphHttpClient client})
      : _dio = client.dio;

  @visibleForTesting
  GraphApiDatasourceImpl.withDio(this._dio);

  final Dio _dio;

  @override
  Future<List<EmailModel>> getEmails({
    String? folderId,
    int top = 25,
    int skip = 0,
    String? filter,
    String orderBy = 'receivedDateTime desc',
  }) async {
    final path = folderId != null
        ? '/me/mailFolders/$folderId/messages'
        : '/me/messages';

    try {
      final response = await _dio.get<Map<String, dynamic>>(
        path,
        queryParameters: {
          '\$top': top,
          '\$skip': skip,
          '\$select': _emailListSelect,
          '\$orderby': orderBy,
          '\$filter': ?filter,
        },
      );

      final data = response.data;
      if (data == null) return [];

      final value = data['value'] as List<dynamic>? ?? [];
      final folderEmails = value
          .map((e) => EmailModel.fromJson(e as Map<String, dynamic>))
          .toList();

      if (folderEmails.isEmpty) return [];

      // For each unique conversationId found in this folder, fetch all messages
      // that share that conversationId across every folder.  This surfaces
      // cross-folder replies (e.g. emails moved to sub-folders) inside the
      // same conversation view without changing which conversations appear.
      final conversationIds = folderEmails
          .map((e) => e.conversationId)
          .whereType<String>()
          .toSet();

      if (conversationIds.isEmpty) return folderEmails;

      final crossFolderFutures = conversationIds.map(_fetchConversationMessages);
      final crossFolderBatches = await Future.wait(crossFolderFutures);

      // Merge: folder emails + cross-folder emails, de-duplicated by id.
      final byId = <String, EmailModel>{};
      for (final e in folderEmails) {
        byId[e.id] = e;
      }
      for (final batch in crossFolderBatches) {
        for (final e in batch) {
          byId.putIfAbsent(e.id, () => e);
        }
      }
      return byId.values.toList();
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  Future<List<EmailModel>> _fetchConversationMessages(
      String conversationId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/me/messages',
        queryParameters: {
          '\$filter': "conversationId eq '$conversationId'",
          '\$select': _emailListSelect,
          '\$top': 50,
        },
      );
      final value =
          (response.data?['value'] as List<dynamic>? ?? []);
      return value
          .map((e) => EmailModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<List<EmailModel>> searchEmails({
    String? folderId,
    required String query,
    int top = 50,
  }) async {
    // Convert has:attachment to KQL; other tokens (from:, to:, subject:) pass through.
    final kql = query.replaceAllMapped(
      RegExp(r'\bhas:attachment\b', caseSensitive: false),
      (_) => 'hasAttachments:true',
    );

    try {
      // Always search globally across the whole mailbox. Per-folder $search on
      // /me/mailFolders/{id}/messages silently returns empty on many tenants,
      // and Graph uses inconsistent ID formats (AQMk vs AAMk) that break
      // client-side parentFolderId filtering. Global search matches Outlook's
      // default behaviour.
      final response = await _dio.get<Map<String, dynamic>>(
        '/me/messages',
        queryParameters: {
          '\$top': top,
          '\$select': _emailListSelect,
          '\$search': '"$kql"',
        },
      );
      final value = response.data?['value'] as List<dynamic>? ?? [];
      return value
          .map((e) => EmailModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<EmailModel> getEmail(String id) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/me/messages/$id',
        queryParameters: {
          // No $select here: Graph omits @odata.type for derived types
          // (eventMessage) on single-resource GETs when $select is present.
          // Returning all default fields ensures the type annotation is present.
          '\$expand': r'attachments($select=id,name,contentType,size,isInline)',
        },
        // Return eventMessage startDateTime/endDateTime in UTC so we can use
        // them directly without Windows-timezone-name conversion.
        options: Options(headers: {'Prefer': 'outlook.timezone="UTC"'}),
      );

      if (response.data == null) {
        throw ServerException(
            message: 'Empty response for message $id', statusCode: 200);
      }

      // contentId and contentBytes are on the fileAttachment subtype and
      // cannot be requested via $select in $expand (which targets the base
      // attachment type). Fetch each inline attachment individually to get
      // those fields, then merge before parsing.
      final emailData = Map<String, dynamic>.from(response.data!);
      final rawAttachments = emailData['attachments'] as List<dynamic>?;
      if (rawAttachments != null) {
        final enriched = <Map<String, dynamic>>[];
        for (final a in rawAttachments.cast<Map<String, dynamic>>()) {
          if (a['isInline'] == true) {
            final attachId = a['id'] as String?;
            if (attachId != null) {
              try {
                final detail = await _dio.get<Map<String, dynamic>>(
                  '/me/messages/$id/attachments/$attachId',
                );
                if (detail.data != null) {
                  enriched.add({...a, ...detail.data!});
                  continue;
                }
              } catch (_) {}
            }
          }
          enriched.add(a);
        }
        emailData['attachments'] = enriched;
      }

      return EmailModel.fromJson(emailData);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<EmailModel> updateEmailReadStatus({
    required String id,
    required bool isRead,
  }) async {
    try {
      final response = await _dio.patch<Map<String, dynamic>>(
        '/me/messages/$id',
        data: {'isRead': isRead},
        queryParameters: {'\$select': _emailListSelect},
      );

      if (response.data == null) {
        throw ServerException(
            message: 'Empty response when updating message $id', statusCode: 200);
      }

      return EmailModel.fromJson(response.data!);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<List<EmailFolderModel>> getMailFolders() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/me/mailFolders',
        queryParameters: {
          '\$select':
              'id,displayName,totalItemCount,unreadItemCount,parentFolderId,isHidden,childFolderCount',
          '\$top': 100,
        },
      );

      final data = response.data;
      if (data == null) return [];

      final value = data['value'] as List<dynamic>? ?? [];
      return value
          .map((e) => EmailFolderModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<List<EmailFolderModel>> getChildFolders(String parentFolderId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/me/mailFolders/$parentFolderId/childFolders',
        queryParameters: {
          '\$select':
              'id,displayName,totalItemCount,unreadItemCount,parentFolderId,isHidden,childFolderCount',
          '\$top': 100,
        },
      );

      final data = response.data;
      if (data == null) return [];

      final value = data['value'] as List<dynamic>? ?? [];
      return value
          .map((e) => EmailFolderModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<List<CalendarEventModel>> getCalendarEvents({
    required DateTime startDateTime,
    required DateTime endDateTime,
  }) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/me/calendarView',
        queryParameters: {
          'startDateTime': startDateTime.toUtc().toIso8601String(),
          'endDateTime': endDateTime.toUtc().toIso8601String(),
          '\$select':
              'id,subject,start,end,isAllDay,location,onlineMeeting,bodyPreview,showAs,isOrganizer,attendees,recurrence',
          '\$top': 100,
        },
        options: Options(
          headers: {'Prefer': 'outlook.timezone="UTC"'},
        ),
      );

      final data = response.data;
      if (data == null) return [];

      final value = data['value'] as List<dynamic>? ?? [];
      return value
          .map((e) => CalendarEventModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<CalendarEventModel> createCalendarEvent({
    required CreateCalendarEventParams params,
  }) async {
    try {
      final body = _buildGraphEventBody(
        subject: params.subject,
        start: params.start,
        end: params.end,
        isAllDay: params.isAllDay,
        timezone: params.timezone,
        location: params.location,
        description: params.description,
        attendeeEmails: params.attendeeEmails,
        recurrence: params.recurrence,
        isTeamsMeeting: params.isTeamsMeeting,
        reminderMinutes: params.reminderMinutes,
      );

      final response = await _dio.post<Map<String, dynamic>>(
        '/me/events',
        data: body,
      );

      if (response.data == null) {
        throw const ServerException(message: 'Empty response from server');
      }
      return CalendarEventModel.fromJson(response.data!);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<CalendarEventModel> updateCalendarEvent({
    required UpdateCalendarEventParams params,
  }) async {
    try {
      final body = _buildGraphEventBody(
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

      final response = await _dio.patch<Map<String, dynamic>>(
        '/me/events/${params.id}',
        data: body,
      );

      if (response.data == null) {
        throw const ServerException(message: 'Empty response from server');
      }
      return CalendarEventModel.fromJson(response.data!);
    } on DioException catch (e) {
      throw _mapDioException(e);
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
    final endpoint = switch (response) {
      MeetingInviteResponseType.accept => 'accept',
      MeetingInviteResponseType.tentative => 'tentativelyAccept',
      MeetingInviteResponseType.decline => 'decline',
    };
    final body = {'sendResponse': true, 'comment': ''};

    // 1. Try the message-level action (works for unprocessed eventMessages).
    try {
      await _dio.post<void>('/me/messages/$emailId/$endpoint', data: body);
      return;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) throw _mapDioException(e);
      // 400/404 means action unavailable on this message type — fall through.
    }

    // 2. Navigate from message to its linked calendar event.
    String? eventId;
    try {
      final eventResp = await _dio.get<Map<String, dynamic>>(
        '/me/messages/$emailId/event',
        queryParameters: {'\$select': 'id,isOrganizer'},
      );
      final isOrganizer = eventResp.data?['isOrganizer'] as bool? ?? false;
      if (isOrganizer) return; // Organiser has no response to send.
      eventId = eventResp.data?['id'] as String?;
    } on DioException {
      // Navigation unavailable (cross-tenant invite, or already processed).
      // Fall through to the calendar-search approach below.
    }

    if (eventId != null) {
      try {
        await _dio.post<void>('/me/events/$eventId/$endpoint', data: body);
        return;
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        if (status == 401 || status == 403) throw _mapDioException(e);
        // Event action also failed — fall through to calendar search.
      }
    }

    // 3. Last resort: search the calendar by the meeting's start time and
    //    accept whichever event in that window is still pending a response.
    if (meetingStart == null) {
      throw const ServerException(
          message: 'Could not locate the calendar event for this invite');
    }
    try {
      // meetingStart is exact UTC (Graph returned it via Prefer: UTC header).
      // Use a small window to avoid picking up adjacent meetings.
      final windowStart = meetingStart.subtract(const Duration(minutes: 30));
      final windowEnd = meetingStart.add(const Duration(hours: 2));
      String fmt(DateTime d) => d.toUtc().toIso8601String();
      final calResp = await _dio.get<Map<String, dynamic>>(
        '/me/calendarView',
        queryParameters: {
          'startDateTime': fmt(windowStart),
          'endDateTime': fmt(windowEnd),
          '\$select': 'id,isOrganizer,responseStatus',
          '\$top': 50,
        },
        options: Options(headers: {'Prefer': 'outlook.timezone="UTC"'}),
      );
      final events = (calResp.data?['value'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      // Exclude events where the user is the organiser — they have no
      // response to send. Accept any attendee event regardless of current
      // responseStatus: Exchange may have auto-set it to accepted/tentative,
      // and the user is explicitly overriding that here.
      final attendeeEvents =
          events.where((e) => e['isOrganizer'] != true).toList();

      if (attendeeEvents.isEmpty) {
        throw const ServerException(
            message: 'No meeting found in your calendar at that time');
      }
      final targetId = attendeeEvents.first['id'] as String;
      await _dio.post<void>('/me/events/$targetId/$endpoint', data: body);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<void> cancelCalendarEvent({required String eventId}) async {
    try {
      await _dio.post<void>(
        '/me/events/$eventId/cancel',
        data: {'comment': ''},
      );
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<void> declineCalendarEvent({
    required String eventId,
    String? userEmail,
  }) async {
    try {
      await _dio.post<void>(
        '/me/events/$eventId/decline',
        data: {'sendResponse': true, 'comment': ''},
      );
    } on DioException catch (e) {
      throw _mapDioException(e);
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
    // Send the proposed time as the attendee's local wall-clock time paired with
    // their IANA timezone. This avoids Exchange doing a UTC→local conversion on
    // its end (which can apply the wrong DST offset) and lets Exchange store the
    // time directly as specified.
    final tz = timezone ?? 'UTC';
    try {
      await _dio.post<void>(
        '/me/events/$eventId/decline',
        data: {
          'sendResponse': true,
          'comment': message ?? '',
          'proposedNewTime': {
            'start': {
              'dateTime': _formatLocalDateTime(newStart),
              'timeZone': tz,
            },
            'end': {
              'dateTime': _formatLocalDateTime(newEnd),
              'timeZone': tz,
            },
          },
        },
      );
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  Map<String, dynamic> _buildGraphEventBody({
    required String subject,
    required DateTime start,
    required DateTime end,
    required bool isAllDay,
    required String timezone,
    String? location,
    String? description,
    List<String> attendeeEmails = const [],
    CalendarRecurrence? recurrence,
    bool isTeamsMeeting = false,
    int? reminderMinutes,
  }) {
    final body = <String, dynamic>{
      'subject': subject,
      'isAllDay': isAllDay,
      'isReminderOn': reminderMinutes != null,
      if (reminderMinutes != null) 'reminderMinutesBeforeStart': reminderMinutes,
      if (isTeamsMeeting) 'isOnlineMeeting': true,
    };

    if (description != null && description.isNotEmpty) {
      body['body'] = {'contentType': 'text', 'content': description};
    }

    if (isAllDay) {
      body['start'] = {
        'dateTime': _formatLocalDateTime(start),
        'timeZone': timezone,
      };
      body['end'] = {
        'dateTime': _formatLocalDateTime(end),
        'timeZone': timezone,
      };
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

    if (location != null && location.isNotEmpty) {
      body['location'] = {'displayName': location};
    }

    if (attendeeEmails.isNotEmpty) {
      body['attendees'] = attendeeEmails
          .map((e) => {
                'emailAddress': {'address': e},
                'type': 'required',
              })
          .toList();
    }

    if (recurrence != null) {
      body['recurrence'] = _buildGraphRecurrence(recurrence, start);
    }

    return body;
  }

  Map<String, dynamic> _buildGraphRecurrence(
      CalendarRecurrence r, DateTime startDate) {
    final patternType = switch (r.frequency) {
      RecurrenceFrequency.daily => 'daily',
      RecurrenceFrequency.weekly => 'weekly',
      RecurrenceFrequency.monthly => 'absoluteMonthly',
      RecurrenceFrequency.yearly => 'absoluteYearly',
    };

    final pattern = <String, dynamic>{
      'type': patternType,
      'interval': r.interval,
    };

    if (r.frequency == RecurrenceFrequency.weekly &&
        r.daysOfWeek != null &&
        r.daysOfWeek!.isNotEmpty) {
      const dayNames = ['', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
      pattern['daysOfWeek'] = r.daysOfWeek!.map((d) => dayNames[d]).toList();
    }

    final local = startDate.toLocal();
    final startDateStr =
        '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';

    Map<String, dynamic> range;
    if (r.endDate != null) {
      final ed = r.endDate!.toLocal();
      final endDateStr =
          '${ed.year.toString().padLeft(4, '0')}-${ed.month.toString().padLeft(2, '0')}-${ed.day.toString().padLeft(2, '0')}';
      range = {'type': 'endDate', 'startDate': startDateStr, 'endDate': endDateStr};
    } else if (r.count != null) {
      range = {'type': 'numbered', 'startDate': startDateStr, 'numberOfOccurrences': r.count};
    } else {
      range = {'type': 'noEnd', 'startDate': startDateStr};
    }

    return {'pattern': pattern, 'range': range};
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

  Future<({String displayName, String email})> fetchUserProfile() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/me',
        queryParameters: {'\$select': 'displayName,mail,userPrincipalName'},
      );
      final data = response.data;
      if (data == null) throw const ServerException(message: 'Empty response');
      final email = data['mail'] as String? ??
          data['userPrincipalName'] as String? ??
          '';
      final displayName = data['displayName'] as String? ?? '';
      return (displayName: displayName, email: email);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<void> sendEmail({
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    try {
      final attachmentsList = await _buildGraphAttachments(newAttachments);
      await _dio.post<void>(
        '/me/sendMail',
        data: {
          'message': {
            'subject': subject,
            'body': {
              'contentType': 'html',
              'content': const HtmlEscape()
                  .convert(body)
                  .replaceAll('\n', '<br>'),
            },
            'toRecipients': toAddresses
                .map((a) => {'emailAddress': {'address': _bareEmail(a)}})
                .toList(),
            if (ccAddresses.isNotEmpty)
              'ccRecipients': ccAddresses
                  .map((a) => {'emailAddress': {'address': _bareEmail(a)}})
                  .toList(),
            if (attachmentsList.isNotEmpty) 'attachments': attachmentsList,
          },
          'saveToSentItems': true,
        },
      );
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<void> replyToEmail({
    required String messageId,
    required String comment,
    bool replyAll = false,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    try {
      if (newAttachments.isEmpty) {
        final path = replyAll
            ? '/me/messages/$messageId/replyAll'
            : '/me/messages/$messageId/reply';
        await _dio.post<void>(path, data: {
          'message': {
            'body': {
              'contentType': bodyType == EmailBodyType.html ? 'html' : 'text',
              'content': comment,
            },
          },
        });
      } else {
        // Create a draft reply, attach files, then send.
        final createPath = replyAll
            ? '/me/messages/$messageId/createReplyAll'
            : '/me/messages/$messageId/createReply';
        final draftResp = await _dio.post<Map<String, dynamic>>(
          createPath,
          data: {
            'message': {
              'body': {
                'contentType': bodyType == EmailBodyType.html ? 'html' : 'text',
                'content': comment,
              },
            },
          },
        );
        final draftId = draftResp.data?['id'] as String?;
        if (draftId == null) {
          throw const ServerException(message: 'No draft ID in reply response');
        }
        await _addAttachmentsToDraft(draftId, newAttachments);
        await _dio.post<void>('/me/messages/$draftId/send');
      }
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<void> forwardEmail({
    required String messageId,
    required List<String> toAddresses,
    required String comment,
    List<String> excludedAttachmentIds = const [],
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    try {
      // Use message.body instead of comment so Graph doesn't auto-append the
      // original (which would double-quote since we've already embedded it).
      final messageBody = {
        'body': {
          'contentType': bodyType == EmailBodyType.html ? 'html' : 'text',
          'content': comment,
        },
      };
      final toRecipients = toAddresses
          .map((a) => {'emailAddress': {'address': _bareEmail(a)}})
          .toList();

      if (newAttachments.isEmpty) {
        await _dio.post<void>(
          '/me/messages/$messageId/forward',
          data: {
            'message': messageBody,
            'toRecipients': toRecipients,
          },
        );
      } else {
        // Create a forward draft, attach files, then send.
        final draftResp = await _dio.post<Map<String, dynamic>>(
          '/me/messages/$messageId/createForward',
          data: {
            'message': messageBody,
            'toRecipients': toRecipients,
          },
        );
        final draftId = draftResp.data?['id'] as String?;
        if (draftId == null) {
          throw const ServerException(message: 'No draft ID in forward response');
        }
        await _addAttachmentsToDraft(draftId, newAttachments);
        await _dio.post<void>('/me/messages/$draftId/send');
      }
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  Future<List<Map<String, dynamic>>> _buildGraphAttachments(
      List<LocalAttachment> attachments) async {
    return [
      for (final att in attachments)
        {
          '@odata.type': '#microsoft.graph.fileAttachment',
          'name': att.name,
          'contentType': att.mimeType,
          'contentBytes': base64.encode(att.bytes),
        }
    ];
  }

  Future<void> _addAttachmentsToDraft(
      String draftId, List<LocalAttachment> attachments) async {
    for (final att in attachments) {
      await _dio.post<void>('/me/messages/$draftId/attachments', data: {
        '@odata.type': '#microsoft.graph.fileAttachment',
        'name': att.name,
        'contentType': att.mimeType,
        'contentBytes': base64.encode(att.bytes),
      });
    }
  }

  @override
  Future<void> moveEmail(String id, String destinationFolderId) async {
    try {
      await _dio.post<void>(
        '/me/messages/$id/move',
        data: {'destinationId': destinationFolderId},
      );
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<void> reportJunk(String id) async {
    try {
      await _dio.post<void>(
        '/me/messages/$id/move',
        data: {'destinationId': 'junkemail'},
      );
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<void> deleteEmail(String id) async {
    try {
      await _dio.post<void>(
        '/me/messages/$id/move',
        data: {'destinationId': 'deleteditems'},
      );
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<void> emptyFolder(String folderId,
      {bool permanentDelete = false}) async {
    try {
      const pageSize = 100;
      while (true) {
        // /mailFolders/{id}/messages returns only messages directly in this
        // folder — child folders and their contents are never included.
        final response = await _dio.get<Map<String, dynamic>>(
          '/me/mailFolders/$folderId/messages',
          queryParameters: {'\$top': pageSize, '\$select': 'id'},
        );
        final messages = ((response.data?['value'] as List<dynamic>?) ?? [])
            .cast<Map<String, dynamic>>();
        if (messages.isEmpty) break;

        for (final msg in messages) {
          final id = msg['id'] as String;
          if (permanentDelete) {
            await _dio.post<void>('/me/messages/$id/permanentDelete');
          } else {
            await _dio.post<void>(
              '/me/messages/$id/move',
              data: {'destinationId': 'deleteditems'},
            );
          }
        }

        if (messages.length < pageSize) break;
      }
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<Uint8List> downloadAttachment(
      String messageId, String attachmentId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/me/messages/$messageId/attachments/$attachmentId',
      );
      final data = response.data;
      final contentBytes = data?['contentBytes'] as String?;
      if (contentBytes == null || contentBytes.isEmpty) {
        throw ServerException(
            message: 'Attachment has no content', statusCode: 200);
      }
      return base64Decode(contentBytes);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<List<TodoTaskListModel>> getTaskLists() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/me/todo/lists',
        queryParameters: {'\$top': 100},
      );
      final value = (response.data?['value'] as List<dynamic>?) ?? [];
      return value
          .map((e) => TodoTaskListModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<List<TodoTaskModel>> getTasks(
    String listId, {
    bool includeCompleted = false,
  }) async {
    try {
      final params = <String, dynamic>{
        '\$top': 200,
        '\$orderby': 'createdDateTime desc',
      };
      if (!includeCompleted) {
        params['\$filter'] = "status ne 'completed'";
      }
      final response = await _dio.get<Map<String, dynamic>>(
        '/me/todo/lists/$listId/tasks',
        queryParameters: params,
      );
      final value = (response.data?['value'] as List<dynamic>?) ?? [];
      return value
          .map((e) => TodoTaskModel.fromJson(
                e as Map<String, dynamic>,
                listId: listId,
              ))
          .toList();
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<TodoTaskModel> createTask({
    required String listId,
    required String title,
    String? body,
    DateTime? dueDate,
    TodoTaskImportance importance = TodoTaskImportance.normal,
  }) async {
    try {
      final data = <String, dynamic>{
        'title': title,
        'importance': switch (importance) {
          TodoTaskImportance.high => 'high',
          TodoTaskImportance.low => 'low',
          TodoTaskImportance.normal => 'normal',
        },
      };
      if (body != null && body.isNotEmpty) {
        data['body'] = {'content': body, 'contentType': 'text'};
      }
      if (dueDate != null) {
        final d = dueDate.toLocal();
        final dateStr =
            '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}T00:00:00';
        data['dueDateTime'] = {'dateTime': dateStr, 'timeZone': 'UTC'};
      }
      final response = await _dio.post<Map<String, dynamic>>(
        '/me/todo/lists/$listId/tasks',
        data: data,
      );
      if (response.data == null) {
        throw const ServerException(message: 'Empty response from server');
      }
      return TodoTaskModel.fromJson(response.data!, listId: listId);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<TodoTaskModel> updateTaskStatus({
    required String listId,
    required String taskId,
    required TodoTaskStatus status,
  }) async {
    try {
      final statusStr = switch (status) {
        TodoTaskStatus.completed => 'completed',
        TodoTaskStatus.inProgress => 'inProgress',
        TodoTaskStatus.waitingOnOthers => 'waitingOnOthers',
        TodoTaskStatus.deferred => 'deferred',
        TodoTaskStatus.notStarted => 'notStarted',
      };
      final response = await _dio.patch<Map<String, dynamic>>(
        '/me/todo/lists/$listId/tasks/$taskId',
        data: {'status': statusStr},
      );
      if (response.data == null) {
        throw const ServerException(message: 'Empty response from server');
      }
      return TodoTaskModel.fromJson(response.data!, listId: listId);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<TodoTaskModel> updateTaskDueDate({
    required String listId,
    required String taskId,
    required DateTime? dueDate,
  }) async {
    try {
      final data = <String, dynamic>{};
      if (dueDate == null) {
        data['dueDateTime'] = null;
      } else {
        final d = dueDate.toLocal();
        final dateStr =
            '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}T00:00:00';
        data['dueDateTime'] = {'dateTime': dateStr, 'timeZone': 'UTC'};
      }
      final response = await _dio.patch<Map<String, dynamic>>(
        '/me/todo/lists/$listId/tasks/$taskId',
        data: data,
      );
      if (response.data == null) {
        throw const ServerException(message: 'Empty response from server');
      }
      return TodoTaskModel.fromJson(response.data!, listId: listId);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Email raw bytes
  // ---------------------------------------------------------------------------

  @override
  Future<Uint8List> getRawEmailBytes(String id) async {
    try {
      final response = await _dio.get<List<int>>(
        '/me/messages/$id/\$value',
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(response.data ?? []);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Task attachments
  // ---------------------------------------------------------------------------

  static const int _inlineAttachmentLimit = 3 * 1024 * 1024; // 3 MB

  @override
  Future<TodoTaskAttachmentModel> attachEmailToTask({
    required String listId,
    required String taskId,
    required String fileName,
    required Uint8List emlBytes,
  }) async {
    try {
      if (emlBytes.length <= _inlineAttachmentLimit) {
        return _attachInline(
          listId: listId,
          taskId: taskId,
          fileName: fileName,
          emlBytes: emlBytes,
        );
      } else {
        return _attachViaUploadSession(
          listId: listId,
          taskId: taskId,
          fileName: fileName,
          emlBytes: emlBytes,
        );
      }
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  Future<TodoTaskAttachmentModel> _attachInline({
    required String listId,
    required String taskId,
    required String fileName,
    required Uint8List emlBytes,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/me/todo/lists/$listId/tasks/$taskId/attachments',
      data: {
        '@odata.type': '#microsoft.graph.taskFileAttachment',
        'name': fileName,
        'contentType': 'message/rfc822',
        'contentBytes': base64Encode(emlBytes),
        'size': emlBytes.length,
      },
    );
    if (response.data == null) {
      throw const ServerException(message: 'Empty response from server');
    }
    return TodoTaskAttachmentModel.fromJson(response.data!);
  }

  Future<TodoTaskAttachmentModel> _attachViaUploadSession({
    required String listId,
    required String taskId,
    required String fileName,
    required Uint8List emlBytes,
  }) async {
    final sessionResponse = await _dio.post<Map<String, dynamic>>(
      '/me/todo/lists/$listId/tasks/$taskId/attachments/createUploadSession',
      data: {
        'attachmentItem': {
          '@odata.type': '#microsoft.graph.fileAttachmentUploadProperties',
          'attachmentType': 'file',
          'contentType': 'message/rfc822',
          'name': fileName,
          'size': emlBytes.length,
        },
      },
    );
    final uploadUrl = sessionResponse.data?['uploadUrl'] as String?;
    if (uploadUrl == null) {
      throw const ServerException(message: 'No upload URL returned');
    }

    // Upload using a plain Dio instance — the session URL is pre-authorized.
    final uploadDio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 60),
      receiveTimeout: const Duration(seconds: 60),
    ));
    final size = emlBytes.length;
    final uploadResponse = await uploadDio.put<Map<String, dynamic>>(
      uploadUrl,
      data: Stream.fromIterable([emlBytes]),
      options: Options(
        headers: {
          'Content-Range': 'bytes 0-${size - 1}/$size',
          'Content-Length': size,
          'Content-Type': 'message/rfc822',
        },
        responseType: ResponseType.json,
      ),
    );

    if (uploadResponse.data == null) {
      throw const ServerException(message: 'Empty upload response');
    }
    return TodoTaskAttachmentModel.fromJson(uploadResponse.data!);
  }

  @override
  Future<List<TodoTaskAttachmentModel>> getTaskAttachments({
    required String listId,
    required String taskId,
  }) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/me/todo/lists/$listId/tasks/$taskId/attachments',
      );
      final value = (response.data?['value'] as List<dynamic>?) ?? [];
      return value
          .map((e) =>
              TodoTaskAttachmentModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<Uint8List> downloadTaskAttachment({
    required String listId,
    required String taskId,
    required String attachmentId,
  }) async {
    try {
      final response = await _dio.get<List<int>>(
        '/me/todo/lists/$listId/tasks/$taskId/attachments/$attachmentId/\$value',
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(response.data ?? []);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Graph delta sync
  // ---------------------------------------------------------------------------

  @override
  Future<MailDeltaResult> syncMailDelta(
    String folderId, {
    String? deltaLink,
  }) async {
    final upserted = <EmailModel>[];
    final removedIds = <String>[];

    // For the initial sync (no saved token), restrict to the last 30 days so
    // the first pass is fast. The returned delta link tracks ALL future changes
    // regardless of this filter.
    final cutoff = DateTime.now().subtract(const Duration(days: 30)).toUtc();
    final cutoffStr =
        '${cutoff.year.toString().padLeft(4, '0')}-'
        '${cutoff.month.toString().padLeft(2, '0')}-'
        '${cutoff.day.toString().padLeft(2, '0')}T00:00:00Z';

    String? nextUrl = deltaLink;
    bool isInitial = deltaLink == null;

    try {
      while (true) {
        final Response<Map<String, dynamic>> response;

        if (isInitial) {
          isInitial = false;
          response = await _dio.get<Map<String, dynamic>>(
            '/me/mailFolders/$folderId/messages/delta',
            queryParameters: {
              '\$select': _emailListSelect,
              '\$filter': 'receivedDateTime ge $cutoffStr',
              '\$top': 50,
            },
          );
        } else {
          // nextLink / deltaLink are full absolute URLs — Dio uses them as-is.
          response = await _dio.get<Map<String, dynamic>>(nextUrl!);
        }

        final data = response.data ?? <String, dynamic>{};

        for (final item
            in (data['value'] as List<dynamic>? ?? [])
                .cast<Map<String, dynamic>>()) {
          if (item.containsKey('@removed')) {
            final id = item['id'] as String?;
            if (id != null) removedIds.add(id);
          } else {
            upserted.add(EmailModel.fromJson(item));
          }
        }

        final dl = data['@odata.deltaLink'] as String?;
        if (dl != null) {
          return MailDeltaResult(
            upserted: upserted,
            removedIds: removedIds,
            deltaLink: dl,
          );
        }

        nextUrl = data['@odata.nextLink'] as String?;
        if (nextUrl == null) break;
      }
    } on DioException catch (e) {
      throw _mapDioException(e);
    }

    throw const ServerException(
        message: 'Delta query completed without returning a delta link');
  }

  @override
  Future<List<AttendeeAvailability>> getAttendeesSchedule({
    required List<String> emails,
    required DateTime start,
    required DateTime end,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/me/calendar/getSchedule',
        data: {
          'schedules': emails,
          'startTime': {
            'dateTime': start.toUtc().toIso8601String().replaceFirst('Z', ''),
            'timeZone': 'UTC',
          },
          'endTime': {
            'dateTime': end.toUtc().toIso8601String().replaceFirst('Z', ''),
            'timeZone': 'UTC',
          },
        },
      );

      final value = response.data?['value'] as List<dynamic>? ?? [];
      return value.cast<Map<String, dynamic>>().map((item) {
        final scheduleId = item['scheduleId'] as String? ?? '';
        final availabilityView = item['availabilityView'] as String? ?? '';
        final rawItems = (item['scheduleItems'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();
        final scheduleItems = rawItems
            .map((si) {
              final startDt = (si['start'] as Map?)?['dateTime'] as String?;
              final endDt = (si['end'] as Map?)?['dateTime'] as String?;
              if (startDt == null || endDt == null) return null;
              final status = _parseItemStatus(si['status'] as String?);
              if (status == AttendeeAvailabilityStatus.free ||
                  status == AttendeeAvailabilityStatus.unknown) return null;
              return AttendeeScheduleItem(
                start: DateTime.parse('${startDt.split('.').first}Z'),
                end: DateTime.parse('${endDt.split('.').first}Z'),
                status: status,
                subject: si['subject'] as String?,
                isPrivate: si['isPrivate'] as bool? ?? false,
              );
            })
            .whereType<AttendeeScheduleItem>()
            .toList();
        return AttendeeAvailability(
          email: scheduleId,
          status: _worstStatus(availabilityView),
          scheduleItems: scheduleItems,
        );
      }).toList();
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  AttendeeAvailabilityStatus _parseItemStatus(String? status) =>
      switch (status?.toLowerCase()) {
        'busy' => AttendeeAvailabilityStatus.busy,
        'tentative' => AttendeeAvailabilityStatus.tentative,
        'oof' => AttendeeAvailabilityStatus.outOfOffice,
        'workingelsewhere' => AttendeeAvailabilityStatus.workingElsewhere,
        'free' => AttendeeAvailabilityStatus.free,
        _ => AttendeeAvailabilityStatus.unknown,
      };

  AttendeeAvailabilityStatus _worstStatus(String availabilityView) {
    if (availabilityView.contains('2')) return AttendeeAvailabilityStatus.busy;
    if (availabilityView.contains('3')) return AttendeeAvailabilityStatus.outOfOffice;
    if (availabilityView.contains('1')) return AttendeeAvailabilityStatus.tentative;
    if (availabilityView.contains('4')) return AttendeeAvailabilityStatus.workingElsewhere;
    if (availabilityView.isNotEmpty) return AttendeeAvailabilityStatus.free;
    return AttendeeAvailabilityStatus.unknown;
  }

  @override
  Future<void> createFolder({
    required String parentFolderId,
    required String displayName,
  }) async {
    try {
      await _dio.post<void>(
        '/me/mailFolders/$parentFolderId/childFolders',
        data: {'displayName': displayName},
      );
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  static final _angleEmail = RegExp(r'<([^>]+)>\s*$');

  /// Extracts a bare email address from an optionally formatted string like
  /// "Display Name <email@example.com>" — Graph API rejects the full format.
  static String _bareEmail(String address) {
    final m = _angleEmail.firstMatch(address);
    return m != null ? m.group(1)!.trim() : address.trim();
  }

  @override
  Future<String> createServerDraft({
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        '/me/messages',
        data: {
          'subject': subject,
          'body': {'contentType': 'Text', 'content': body},
          'toRecipients':
              toAddresses.map((a) => {'emailAddress': {'address': a}}).toList(),
          if (ccAddresses.isNotEmpty)
            'ccRecipients': ccAddresses
                .map((a) => {'emailAddress': {'address': a}})
                .toList(),
        },
      );
      final id = resp.data?['id'] as String?;
      if (id == null) throw const ServerException(message: 'No draft ID in response');
      if (newAttachments.isNotEmpty) await _addAttachmentsToDraft(id, newAttachments);
      return id;
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<String> updateServerDraft({
    required String draftId,
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    try {
      await _dio.patch<void>(
        '/me/messages/$draftId',
        data: {
          'subject': subject,
          'body': {'contentType': 'Text', 'content': body},
          'toRecipients':
              toAddresses.map((a) => {'emailAddress': {'address': a}}).toList(),
          if (ccAddresses.isNotEmpty)
            'ccRecipients': ccAddresses
                .map((a) => {'emailAddress': {'address': a}})
                .toList(),
        },
      );
      if (newAttachments.isNotEmpty) await _addAttachmentsToDraft(draftId, newAttachments);
      return draftId;
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<void> deleteServerDraft({required String draftId}) async {
    try {
      await _dio.delete<void>('/me/messages/$draftId');
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  Exception _mapDioException(DioException e) {
    final statusCode = e.response?.statusCode;

    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return NetworkException(message: e.message ?? 'Network error');
    }

    if (statusCode == 401) {
      final msg = _extractGraphErrorMessage(e) ?? 'Authentication required';
      return AuthException(message: msg);
    }

    final msg = _extractGraphErrorMessage(e) ??
        e.message ??
        'Server error ($statusCode)';
    return ServerException(message: msg, statusCode: statusCode);
  }

  String? _extractGraphErrorMessage(DioException e) {
    try {
      final data = e.response?.data;
      if (data is Map) {
        final error = data['error'] as Map?;
        return error?['message'] as String?;
      }
    } catch (_) {}
    return null;
  }
}
