import 'package:dio/dio.dart';

import '../../../core/error/exceptions.dart';
import '../../../infrastructure/http/graph_http_client.dart';
import '../../models/calendar_event_model.dart';
import '../../models/email_folder_model.dart';
import '../../models/email_model.dart';
import 'calendar_remote_datasource.dart';
import 'email_remote_datasource.dart';

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
    implements EmailRemoteDatasource, CalendarRemoteDatasource {
  GraphApiDatasourceImpl({required GraphHttpClient client})
      : _dio = client.dio;

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
          if (filter != null) '\$filter': filter,
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

      return EmailModel.fromJson(response.data!);
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
              'id,subject,start,end,isAllDay,location,bodyPreview,showAs,isOrganizer',
          '\$orderby': 'start/dateTime asc',
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
  Future<void> deleteEmail(String id) async {
    try {
      await _dio.delete<void>('/me/messages/$id');
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
