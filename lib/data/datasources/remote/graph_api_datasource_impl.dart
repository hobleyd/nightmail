import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/error/exceptions.dart';
import '../../../core/utils/ics_parser.dart';
import '../../../core/utils/online_meeting_url.dart';
import '../../../domain/entities/contact_details.dart';
import '../../../domain/entities/local_attachment.dart';
import '../../../domain/entities/attendee_availability.dart';
import '../../../domain/entities/email.dart';
import '../../../domain/entities/inline_attachment.dart';
import '../../../domain/entities/calendar_recurrence.dart';
import '../../../domain/entities/meeting_invite.dart';
import '../../../domain/entities/meeting_room.dart';
import '../../../domain/entities/todo_task.dart';
import '../../../domain/usecases/create_calendar_event.dart';
import '../../../domain/usecases/update_calendar_event.dart';
import '../../../infrastructure/http/graph_http_client.dart';
import '../../models/calendar_event_model.dart';
import '../../models/email_address_model.dart';
import '../../models/email_folder_model.dart';
import '../../models/email_model.dart';
import '../../models/mail_delta_result.dart';
import '../../models/todo_task_attachment_model.dart';
import '../../models/todo_task_list_model.dart';
import '../../models/todo_task_model.dart';
import 'calendar_remote_datasource.dart';
import 'contact_bulk_parser.dart';
import 'email_remote_datasource.dart';
import 'graph_delta_datasource.dart';
import 'graph_message_parser.dart';
import 'tasks_remote_datasource.dart';

/// Path to the calendar event linked to a message.
///
/// The `event` navigation property is declared on `eventMessage`, a type derived
/// from `message`, so OData requires the cast segment. Reaching for
/// `/me/messages/{id}/event` instead makes Graph answer HTTP 400 "Resource not
/// found for the segment 'event'" — which reads like a missing event rather than
/// a malformed URL, so callers quietly fall back to searching the calendar.
///
/// Visible for testing.
String linkedEventPath(String messageId) =>
    '/me/messages/$messageId/microsoft.graph.eventMessage/event';

/// Whether a message's own MIME headers declare its body as plain text.
///
/// Graph will not tell us this. `body.contentType` reports the format Graph
/// *rendered*, not the one the sender wrote: absent a
/// `Prefer: outlook.body-content-type` header it renders HTML and converts a
/// text/plain message on the way, and asking for text instead converts real
/// HTML in the other direction. Either way the answer echoes the request. The
/// message's own `Content-Type` header is the only thing that still remembers.
///
/// Visible for testing.
bool declaresPlainTextBody(List<dynamic> internetMessageHeaders) {
  for (final header in internetMessageHeaders) {
    if (header is! Map) continue;
    if ((header['name'] as String?)?.trim().toLowerCase() != 'content-type') {
      continue;
    }
    final value = (header['value'] as String?)?.trim().toLowerCase() ?? '';
    // Only a wholly plain-text message. A `multipart/*` top level means the
    // body is one part among several, and which one Graph rendered is exactly
    // what this header cannot say.
    return value.startsWith('text/plain');
  }
  return false;
}

final _emailListSelect = [
  'id',
  'subject',
  'from',
  'toRecipients',
  'ccRecipients',
  'bodyPreview',
  'isRead',
  // The provider's own follow-up bit. In the projection so a flag set or
  // cleared elsewhere arrives as an ordinary field update — including on the
  // delta feed, which reuses this list.
  'flag',
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

  // Recurrence JSON per series-master id. calendarView expands each series into
  // occurrences that don't carry the `recurrence` pattern — only the master
  // does — so to display recurrence on an occurrence we fetch its master once
  // and cache the pattern. Refreshed at most every 10 minutes; cleared on any
  // local edit so recurrence changes made in-app are reflected immediately.
  final Map<String, Map<String, dynamic>?> _recurrenceByMaster = {};
  DateTime? _recurrenceCacheAt;

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
      final response = await _dio.get<String>(
        path,
        queryParameters: {
          '\$top': top,
          '\$skip': skip,
          '\$select': _emailListSelect,
          '\$orderby': orderBy,
          '\$filter': ?filter,
        },
        options: Options(responseType: ResponseType.plain),
      );

      final raw = response.data;
      if (raw == null || raw.isEmpty) return [];

      final folderEmails = await compute(parseGraphMessageCollection, raw);

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

      // Fetch every conversation concurrently (network only), then decode the
      // whole set in one background isolate rather than one per conversation —
      // compute() spawns an isolate per call, and a page can easily hold 25
      // distinct threads.
      final rawBatches = await Future.wait(
        conversationIds.map(_fetchConversationRaw),
      );
      final crossFolderEmails =
          await compute(parseGraphMessageCollections, rawBatches);

      // Merge: folder emails + cross-folder emails, de-duplicated by id.
      final byId = <String, EmailModel>{};
      for (final e in folderEmails) {
        byId[e.id] = e;
      }
      for (final e in crossFolderEmails) {
        byId.putIfAbsent(e.id, () => e);
      }
      return byId.values.toList();
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  /// [folderId] is ignored: Graph filters conversations mailbox-wide.
  @override
  Future<List<EmailModel>> getConversationMessages(
    String conversationId, {
    String? folderId,
  }) async {
    final raw = await _fetchConversationRaw(conversationId);
    if (raw == null) return [];
    try {
      return await compute(parseGraphMessageCollection, raw);
    } catch (_) {
      return [];
    }
  }

  /// Fetches one conversation's messages **undecoded**, for a parser isolate to
  /// decode. Returns null when the fetch fails, which the batch parser skips.
  Future<String?> _fetchConversationRaw(String conversationId) async {
    try {
      final response = await _dio.get<String>(
        '/me/messages',
        queryParameters: {
          '\$filter': "conversationId eq '$conversationId'",
          '\$select': _emailListSelect,
          '\$top': 200,
        },
        options: Options(responseType: ResponseType.plain),
      );
      return response.data;
    } catch (_) {
      return null;
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
      final response = await _dio.get<String>(
        '/me/messages',
        queryParameters: {
          '\$top': top,
          '\$select': _emailListSelect,
          '\$search': '"$kql"',
        },
        options: Options(responseType: ResponseType.plain),
      );
      final raw = response.data;
      if (raw == null || raw.isEmpty) return [];
      return compute(parseGraphMessageCollection, raw);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<EmailModel> getEmail(String id) async {
    try {
      // Started before the message itself and awaited after, so the extra round
      // trip overlaps the one that matters instead of adding to it.
      final plainTextFuture = _fetchPlainTextBody(id);

      // Undecoded: the message body and every inline image arrive as one JSON
      // document, so the jsonDecode is a large share of the cost and belongs in
      // the parser isolate along with the parse itself.
      final response = await _dio.get<String>(
        '/me/messages/$id',
        queryParameters: {
          // No $select here: Graph omits @odata.type for derived types
          // (eventMessage) on single-resource GETs when $select is present.
          // Returning all default fields ensures the type annotation is present.
          '\$expand': r'attachments($select=id,name,contentType,size,isInline)',
        },
        // Return eventMessage startDateTime/endDateTime in UTC so we can use
        // them directly without Windows-timezone-name conversion.
        options: Options(
          headers: {'Prefer': 'outlook.timezone="UTC"'},
          responseType: ResponseType.plain,
        ),
      );

      final raw = response.data;
      if (raw == null || raw.isEmpty) {
        throw ServerException(
            message: 'Empty response for message $id', statusCode: 200);
      }

      final parsed = await compute(parseGraphFullMessage, raw);
      var email = parsed.email;

      final pendingIds = parsed.pendingInlineAttachmentIds;
      if (pendingIds.isNotEmpty) {
        // contentId and contentBytes are on the fileAttachment subtype and
        // cannot be requested via $select in $expand (which targets the base
        // attachment type), so each inline image needs its own GET. Fetched
        // undecoded and decoded in one more isolate hop — these are images, so
        // the base64 is exactly what must not run here.
        final rawInline = <String>[];
        for (final attachId in pendingIds) {
          try {
            final detail = await _dio.get<String>(
              '/me/messages/$id/attachments/$attachId',
              options: Options(responseType: ResponseType.plain),
            );
            final body = detail.data;
            if (body != null && body.isNotEmpty) rawInline.add(body);
          } catch (_) {}
        }
        if (rawInline.isNotEmpty) {
          final inlineAttachments =
              await compute(parseGraphInlineAttachments, rawInline);
          if (inlineAttachments.isNotEmpty) {
            email = _rebuild(
              email,
              inlineAttachments: [
                ...email.inlineAttachments,
                ...inlineAttachments,
              ],
            );
          }
        }
      }

      final icsAttachmentId = parsed.icsAttachmentId;
      if (icsAttachmentId != null) {
        final invite = await _fetchPublishedEventInvite(id, icsAttachmentId);
        if (invite != null) email = _rebuild(email, meetingInvite: invite);
      }

      final plainText = await plainTextFuture;
      if (plainText != null) {
        email =
            _rebuild(email, body: plainText, bodyType: EmailBodyType.text);
      }
      return email;
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  /// The invite behind an `.ics` attachment, but **only** when it is a
  /// [MeetingEmailType.publishedEvent].
  ///
  /// Graph classifies meeting mail itself, through `meetingMessageType`, and
  /// every action those banners offer is addressed to the message id — which
  /// only works for a real `eventMessage`. An ordinary message that merely
  /// carries an invitation as a file is not one, so anything but a published
  /// event is dropped rather than given buttons with nothing behind them.
  /// `PUBLISH` is safe because its action creates a fresh event and never
  /// refers back to the message.
  Future<MeetingInvite?> _fetchPublishedEventInvite(
      String messageId, String attachmentId) async {
    try {
      final response = await _dio.get<String>(
        '/me/messages/$messageId/attachments/$attachmentId',
        options: Options(responseType: ResponseType.plain),
      );
      final raw = response.data;
      if (raw == null || raw.isEmpty) return null;
      final invite = await compute(parseGraphIcsAttachment, raw);
      return invite?.type == MeetingEmailType.publishedEvent ? invite : null;
    } catch (_) {
      // An attachment that will not fetch or parse just means no banner.
      return null;
    }
  }

  /// Graph's own plain-text rendition of a message, when the message's MIME
  /// headers say the sender wrote plain text. Null means "keep the HTML".
  ///
  /// Taking Graph's rendition rather than converting its HTML back to text
  /// keeps the round trip honest: the HTML is Exchange's own lossy transcription
  /// of the text, and undoing it here would be a second guess at the first.
  ///
  /// Everything failing lands on null — no headers (Exchange does not always
  /// keep them for internal mail), a throttled request, a malformed body — and
  /// null is exactly what the app did before this existed, so a message renders
  /// as it always has rather than not at all.
  Future<String?> _fetchPlainTextBody(String id) async {
    try {
      final response = await _dio.get<String>(
        '/me/messages/$id',
        queryParameters: {'\$select': 'internetMessageHeaders,body'},
        options: Options(
          headers: {'Prefer': 'outlook.body-content-type="text"'},
          responseType: ResponseType.plain,
        ),
      );
      final raw = response.data;
      if (raw == null || raw.isEmpty) return null;

      // Decoded here rather than in an isolate, unlike every other message
      // fetch: $select holds this down to headers plus a text body, with no
      // attachments expanded, so none of the base64 that makes the full
      // document worth handing off is in it.
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final headers =
          json['internetMessageHeaders'] as List<dynamic>? ?? const [];
      if (!declaresPlainTextBody(headers)) return null;
      return (json['body'] as Map<String, dynamic>?)?['content'] as String? ??
          '';
    } catch (_) {
      return null;
    }
  }

  /// Rebuilds [email] with the given overrides.
  ///
  /// Rebuilt rather than re-parsed: the decode already happened in the isolate,
  /// so this is pure object construction.
  EmailModel _rebuild(
    EmailModel email, {
    String? body,
    EmailBodyType? bodyType,
    List<InlineAttachment>? inlineAttachments,
    MeetingInvite? meetingInvite,
  }) {
    return EmailModel(
      id: email.id,
      subject: email.subject,
      from: EmailAddressModel.fromEntity(email.from),
      toRecipients:
          email.toRecipients.map(EmailAddressModel.fromEntity).toList(),
      ccRecipients:
          email.ccRecipients.map(EmailAddressModel.fromEntity).toList(),
      bodyPreview: email.bodyPreview,
      body: body ?? email.body,
      bodyType: bodyType ?? email.bodyType,
      isRead: email.isRead,
      isFlagged: email.isFlagged,
      receivedDateTime: email.receivedDateTime,
      importance: email.importance,
      sentDateTime: email.sentDateTime,
      conversationId: email.conversationId,
      hasAttachments: email.hasAttachments,
      attachments: email.attachments,
      inlineAttachments: inlineAttachments ?? email.inlineAttachments,
      parentFolderId: email.parentFolderId,
      folderIds: email.folderIds,
      meetingInvite: meetingInvite ?? email.meetingInvite,
    );
  }

  @override
  Future<EmailModel> updateEmailReadStatus({
    required String id,
    required bool isRead,
  }) async {
    try {
      final response = await _dio.patch<String>(
        '/me/messages/$id',
        data: {'isRead': isRead},
        queryParameters: {'\$select': _emailListSelect},
        options: Options(responseType: ResponseType.plain),
      );

      final raw = response.data;
      if (raw == null || raw.isEmpty) {
        throw ServerException(
            message: 'Empty response when updating message $id', statusCode: 200);
      }

      return compute(parseGraphMessage, raw);
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
              'id,iCalUId,subject,start,end,isAllDay,location,onlineMeeting,bodyPreview,showAs,isOrganizer,responseStatus,attendees,recurrence,isReminderOn,reminderMinutesBeforeStart,seriesMasterId',
          '\$top': 100,
        },
        options: Options(
          headers: {'Prefer': 'outlook.timezone="UTC"'},
        ),
      );

      final data = response.data;
      if (data == null) return [];

      final rawItems =
          (data['value'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

      // Occurrences don't carry the recurrence pattern — resolve it from each
      // distinct series master so the edit form can show recurrence.
      final masterIds = rawItems
          .where((e) => e['recurrence'] == null)
          .map((e) => e['seriesMasterId'] as String?)
          .whereType<String>()
          .toSet();
      final recurrenceByMaster = await _recurrenceJsonForMasters(masterIds);

      return rawItems.map((e) {
        final masterId = e['seriesMasterId'] as String?;
        final recurrence =
            masterId != null ? recurrenceByMaster[masterId] : null;
        final json = (e['recurrence'] == null && recurrence != null)
            ? {...e, 'recurrence': recurrence}
            : e;
        return CalendarEventModel.fromJson(json);
      }).toList();
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<CalendarEventModel> getCalendarEvent({required String id}) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/me/events/$id',
        queryParameters: {
          '\$select':
              'id,iCalUId,subject,start,end,isAllDay,location,onlineMeeting,bodyPreview,showAs,isOrganizer,responseStatus,attendees,recurrence,isReminderOn,reminderMinutesBeforeStart,seriesMasterId',
        },
        options: Options(headers: {'Prefer': 'outlook.timezone="UTC"'}),
      );
      final data = response.data;
      if (data == null) {
        throw const ServerException(message: 'Empty response from server');
      }
      return CalendarEventModel.fromJson(data);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  /// Fetches the `recurrence` pattern for each distinct series master (in
  /// parallel), caching results for 10 minutes. Returns master id → recurrence
  /// JSON (null when the master has no pattern or the fetch fails).
  Future<Map<String, Map<String, dynamic>?>> _recurrenceJsonForMasters(
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
        final resp = await _dio.get<Map<String, dynamic>>(
          '/me/events/$id',
          queryParameters: {'\$select': 'recurrence'},
        );
        _recurrenceByMaster[id] =
            resp.data?['recurrence'] as Map<String, dynamic>?;
      } catch (e) {
        debugPrint('GraphApiDatasourceImpl: recurrence fetch for $id failed: $e');
        _recurrenceByMaster[id] = null;
      }
    }));

    return {for (final id in masterIds) id: _recurrenceByMaster[id]};
  }

  void _invalidateRecurrenceCache() {
    _recurrenceByMaster.clear();
    _recurrenceCacheAt = null;
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
        roomEmails: params.roomEmails,
        recurrence: params.recurrence,
        isOnlineMeeting: params.isOnlineMeeting,
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
    // Recurrence may have changed; drop the cache so the next load refetches.
    _invalidateRecurrenceCache();
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
        roomEmails: params.roomEmails,
        recurrence: params.recurrence,
        isOnlineMeeting: params.isOnlineMeeting,
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
    String? message,
  }) async {
    final endpoint = switch (response) {
      MeetingInviteResponseType.accept => 'accept',
      MeetingInviteResponseType.tentative => 'tentativelyAccept',
      MeetingInviteResponseType.decline => 'decline',
    };
    final body = {'sendResponse': true, 'comment': message ?? ''};

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
        linkedEventPath(emailId),
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
  bool get supportsNativeProposeNewTime => true;

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
    // Both halves must describe the same zone. _formatLocalDateTime renders
    // *local* wall-clock, so pairing it with 'UTC' shifted every proposal by
    // the local offset — a proposal of 11:30 Sydney arrived as 21:30 Sydney.
    final body = {
      'sendResponse': true,
      'comment': message ?? '',
      'proposedNewTime': {
        'start': _graphDateTime(newStart),
        'end': _graphDateTime(newEnd),
      },
    };

    // Navigate from message to its linked calendar event.
    String? eventId;
    try {
      final eventResp = await _dio.get<Map<String, dynamic>>(
        linkedEventPath(emailId),
        queryParameters: {'\$select': 'id,isOrganizer'},
      );
      final isOrganizer = eventResp.data?['isOrganizer'] as bool? ?? false;
      if (isOrganizer) return;
      eventId = eventResp.data?['id'] as String?;
    } on DioException {
      // Navigation unavailable — fall through to calendar search.
    }

    if (eventId != null) {
      try {
        await _dio.post<void>('/me/events/$eventId/decline', data: body);
        return;
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        if (status == 401 || status == 403) throw _mapDioException(e);
      }
    }

    // Fall back to calendar search by meeting start time.
    if (meetingStart == null) {
      throw const ServerException(
          message: 'Could not locate the calendar event for this invite');
    }
    try {
      final windowStart = meetingStart.subtract(const Duration(minutes: 30));
      final windowEnd = meetingStart.add(const Duration(hours: 2));
      String fmt(DateTime d) => d.toUtc().toIso8601String();
      final calResp = await _dio.get<Map<String, dynamic>>(
        '/me/calendarView',
        queryParameters: {
          'startDateTime': fmt(windowStart),
          'endDateTime': fmt(windowEnd),
          '\$select': 'id,isOrganizer',
          '\$top': 50,
        },
        options: Options(headers: {'Prefer': 'outlook.timezone="UTC"'}),
      );
      final events = (calResp.data?['value'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      final attendeeEvents =
          events.where((e) => e['isOrganizer'] != true).toList();
      if (attendeeEvents.isEmpty) {
        throw const ServerException(
            message: 'No meeting found in your calendar at that time');
      }
      final targetId = attendeeEvents.first['id'] as String;
      await _dio.post<void>('/me/events/$targetId/decline', data: body);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<void> removeMeetingFromCalendar({
    required String emailId,
    String? icsData,
    DateTime? meetingStart,
  }) async {
    // 1. Navigate from message to its linked calendar event.
    String? eventId;
    try {
      final eventResp = await _dio.get<Map<String, dynamic>>(
        linkedEventPath(emailId),
        queryParameters: {'\$select': 'id'},
      );
      eventId = eventResp.data?['id'] as String?;
    } on DioException {
      // Navigation unavailable — fall through to calendar search.
    }

    if (eventId != null) {
      try {
        await _dio.delete<void>('/me/events/$eventId');
        return;
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        if (status == 401 || status == 403) throw _mapDioException(e);
        // Fall through to calendar search.
      }
    }

    // 2. Fallback: search the calendar by start time and delete the attendee event.
    if (meetingStart == null) {
      throw const ServerException(
          message: 'Could not locate the calendar event for this cancellation');
    }
    try {
      final windowStart = meetingStart.subtract(const Duration(minutes: 30));
      final windowEnd = meetingStart.add(const Duration(hours: 2));
      String fmt(DateTime d) => d.toUtc().toIso8601String();
      final calResp = await _dio.get<Map<String, dynamic>>(
        '/me/calendarView',
        queryParameters: {
          'startDateTime': fmt(windowStart),
          'endDateTime': fmt(windowEnd),
          '\$select': 'id,isOrganizer',
          '\$top': 50,
        },
        options: Options(headers: {'Prefer': 'outlook.timezone="UTC"'}),
      );
      final events = (calResp.data?['value'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      final attendeeEvents =
          events.where((e) => e['isOrganizer'] != true).toList();
      if (attendeeEvents.isEmpty) return; // Not in calendar — nothing to remove.
      final targetId = attendeeEvents.first['id'] as String;
      await _dio.delete<void>('/me/events/$targetId');
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<void> cancelMeetingFromEmail({
    required String emailId,
    DateTime? meetingStart,
  }) async {
    // 1. Navigate from the decline-notification message to the calendar event.
    String? eventId;
    try {
      final eventResp = await _dio.get<Map<String, dynamic>>(
        linkedEventPath(emailId),
        queryParameters: {'\$select': 'id,isOrganizer'},
      );
      final isOrganizer = eventResp.data?['isOrganizer'] as bool? ?? false;
      if (!isOrganizer) {
        throw const ServerException(
            message: 'You are not the organizer of this meeting');
      }
      eventId = eventResp.data?['id'] as String?;
    } on DioException {
      // Navigation unavailable — fall through to calendar search.
    }

    if (eventId != null) {
      try {
        await _dio.post<void>('/me/events/$eventId/cancel', data: {'comment': ''});
        return;
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        if (status == 401 || status == 403) throw _mapDioException(e);
      }
    }

    // 2. Fallback: search calendar by start time and cancel the organizer event.
    if (meetingStart == null) {
      throw const ServerException(
          message: 'Could not locate the calendar event to cancel');
    }
    try {
      final windowStart = meetingStart.subtract(const Duration(minutes: 30));
      final windowEnd = meetingStart.add(const Duration(hours: 2));
      String fmt(DateTime d) => d.toUtc().toIso8601String();
      final calResp = await _dio.get<Map<String, dynamic>>(
        '/me/calendarView',
        queryParameters: {
          'startDateTime': fmt(windowStart),
          'endDateTime': fmt(windowEnd),
          '\$select': 'id,isOrganizer',
          '\$top': 50,
        },
        options: Options(headers: {'Prefer': 'outlook.timezone="UTC"'}),
      );
      final events = (calResp.data?['value'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      final organized = events.where((e) => e['isOrganizer'] == true).toList();
      if (organized.isEmpty) {
        throw const ServerException(
            message: 'No organizer event found in your calendar at that time');
      }
      final targetId = organized.first['id'] as String;
      await _dio.post<void>('/me/events/$targetId/cancel', data: {'comment': ''});
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<void> acceptProposedTimeFromEmail({
    required String emailId,
    required DateTime newStart,
    required DateTime newEnd,
    String? icsData,
    DateTime? meetingStart,
  }) async {
    final eventId = await _organizerEventIdForMessage(
      emailId: emailId,
      meetingStart: meetingStart,
      icsData: icsData,
    );
    try {
      // PATCHing start/end makes Graph send the updated invitation to every
      // attendee by itself — there is no separate "send update" call.
      await _dio.patch<void>(
        '/me/events/$eventId',
        data: {
          'start': _graphDateTime(newStart),
          'end': _graphDateTime(newEnd),
        },
      );
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  /// A Graph `DateTimeTimeZone` in UTC.
  ///
  /// The zone lives in its own field, so the `dateTime` string carries no
  /// offset — hence stripping the `Z`. Use this rather than
  /// [_formatLocalDateTime] unless you are also passing that value's real IANA
  /// zone: the two fields must agree, or the time silently shifts.
  Map<String, String> _graphDateTime(DateTime dt) => {
        'dateTime':
            dt.toUtc().toIso8601String().replaceFirst(RegExp(r'Z$'), ''),
        'timeZone': 'UTC',
      };

  /// Resolves the proposal message into the id of the organizer's own copy of
  /// the meeting.
  ///
  /// Four strategies are tried in turn, because none is reliable alone:
  /// the iCalendar UID in the proposal's calendar part, Graph's `message/event`
  /// navigation, a calendar search at the meeting's current time, and finally
  /// the same navigation from another message in the conversation.
  ///
  /// The UID goes first because it is the only one that survives a proposal
  /// Exchange never recognised. A `METHOD:COUNTER` from a non-Exchange client
  /// can stay an ordinary `message`, and then every navigation is dead — the
  /// cast segment is rejected outright with "Resource not found for the segment
  /// 'EventMessage'", because the message genuinely is not one.
  ///
  /// Every attempt's reason for failing is collected and reported together: a
  /// bare "could not locate" says nothing about which step broke, which is
  /// exactly what distinguishes a missing event from a rejected request.
  Future<String> _organizerEventIdForMessage({
    required String emailId,
    DateTime? meetingStart,
    String? icsData,
  }) async {
    final tried = <String>[];

    final byUid = await _eventIdByICalUid(emailId, icsData, tried);
    if (byUid != null) return byUid;

    // Re-read the message rather than trusting what the caller parsed: Graph
    // does not always populate startDateTime on a response, and the caller's
    // copy may have come from the list projection.
    Map<String, dynamic>? message;
    try {
      final resp =
          await _dio.get<Map<String, dynamic>>('/me/messages/$emailId');
      message = resp.data;
    } on DioException catch (e) {
      if (_isGraphAuthFailure(e)) throw _mapDioException(e);
      tried.add('re-reading the message failed (${_describeGraphError(e)})');
    }

    final conversationId = message?['conversationId'] as String?;
    final siblings = conversationId == null
        ? const <String>[]
        : await _conversationMessageIds(conversationId, emailId, tried);
    if (conversationId == null) {
      tried.add('the message has no conversation to trace back to');
    }

    // Outlook splits propose-new-time into two messages: a decline that carries
    // the .ics, and the proposal itself, which does not. So the UID that
    // identifies the meeting usually lives on a sibling, not on the message the
    // user is looking at.
    for (final id in siblings) {
      final viaSibling = await _eventIdByICalUid(id, null, <String>[]);
      if (viaSibling != null) return viaSibling;
    }
    if (siblings.isNotEmpty) {
      tried.add('no calendar attachment on the ${siblings.length} other '
          'messages in the conversation either');
    }

    final direct = await _eventIdForMessage(emailId, tried);
    if (direct != null) return direct;

    final start =
        meetingStart ?? _parseGraphDateTime(message?['startDateTime']);
    if (start == null) {
      tried.add('the message states no current meeting time to search by');
    } else {
      final byTime = await _organizerEventIdAt(start, tried);
      if (byTime != null) return byTime;
    }

    for (final id in siblings) {
      final viaSibling = await _eventIdForMessage(id, <String>[]);
      if (viaSibling != null) return viaSibling;
    }
    if (siblings.isNotEmpty) {
      tried.add('none of them link to a calendar event');
    }

    // The message's real type explains most failures above, and is otherwise
    // invisible from the outside.
    final odataType = message?['@odata.type'] as String?;
    if (odataType != null) tried.add('the message is a $odataType');

    throw ServerException(
        message: 'Could not find the meeting to update. ${tried.join('. ')}.');
  }

  /// Finds the meeting by the iCalendar UID of the proposal's calendar part.
  ///
  /// The UID is echoed from the invitation, so it matches the organizer's own
  /// copy, and Graph exposes it on events as `iCalUId`.
  Future<String?> _eventIdByICalUid(
      String messageId, String? icsData, List<String> tried) async {
    final ics = icsData ?? await _calendarPartOfMessage(messageId, tried);
    if (ics == null) return null;

    String? uid;
    try {
      uid = IcsParser.parse(ics).uid;
    } catch (_) {
      // Fall through to the same diagnostic as a UID-less part.
    }
    if (uid == null) {
      tried.add('the calendar part carries no UID');
      return null;
    }

    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/me/events',
        queryParameters: {
          // Single quotes delimit the literal, so an embedded one must double.
          '\$filter': "iCalUId eq '${uid.replaceAll("'", "''")}'",
          '\$select': 'id,isOrganizer',
          '\$top': 5,
        },
      );
      final events = (resp.data?['value'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      for (final e in events) {
        if (e['isOrganizer'] == true) return e['id'] as String?;
      }
      if (events.isNotEmpty) {
        throw const ServerException(
            message: 'You are not the organizer of this meeting');
      }
      tried.add('no meeting in your calendar has UID $uid');
    } on DioException catch (e) {
      if (_isGraphAuthFailure(e)) throw _mapDioException(e);
      tried.add('looking up UID $uid failed (${_describeGraphError(e)})');
    }
    return null;
  }

  /// The text of the message's `text/calendar` part, if it has one.
  Future<String?> _calendarPartOfMessage(
      String messageId, List<String> tried) async {
    try {
      final list = await _dio.get<Map<String, dynamic>>(
        '/me/messages/$messageId/attachments',
        queryParameters: {'\$select': 'id,name,contentType'},
      );
      final items = (list.data?['value'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      String? calendarId;
      for (final a in items) {
        final type = (a['contentType'] as String? ?? '').toLowerCase();
        final name = (a['name'] as String? ?? '').toLowerCase();
        if (type.contains('text/calendar') || name.endsWith('.ics')) {
          calendarId = a['id'] as String?;
          break;
        }
      }
      if (calendarId == null) {
        tried.add('the message has no calendar attachment to read a UID from');
        return null;
      }

      // contentBytes lives on the fileAttachment subtype and cannot be
      // $selected from the collection, so fetch the attachment on its own.
      final detail = await _dio.get<Map<String, dynamic>>(
          '/me/messages/$messageId/attachments/$calendarId');
      final encoded = detail.data?['contentBytes'] as String?;
      if (encoded == null || encoded.isEmpty) {
        tried.add('the calendar attachment returned no content');
        return null;
      }
      return utf8.decode(base64Decode(encoded), allowMalformed: true);
    } on DioException catch (e) {
      if (_isGraphAuthFailure(e)) throw _mapDioException(e);
      tried.add('reading the calendar attachment failed '
          '(${_describeGraphError(e)})');
    } on FormatException catch (e) {
      tried.add('the calendar attachment was not readable (${e.message})');
    }
    return null;
  }

  /// The id of the calendar event linked to [messageId], or null if it cannot
  /// be reached.
  ///
  /// `event` is declared on `eventMessage`, a type *derived* from `message`, so
  /// OData needs a cast segment; without one Graph answers HTTP 400 "Resource
  /// not found for the segment 'event'". Which cast it accepts varies: some
  /// Exchange builds reject the upcast to `eventMessage` and want the message's
  /// exact type, so the response subtype is tried too, and the uncast form last
  /// because it is the documented spelling.
  ///
  /// All three fail when the message is not an eventMessage at all — a
  /// `METHOD:COUNTER` Exchange did not recognise stays an ordinary message.
  Future<String?> _eventIdForMessage(String messageId, List<String> tried) async {
    final attempts = <String>[];
    for (final path in [
      '/me/messages/$messageId/microsoft.graph.eventMessageResponse/event',
      linkedEventPath(messageId),
      '/me/messages/$messageId/event',
    ]) {
      final id = await _eventIdByNavigation(path, attempts);
      if (id != null) return id;
    }
    // The spellings fail for the same underlying reason, so report it once
    // rather than three times.
    if (attempts.isNotEmpty) tried.add(attempts.first);
    return null;
  }

  /// Follows a `message/event` navigation, returning the event id or null when
  /// this strategy did not resolve.
  ///
  /// Throws rather than returning null when the caller is not the organizer:
  /// that is a settled answer, not a failed lookup, and no other strategy can
  /// improve on it.
  Future<String?> _eventIdByNavigation(String path, List<String> tried) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(path);
      if (resp.data?['isOrganizer'] == false) {
        throw const ServerException(
            message: 'You are not the organizer of this meeting');
      }
      final id = resp.data?['id'] as String?;
      if (id != null) return id;
      tried.add('$path returned no event id');
    } on DioException catch (e) {
      if (_isGraphAuthFailure(e)) throw _mapDioException(e);
      tried.add('$path failed (${_describeGraphError(e)})');
    }
    return null;
  }

  /// Finds a meeting the caller organizes around [start].
  Future<String?> _organizerEventIdAt(DateTime start, List<String> tried) async {
    try {
      String fmt(DateTime d) => d.toUtc().toIso8601String();
      final resp = await _dio.get<Map<String, dynamic>>(
        '/me/calendarView',
        queryParameters: {
          'startDateTime': fmt(start.subtract(const Duration(minutes: 30))),
          'endDateTime': fmt(start.add(const Duration(hours: 2))),
          '\$select': 'id,isOrganizer',
          '\$top': 50,
        },
        options: Options(headers: {'Prefer': 'outlook.timezone="UTC"'}),
      );
      final events = (resp.data?['value'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      final organized =
          events.where((e) => e['isOrganizer'] == true).toList();
      if (organized.isNotEmpty) return organized.first['id'] as String;
      tried.add('no meeting you organize sits at ${fmt(start)}');
    } on DioException catch (e) {
      if (_isGraphAuthFailure(e)) throw _mapDioException(e);
      tried.add('searching the calendar failed (${_describeGraphError(e)})');
    }
    return null;
  }

  /// The other messages in [conversationId] — the meeting's whole thread, which
  /// is where the identifying `.ics` and any navigable message actually live.
  ///
  /// Only base-`message` fields are selected. `meetingMessageType` is declared
  /// on the derived `eventMessage`, and asking a message collection for it draws
  /// HTTP 400 "Could not find a property named 'meetingMessageType'" — so the
  /// useful message is found by probing rather than by filtering.
  Future<List<String>> _conversationMessageIds(
      String conversationId, String excludeMessageId, List<String> tried) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/me/messages',
        queryParameters: {
          '\$filter': "conversationId eq '$conversationId'",
          '\$select': 'id',
          '\$top': 10,
        },
      );
      final ids = (resp.data?['value'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>()
          .map((m) => m['id'] as String?)
          .whereType<String>()
          .where((id) => id != excludeMessageId)
          // Each candidate costs several requests, so probe only a few.
          .take(5)
          .toList();
      if (ids.isEmpty) {
        tried.add('the conversation holds no other message to trace back '
            'through');
      }
      return ids;
    } on DioException catch (e) {
      if (_isGraphAuthFailure(e)) throw _mapDioException(e);
      tried.add('searching the conversation failed (${_describeGraphError(e)})');
      return const [];
    }
  }

  bool _isGraphAuthFailure(DioException e) {
    final status = e.response?.statusCode;
    return status == 401 || status == 403 || e.error is AuthException;
  }

  /// A short, user-readable reason for a failed Graph call.
  String _describeGraphError(DioException e) {
    final status = e.response?.statusCode;
    final detail = _extractGraphErrorMessage(e);
    if (detail != null) return status != null ? 'HTTP $status: $detail' : detail;
    return status != null ? 'HTTP $status' : (e.message ?? 'network error');
  }

  /// Parses a Graph `DateTimeTimeZone` as UTC. Graph omits the `Z` when the
  /// caller asked for UTC via `Prefer: outlook.timezone`, so append one.
  DateTime? _parseGraphDateTime(dynamic raw) {
    if (raw is! Map) return null;
    final str = raw['dateTime'] as String?;
    if (str == null || str.isEmpty) return null;
    return DateTime.tryParse(str.endsWith('Z') ? str : '${str}Z');
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
  Future<void> cancelCalendarEventSeries({
    required String eventId,
    String? seriesMasterId,
    required DateTime occurrenceStart,
  }) async {
    // Graph API has no "cancel this and future" primitive that sends a proper
    // cancellation notice. PATCH-ing the recurrence end-date sends an Exchange
    // update, which recipients receive as a new invitation — not a cancellation.
    // Cancelling the series master via POST /cancel sends the correct
    // cancellation message to all attendees.
    final masterId = seriesMasterId ?? eventId;
    _invalidateRecurrenceCache();
    try {
      await _dio.post<void>(
        '/me/events/$masterId/cancel',
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
    List<String> roomEmails = const [],
    CalendarRecurrence? recurrence,
    bool isOnlineMeeting = false,
    int? reminderMinutes,
  }) {
    final body = <String, dynamic>{
      'subject': subject,
      'isAllDay': isAllDay,
      'isReminderOn': reminderMinutes != null,
      if (reminderMinutes != null) 'reminderMinutesBeforeStart': reminderMinutes,
      if (isOnlineMeeting) 'isOnlineMeeting': true,
      if (isOnlineMeeting) 'onlineMeetingProvider': 'teamsForBusiness',
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

    // `location` and `locations` are always sent, even when empty. On a PATCH an
    // omitted field means "leave unchanged", so clearing the location — or
    // releasing the last room — would otherwise silently not take effect
    // server-side. Every caller passes the whole location, so an empty value
    // here really does mean "no location".
    //
    // Rooms go in `locations` as conferenceRoom entries carrying their mailbox
    // address, which is what makes Outlook render them as rooms rather than as
    // a typed-in string. `location` is the single primary that older clients
    // read, so it gets the first entry.
    final roomLocations = roomEmails
        .map((e) => <String, dynamic>{
              'displayName': _roomDisplayName(e),
              'locationEmailAddress': e,
              'locationType': 'conferenceRoom',
            })
        .toList();
    // A join link is not a place. `CalendarEventModel._parseLocation` hands
    // `onlineMeeting.joinUrl` up as the location, so that is what comes back
    // down here for a Teams meeting — storing it as a location entry would
    // duplicate something Graph already holds, and on an event with no room it
    // is the entry that `location` gets, which is how the join link survives
    // today. So it is kept as the location only while there is no room to
    // supersede it; the joinUrl itself lives in `onlineMeeting` regardless and
    // is what the Join Meeting affordance reads back.
    final locationIsJoinUrl = isOnlineMeetingUrl(location);
    final freeTextLocation = (location != null &&
            location.isNotEmpty &&
            !(locationIsJoinUrl && roomEmails.isNotEmpty))
        ? <String, dynamic>{'displayName': location}
        : null;

    // The free text goes first when there is no room, and after the rooms when
    // there is: with a room booked the room is the meeting's real place, and
    // Graph mirrors locations[0] into location.
    final locations = <Map<String, dynamic>>[
      ...roomLocations,
      if (freeTextLocation != null &&
          !_locationNamesARoom(location!, roomEmails))
        freeTextLocation,
    ];

    body['locations'] = locations;
    body['location'] = locations.isEmpty
        ? {'displayName': ''}
        : Map<String, dynamic>.from(locations.first);

    // People are `required`, rooms are `resource` — the type is what tells
    // Exchange to run the room's booking policy (auto-accept, decline on
    // conflict) instead of emailing a human. Always sent for the same
    // PATCH-semantics reason as the locations above.
    body['attendees'] = [
      for (final e in attendeeEmails)
        {
          'emailAddress': {'address': e},
          'type': 'required',
        },
      for (final e in roomEmails)
        {
          'emailAddress': {'address': e, 'name': _roomDisplayName(e)},
          'type': 'resource',
        },
    ];

    if (recurrence != null) {
      body['recurrence'] = _buildGraphRecurrence(recurrence, start);
    }

    return body;
  }

  Map<String, dynamic> _buildGraphRecurrence(
      CalendarRecurrence rawR, DateTime startDate) {
    final r = rawR.normalizedForSync();
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

  /// Looks up an org directory profile by email via Graph's `/users/{id}`.
  /// Returns null on 404 (not in the directory, e.g. an external sender) or
  /// 403 (the `User.Read.All` scope hasn't been granted yet) — both are
  /// expected, silent cases for a best-effort contact-details lookup.
  Future<ContactDetails?> fetchDirectoryProfile(String email) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/users/${Uri.encodeComponent(email)}',
        queryParameters: {
          '\$select': 'displayName,jobTitle,department,companyName,'
              'mobilePhone,businessPhones,officeLocation,mail,userPrincipalName',
        },
      );
      final data = response.data;
      if (data == null) return null;

      final phones = <String>[
        if ((data['mobilePhone'] as String?)?.isNotEmpty ?? false)
          data['mobilePhone'] as String,
        ...((data['businessPhones'] as List<dynamic>? ?? [])
            .whereType<String>()
            .where((p) => p.isNotEmpty)),
      ];

      return ContactDetails(
        address: data['mail'] as String? ??
            data['userPrincipalName'] as String? ??
            email,
        name: data['displayName'] as String?,
        jobTitle: data['jobTitle'] as String?,
        department: data['department'] as String?,
        companyName: data['companyName'] as String?,
        officeLocation: data['officeLocation'] as String?,
        phoneNumbers: phones,
      );
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 404 || status == 403) return null;
      throw _mapDioException(e);
    }
  }

  /// Fetches profile fields useful for prefilling the Settings "Profile"
  /// section (and email signature merge tags): given/family name, job title,
  /// and phone numbers, via Graph's `/me`. Returns null on 403 (the
  /// `User.Read`/`User.Read.All` scope hasn't been granted) — a silent,
  /// expected case for a best-effort prefill.
  Future<
      ({
        String firstName,
        String lastName,
        String jobTitle,
        String phone,
        String mobile
      })?> fetchOwnSignatureProfile() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/me',
        queryParameters: {
          '\$select': 'givenName,surname,jobTitle,mobilePhone,businessPhones',
        },
      );
      final data = response.data;
      if (data == null) return null;

      final businessPhones = (data['businessPhones'] as List<dynamic>? ?? [])
          .whereType<String>()
          .where((p) => p.isNotEmpty)
          .toList();

      return (
        firstName: data['givenName'] as String? ?? '',
        lastName: data['surname'] as String? ?? '',
        jobTitle: data['jobTitle'] as String? ?? '',
        phone: businessPhones.isNotEmpty ? businessPhones.first : '',
        mobile: data['mobilePhone'] as String? ?? '',
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 403) return null;
      throw _mapDioException(e);
    }
  }

  /// Graph's maximum page size is 999 for `/users` and `/me/contacts`; `/me/people`
  /// caps out lower but accepts the larger value and clamps it itself.
  static const _bulkPageSize = 999;

  /// Ceiling on pages per collection — 25 × 999 covers any tenant we expect to
  /// see. Hitting it is reported through [BulkFetchResult.truncated] rather
  /// than silently returning a partial directory as if it were whole.
  static const _maxBulkPages = 25;

  /// Pulls this account's entire address book — Outlook contacts, the Entra
  /// directory, and Graph's relevance-ranked `/me/people` — as raw, undecoded
  /// page bodies for [parseGraphContactPages] to handle off the UI isolate.
  /// Backs the daily cache refresh, not the typeahead.
  ///
  /// Each collection fails independently. `Contacts.Read` and `People.Read`
  /// were added to the requested scopes after the first release, so accounts
  /// authorised before that keep a token without them and 403 on two of the
  /// three until they are signed in again from Settings; the directory (which
  /// only needs the long-standing `User.Read.All`) still populates meanwhile.
  Future<BulkFetchResult<GraphContactPages>> fetchAllContacts() async {
    final failures = <String>[];
    var truncated = false;

    Future<List<String>> collect(
      String label,
      String path,
      Map<String, dynamic> params,
    ) async {
      try {
        final result = await _fetchAllGraphPages(path, params);
        if (result.truncated) truncated = true;
        return result.pages;
      } catch (e) {
        failures.add('$label: ${_describeBulk(e)}');
        return const [];
      }
    }

    final results = await Future.wait([
      collect('contacts', '/me/contacts', {
        '\$select': 'displayName,emailAddresses',
        '\$top': _bulkPageSize,
      }),
      collect('directory', '/users', {
        '\$select': 'displayName,mail,userPrincipalName',
        '\$top': _bulkPageSize,
      }),
      collect('people', '/me/people', {
        '\$select': 'displayName,scoredEmailAddresses',
        '\$top': _bulkPageSize,
      }),
    ]);

    return BulkFetchResult(
      data: GraphContactPages(
        personalContacts: results[0],
        directoryUsers: results[1],
        people: results[2],
      ),
      failures: failures,
      truncated: truncated,
    );
  }

  /// Walks one Graph collection, following `@odata.nextLink` until it runs out
  /// or [_maxBulkPages] is reached. Bodies come back undecoded
  /// (`ResponseType.plain`) so the JSON parse can happen in a background
  /// isolate.
  Future<({List<String> pages, bool truncated})> _fetchAllGraphPages(
    String path,
    Map<String, dynamic> baseParams,
  ) async {
    final pages = <String>[];
    // nextLink is an absolute URL with the paging state already baked in, so
    // after the first request the query parameters must not be re-applied.
    String? nextLink;
    for (var i = 0; i < _maxBulkPages; i++) {
      final resp = await _dio.get<String>(
        nextLink ?? path,
        queryParameters: nextLink == null ? baseParams : null,
        options: Options(responseType: ResponseType.plain),
      );
      final body = resp.data;
      if (body == null || body.isEmpty) break;
      pages.add(body);
      nextLink = graphNextLink(body);
      if (nextLink == null) return (pages: pages, truncated: false);
    }
    return (pages: pages, truncated: nextLink != null);
  }

  static String _describeBulk(Object e) {
    if (e is DioException) {
      return 'HTTP ${e.response?.statusCode ?? e.type.name}';
    }
    return e.toString();
  }

  /// Best-effort photo fetch — any failure (no photo set, no permission)
  /// resolves to null rather than surfacing an error, since the photo is
  /// purely decorative in the contact-details card.
  Future<Uint8List?> fetchDirectoryPhoto(String email) async {
    try {
      final response = await _dio.get<List<int>>(
        '/users/${Uri.encodeComponent(email)}/photo/\$value',
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      return data == null ? null : Uint8List.fromList(data);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> sendEmail({
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    try {
      final attachmentsList = await _buildGraphAttachments(newAttachments);
      await _dio.post<void>(
        '/me/sendMail',
        data: {
          'message': {
            'subject': subject,
            // Sent verbatim under whichever contentType it was composed as.
            // Escaping a plain-text body and turning its newlines into <br>
            // while still declaring `text` puts markup into a text/plain part,
            // so the recipient reads the tags and loses every line break.
            'body': {
              'contentType': bodyType == EmailBodyType.html ? 'html' : 'text',
              'content': body,
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
    List<String> toAddresses = const [],
    List<String> ccAddresses = const [],
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    try {
      final messageBody = <String, dynamic>{
        'body': {
          'contentType': bodyType == EmailBodyType.html ? 'html' : 'text',
          'content': comment,
        },
        if (toAddresses.isNotEmpty)
          'toRecipients': toAddresses
              .map((a) => {'emailAddress': {'address': _bareEmail(a)}})
              .toList(),
        if (ccAddresses.isNotEmpty)
          'ccRecipients': ccAddresses
              .map((a) => {'emailAddress': {'address': _bareEmail(a)}})
              .toList(),
      };

      if (newAttachments.isEmpty) {
        final path = replyAll
            ? '/me/messages/$messageId/replyAll'
            : '/me/messages/$messageId/reply';
        await _dio.post<void>(path, data: {'message': messageBody});
      } else {
        // Create a draft reply, attach files, then send.
        final createPath = replyAll
            ? '/me/messages/$messageId/createReplyAll'
            : '/me/messages/$messageId/createReply';
        final draftResp = await _dio.post<Map<String, dynamic>>(
          createPath,
          data: {'message': messageBody},
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
    List<String> ccAddresses = const [],
    required String comment,
    List<String> excludedAttachmentIds = const [],
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    try {
      // Use message.body instead of comment so Graph doesn't auto-append the
      // original (which would double-quote since we've already embedded it).
      final messageBody = <String, dynamic>{
        'body': {
          'contentType': bodyType == EmailBodyType.html ? 'html' : 'text',
          'content': comment,
        },
        if (ccAddresses.isNotEmpty)
          'ccRecipients': ccAddresses
              .map((a) => {'emailAddress': {'address': _bareEmail(a)}})
              .toList(),
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
          if (att.isInline) 'isInline': true,
          if (att.isInline && att.contentId != null) 'contentId': att.contentId,
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
        if (att.isInline) 'isInline': true,
        if (att.isInline && att.contentId != null) 'contentId': att.contentId,
      });
    }
  }

  /// Reconciles the draft's server-side attachments with [desired].
  /// Uploads attachments missing from the server; deletes ones no longer
  /// wanted. Attachments are matched by name + size so unchanged files are
  /// not re-uploaded on every auto-save.
  Future<void> _syncDraftAttachments(
      String draftId, List<LocalAttachment> desired) async {
    if (desired.isEmpty) return;

    // $select must use only base attachment properties (id, name, size);
    // derived-type fields like isInline/contentId are not valid on the base
    // attachment type and cause a 400 from Graph.
    final resp = await _dio.get<Map<String, dynamic>>(
      '/me/messages/$draftId/attachments',
      queryParameters: {'\$select': 'id,name,size'},
    );
    final existing = (resp.data?['value'] as List<dynamic>?)
            ?.cast<Map<String, dynamic>>() ??
        [];

    for (final e in existing) {
      final eName = e['name'] as String? ?? '';
      final eSize = (e['size'] as int?) ?? 0;
      final stillWanted = desired.any((a) =>
          a.name == eName && a.bytes.length == eSize);
      if (!stillWanted) {
        final id = e['id'] as String?;
        if (id != null) {
          await _dio.delete<void>('/me/messages/$draftId/attachments/$id');
        }
      }
    }

    for (final att in desired) {
      final alreadyThere = existing.any((e) =>
          (e['name'] as String? ?? '') == att.name &&
          ((e['size'] as int?) ?? 0) == att.bytes.length);
      if (!alreadyThere) {
        await _dio.post<void>('/me/messages/$draftId/attachments', data: {
          '@odata.type': '#microsoft.graph.fileAttachment',
          'name': att.name,
          'contentType': att.mimeType,
          'contentBytes': base64.encode(att.bytes),
          if (att.isInline) 'isInline': true,
          if (att.isInline && att.contentId != null) 'contentId': att.contentId,
        });
      }
    }
  }

  @override
  Future<String?> moveEmail(String id, String destinationFolderId) async {
    try {
      // Graph returns 201 Created with the moved message resource — moving
      // creates a new copy in the destination folder and removes the
      // original, so the response's id differs from [id].
      final response = await _dio.post<Map<String, dynamic>>(
        '/me/messages/$id/move',
        data: {'destinationId': destinationFolderId},
      );
      return response.data?['id'] as String?;
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<String?> reportJunk(String id) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/me/messages/$id/move',
        data: {'destinationId': 'junkemail'},
      );
      return response.data?['id'] as String?;
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

  /// Messages per delta page, and how many pages one call will follow.
  ///
  /// This is what bounds an initial sync, and it is deliberately a *client-side*
  /// bound: Graph encodes the originating request's query options into the
  /// `@odata.deltaLink` it hands back, so a `$filter` on `receivedDateTime`
  /// would be frozen into the token for its whole life and every change to a
  /// message older than that cutoff would be invisible for ever after.
  ///
  /// 20 × 50 is ~1000 messages — years of inbox for most people, and a bounded
  /// number of sequential round trips for a mailbox with far more. Nothing is
  /// lost when the budget runs out: the page cursor is handed back in place of
  /// the token, so the next poll carries on from there.
  static const _deltaPageSize = 50;
  static const _deltaPageBudget = 20;

  @override
  Future<MailDeltaResult> syncMailDelta(
    String folderId, {
    String? deltaLink,
  }) async {
    // Pages are collected undecoded and parsed together at the end, off the UI
    // isolate. Paging itself has to stay here: each page's next link is only
    // known once that page has arrived.
    final rawPages = <String>[];

    String? nextUrl = deltaLink;
    bool isInitial = deltaLink == null;
    var pagesFetched = 0;

    try {
      while (true) {
        final Response<String> response;

        if (isInitial) {
          isInitial = false;
          response = await _dio.get<String>(
            '/me/mailFolders/$folderId/messages/delta',
            queryParameters: {
              '\$select': _emailListSelect,
              '\$top': _deltaPageSize,
            },
            options: Options(responseType: ResponseType.plain),
          );
        } else {
          // nextLink / deltaLink are full absolute URLs — Dio uses them as-is.
          response = await _dio.get<String>(
            nextUrl!,
            options: Options(responseType: ResponseType.plain),
          );
        }

        final raw = response.data ?? '';
        if (raw.isNotEmpty) rawPages.add(raw);
        pagesFetched++;

        // A delta link means the sync is complete. Without one, the page cursor
        // stands in as the token once the budget is spent — the replay branch
        // above follows a nextLink exactly as it follows a delta link, so the
        // next poll resumes where this one stopped rather than starting over.
        final link = graphDeltaLink(raw) ??
            (pagesFetched >= _deltaPageBudget ? graphNextLink(raw) : null);
        if (link != null) {
          final parsed = await compute(parseGraphDeltaPages, rawPages);
          return MailDeltaResult(
            upserted: parsed.upserted,
            removedIds: parsed.removedIds,
            deltaLink: link,
          );
        }

        nextUrl = graphNextLink(raw);
        if (nextUrl == null) break;
      }
    } on DioException catch (e) {
      throw _mapDioException(e);
    }

    throw const ServerException(
        message: 'Delta query completed without returning a delta link');
  }

  /// Addresses per `getSchedule` call. The room picker asks about every room it
  /// is showing at once, which is a much longer list than a guest roster, and
  /// Exchange starts refusing large batches outright rather than truncating.
  static const _scheduleBatchSize = 20;

  @override
  Future<List<AttendeeAvailability>> getAttendeesSchedule({
    required List<String> emails,
    required DateTime start,
    required DateTime end,
  }) async {
    if (emails.length <= _scheduleBatchSize) {
      return _getAttendeesScheduleBatch(emails: emails, start: start, end: end);
    }

    final batches = <List<String>>[];
    for (var i = 0; i < emails.length; i += _scheduleBatchSize) {
      batches.add(emails.sublist(
          i, (i + _scheduleBatchSize).clamp(0, emails.length)));
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

  /// Rooms in the tenant, by lower-cased address, once [getMeetingRooms] has
  /// run. Only used to label a booked room in the event body — the picker gets
  /// its copy through the repository, which caches for itself.
  final Map<String, MeetingRoom> _roomsByEmail = {};

  /// Graph's page size for rooms is 100 and `$top` raises it. Asked for
  /// explicitly so a tenant with a few hundred rooms is one or two requests
  /// rather than three or four.
  static const _roomPageSize = 500;

  /// Guard against a pathological tenant (or a nextLink loop) turning the room
  /// picker into an unbounded fetch.
  static const _maxRoomPages = 10;

  @override
  Future<List<MeetingRoom>> getMeetingRooms() async {
    final rooms = await _fetchRoomsFromPlaces() ?? await _fetchRoomsFromFindRooms();
    _roomsByEmail
      ..clear()
      ..addEntries(
          rooms.map((r) => MapEntry(r.email.toLowerCase(), r)));
    return rooms;
  }

  /// `/places/microsoft.graph.room` — the v1.0 room directory, which carries
  /// capacity, building and floor.
  ///
  /// Returns null (rather than an empty list) when the tenant will not answer,
  /// so the caller can tell "no permission" from "no rooms" and fall back.
  /// `Place.Read.All` was added to the requested scopes after release, so an
  /// account authorised earlier holds a token without it and 403s here until it
  /// is re-authenticated from Settings.
  Future<List<MeetingRoom>?> _fetchRoomsFromPlaces() async {
    final rooms = <MeetingRoom>[];
    var path = '/places/microsoft.graph.room?\$top=$_roomPageSize';

    for (var page = 0; page < _maxRoomPages; page++) {
      final Response<Map<String, dynamic>> response;
      try {
        response = await _dio.get<Map<String, dynamic>>(path);
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        if (status == 401 || status == 403 || status == 404) {
          debugPrint('[Graph] /places denied ($status) — the account most '
              'likely predates the Place.Read.All scope; falling back to '
              'findRooms. Sign in again from Settings to restore the full '
              'room directory.');
          return null;
        }
        // A partial first page is still worth showing; a partial later page
        // means we keep what we already read rather than losing all of it.
        if (rooms.isEmpty) return null;
        debugPrint('[Graph] /places paging stopped early: ${e.message}');
        return rooms;
      }

      final value = response.data?['value'] as List<dynamic>? ?? const [];
      rooms.addAll(value
          .cast<Map<String, dynamic>>()
          .map(_roomFromPlace)
          .whereType<MeetingRoom>());

      final next = response.data?['@odata.nextLink'] as String?;
      if (next == null || next.isEmpty) return rooms;
      path = next;
    }
    return rooms;
  }

  /// `beta/me/findRooms` — every room the *mailbox* can see, with nothing but a
  /// name and an address.
  ///
  /// The fallback for a token without `Place.Read.All`: it needs only the
  /// calendar permissions the app already holds, so it keeps the picker working
  /// for accounts that have not been re-authenticated. Beta because Graph never
  /// promoted it to v1.0 — `/places` is its v1.0 replacement, which is exactly
  /// the endpoint we could not reach if we are here.
  Future<List<MeetingRoom>> _fetchRoomsFromFindRooms() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        'https://graph.microsoft.com/beta/me/findRooms',
      );
      final value = response.data?['value'] as List<dynamic>? ?? const [];
      return value
          .cast<Map<String, dynamic>>()
          .map((r) {
            final email = r['address'] as String? ?? '';
            if (email.isEmpty) return null;
            return MeetingRoom(
              email: email,
              displayName: (r['name'] as String?)?.trim().isNotEmpty == true
                  ? r['name'] as String
                  : email,
            );
          })
          .whereType<MeetingRoom>()
          .toList();
    } on DioException catch (e) {
      // Nothing left to try. An empty dropdown is the honest outcome — a
      // failure here must not stop the user saving the event.
      debugPrint('[Graph] findRooms unavailable: ${e.message}');
      return const [];
    }
  }

  MeetingRoom? _roomFromPlace(Map<String, dynamic> json) {
    final email = json['emailAddress'] as String? ?? '';
    if (email.isEmpty) return null;
    final floor = json['floorNumber'];
    return MeetingRoom(
      email: email,
      displayName: (json['displayName'] as String?)?.trim().isNotEmpty == true
          ? json['displayName'] as String
          : email,
      capacity: json['capacity'] as int?,
      building: json['building'] as String?,
      floorLabel: floor == null ? null : '$floor',
      isWheelchairAccessible:
          json['isWheelChairAccessible'] as bool? ?? false,
    );
  }

  /// The directory name for a booked room, falling back to the address' local
  /// part when the room directory was never read (a saved event whose rooms came
  /// from the cache rather than the picker).
  String _roomDisplayName(String email) {
    final known = _roomsByEmail[email.toLowerCase()];
    if (known != null) return known.displayName;
    final localPart = email.split('@').first;
    return localPart.isEmpty ? email : localPart;
  }

  /// Whether the free-text location is just a room's name repeated, which is
  /// what happens when the form shows "Room A" in the field and also books it.
  /// Adding it again would give the meeting two locations for one place.
  bool _locationNamesARoom(String location, List<String> roomEmails) {
    final needle = location.trim().toLowerCase();
    return roomEmails.any((e) =>
        _roomDisplayName(e).trim().toLowerCase() == needle ||
        e.trim().toLowerCase() == needle);
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

  @override
  Future<void> renameFolder({
    required String folderId,
    required String newDisplayName,
  }) async {
    try {
      await _dio.patch<void>(
        '/me/mailFolders/$folderId',
        data: {'displayName': newDisplayName},
      );
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<void> moveFolder({
    required String folderId,
    required String newParentFolderId,
  }) async {
    try {
      // Graph's native move preserves the folder id and moves all sub-folders.
      await _dio.post<void>(
        '/me/mailFolders/$folderId/move',
        data: {'destinationId': newParentFolderId},
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
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    try {
      final contentType = bodyType == EmailBodyType.html ? 'Html' : 'Text';
      final resp = await _dio.post<Map<String, dynamic>>(
        '/me/messages',
        data: {
          'subject': subject,
          'body': {'contentType': contentType, 'content': body},
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
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    try {
      final contentType = bodyType == EmailBodyType.html ? 'Html' : 'Text';
      await _dio.patch<void>(
        '/me/messages/$draftId',
        data: {
          'subject': subject,
          'body': {'contentType': contentType, 'content': body},
          'toRecipients':
              toAddresses.map((a) => {'emailAddress': {'address': a}}).toList(),
          if (ccAddresses.isNotEmpty)
            'ccRecipients': ccAddresses
                .map((a) => {'emailAddress': {'address': a}})
                .toList(),
        },
      );
      await _syncDraftAttachments(draftId, newAttachments);
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

    // Deliberately do not fall back to e.message here: for a bad HTTP
    // response Dio's default message is its own internal boilerplate
    // ("...RequestOptions.validateStatus was configured to throw..."),
    // which is meaningless to a user and must never reach the UI.
    final msg = _extractGraphErrorMessage(e) ??
        (statusCode != null ? 'Server error ($statusCode)' : e.message) ??
        'Unknown server error';
    return ServerException(message: msg, statusCode: statusCode);
  }

  String? _extractGraphErrorMessage(DioException e) {
    try {
      final data = e.response?.data;
      // The message-fetch requests ask for ResponseType.plain so the parse can
      // happen in a background isolate, which means *their* error bodies arrive
      // as an undecoded String rather than a Map. Without this branch a failed
      // message fetch loses Graph's own explanation and falls back to a bare
      // "Server error (400)".
      if (data is String) {
        if (data.isEmpty) return null;
        final decoded = jsonDecode(data);
        if (decoded is Map) {
          return (decoded['error'] as Map?)?['message'] as String?;
        }
        return null;
      }
      if (data is Map) {
        final error = data['error'] as Map?;
        return error?['message'] as String?;
      }
    } catch (_) {}
    return null;
  }
}
