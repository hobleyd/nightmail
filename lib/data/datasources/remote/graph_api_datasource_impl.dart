import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/error/exceptions.dart';
import '../../../domain/entities/calendar_recurrence.dart';
import '../../../domain/entities/todo_task.dart';
import '../../../domain/usecases/create_calendar_event.dart';
import '../../../domain/usecases/update_calendar_event.dart';
import '../../../infrastructure/http/graph_http_client.dart';
import '../../models/calendar_event_model.dart';
import '../../models/email_folder_model.dart';
import '../../models/email_model.dart';
import '../../models/todo_task_attachment_model.dart';
import '../../models/todo_task_list_model.dart';
import '../../models/todo_task_model.dart';
import 'calendar_remote_datasource.dart';
import 'email_remote_datasource.dart';
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

final _emailDetailSelect = '$_emailListSelect,body';

class GraphApiDatasourceImpl
    implements EmailRemoteDatasource, CalendarRemoteDatasource, TasksRemoteDatasource {
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
          '\$select': _emailDetailSelect,
          '\$expand': r'attachments($select=id,name,contentType,size,isInline)',
        },
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
              'id,subject,start,end,isAllDay,location,bodyPreview,showAs,isOrganizer,attendees,recurrence',
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
  }) {
    final body = <String, dynamic>{
      'subject': subject,
      'isAllDay': isAllDay,
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

  @override
  Future<void> sendEmail({
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
  }) async {
    try {
      await _dio.post<void>(
        '/me/sendMail',
        data: {
          'message': {
            'subject': subject,
            'body': {'contentType': 'Text', 'content': body},
            'toRecipients': toAddresses
                .map((a) => {'emailAddress': {'address': a}})
                .toList(),
            if (ccAddresses.isNotEmpty)
              'ccRecipients': ccAddresses
                  .map((a) => {'emailAddress': {'address': a}})
                  .toList(),
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
  }) async {
    final path = replyAll
        ? '/me/messages/$messageId/replyAll'
        : '/me/messages/$messageId/reply';
    try {
      await _dio.post<void>(path, data: {'comment': comment});
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  Future<void> forwardEmail({
    required String messageId,
    required List<String> toAddresses,
    required String comment,
  }) async {
    try {
      await _dio.post<void>(
        '/me/messages/$messageId/forward',
        data: {
          'comment': comment,
          'toRecipients': toAddresses
              .map((a) => {'emailAddress': {'address': a}})
              .toList(),
        },
      );
    } on DioException catch (e) {
      throw _mapDioException(e);
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
