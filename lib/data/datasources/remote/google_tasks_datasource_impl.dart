import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/error/exceptions.dart';
import '../../../domain/entities/todo_task.dart';
import '../../../infrastructure/http/google_tasks_http_client.dart';
import '../../models/todo_task_attachment_model.dart';
import '../../models/todo_task_list_model.dart';
import '../../models/todo_task_model.dart';
import 'tasks_remote_datasource.dart';

class GoogleTasksDatasourceImpl implements TasksRemoteDatasource {
  GoogleTasksDatasourceImpl({required GoogleTasksHttpClient client})
      : _dio = client.dio;

  final Dio _dio;

  @override
  Future<List<TodoTaskListModel>> getTaskLists() async {
    try {
      final response =
          await _dio.get<Map<String, dynamic>>('/users/@me/lists');
      final data = response.data;
      if (data == null) return [];

      final items = (data['items'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();

      return items
          .asMap()
          .entries
          .map((entry) => TodoTaskListModel(
                id: entry.value['id'] as String,
                displayName: entry.value['title'] as String? ?? 'Tasks',
                isDefault: entry.key == 0,
              ))
          .toList();
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<List<TodoTaskModel>> getTasks(
    String listId, {
    bool includeCompleted = false,
  }) async {
    try {
      final tasks = <TodoTaskModel>[];
      String? pageToken;

      do {
        final response = await _dio.get<Map<String, dynamic>>(
          '/lists/$listId/tasks',
          queryParameters: {
            'maxResults': 100,
            'showCompleted': includeCompleted,
            'showHidden': false,
            if (pageToken != null) 'pageToken': pageToken,
          },
        );

        final data = response.data;
        if (data == null) break;

        final items = (data['items'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();

        for (final item in items) {
          if (item['deleted'] == true) continue;
          tasks.add(_parseTask(item, listId: listId));
        }

        pageToken = data['nextPageToken'] as String?;
      } while (pageToken != null);

      return tasks;
    } on DioException catch (e) {
      throw _mapException(e);
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
      final payload = <String, dynamic>{
        'title': title,
        'status': 'needsAction',
        if (body != null && body.isNotEmpty) 'notes': body,
        if (dueDate != null) 'due': _formatDueDate(dueDate),
      };

      final response = await _dio.post<Map<String, dynamic>>(
        '/lists/$listId/tasks',
        data: payload,
      );

      if (response.data == null) {
        throw const ServerException(message: 'Empty response from server');
      }
      return _parseTask(response.data!, listId: listId);
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<TodoTaskModel> updateTaskStatus({
    required String listId,
    required String taskId,
    required TodoTaskStatus status,
  }) async {
    try {
      final googleStatus =
          status == TodoTaskStatus.completed ? 'completed' : 'needsAction';

      final response = await _dio.patch<Map<String, dynamic>>(
        '/lists/$listId/tasks/$taskId',
        data: {'status': googleStatus},
      );

      if (response.data == null) {
        throw const ServerException(message: 'Empty response from server');
      }
      return _parseTask(response.data!, listId: listId);
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<TodoTaskModel> updateTaskDueDate({
    required String listId,
    required String taskId,
    required DateTime? dueDate,
  }) async {
    try {
      final payload = <String, dynamic>{
        'due': dueDate != null ? _formatDueDate(dueDate) : null,
      };

      final response = await _dio.patch<Map<String, dynamic>>(
        '/lists/$listId/tasks/$taskId',
        data: payload,
      );

      if (response.data == null) {
        throw const ServerException(message: 'Empty response from server');
      }
      return _parseTask(response.data!, listId: listId);
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<TodoTaskAttachmentModel> attachEmailToTask({
    required String listId,
    required String taskId,
    required String fileName,
    required Uint8List emlBytes,
  }) async {
    throw const ServerException(
      message: 'Email attachment is not supported for Google Tasks',
    );
  }

  @override
  Future<List<TodoTaskAttachmentModel>> getTaskAttachments({
    required String listId,
    required String taskId,
  }) async {
    return [];
  }

  @override
  Future<Uint8List> downloadTaskAttachment({
    required String listId,
    required String taskId,
    required String attachmentId,
  }) async {
    throw const ServerException(
      message: 'Attachments are not supported for Google Tasks',
    );
  }

  TodoTaskModel _parseTask(Map<String, dynamic> json, {required String listId}) {
    final status = json['status'] == 'completed'
        ? TodoTaskStatus.completed
        : TodoTaskStatus.notStarted;

    return TodoTaskModel(
      id: json['id'] as String,
      listId: listId,
      title: json['title'] as String? ?? '(No title)',
      status: status,
      importance: TodoTaskImportance.normal,
      body: json['notes'] as String?,
      dueDateTime: _parseIso(json['due'] as String?),
      completedDateTime: _parseIso(json['completed'] as String?),
      lastModifiedDateTime: _parseIso(json['updated'] as String?),
      hasAttachments: false,
    );
  }

  String _formatDueDate(DateTime date) {
    final utc = date.toUtc();
    final y = utc.year.toString().padLeft(4, '0');
    final m = utc.month.toString().padLeft(2, '0');
    final d = utc.day.toString().padLeft(2, '0');
    return '$y-$m-${d}T00:00:00.000Z';
  }

  DateTime? _parseIso(String? value) {
    if (value == null) return null;
    return DateTime.tryParse(value)?.toLocal();
  }

  Exception _mapException(DioException e) {
    // AuthInterceptor.onRequest can throw AuthException directly (e.g. no
    // stored token, or a failed proactive refresh) before any HTTP request
    // is sent. Dio wraps that throw in a DioException with no response, so
    // it must be unwrapped here or it falls through to a generic
    // ServerException and the UI never learns re-authentication is needed.
    if (e.error is AuthException) return e.error as AuthException;

    final statusCode = e.response?.statusCode;
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return NetworkException(message: e.message ?? 'Network error');
    }

    final (googleMessage, reasons) = _parseGoogleError(e.response?.data);
    assert(() {
      // ignore: avoid_print
      print('[GoogleTasks] HTTP $statusCode reasons=$reasons '
          'message=$googleMessage');
      return true;
    }());

    // A 401 always means the credential is bad — refresh it / re-auth.
    if (statusCode == 401) {
      return const AuthException(message: 'Authentication required');
    }

    if (statusCode == 403) {
      // Only a genuine credential/scope problem should drive the user to
      // re-authenticate. A disabled-API or quota 403 is a project-config
      // problem — routing it to "re-authorize" sends the user in circles
      // (re-auth grants the scope, but the call still 403s).
      const authReasons = {
        'authError',
        'ACCESS_TOKEN_SCOPE_INSUFFICIENT',
        'insufficientPermissions',
      };
      if (reasons.any(authReasons.contains)) {
        return const AuthException(message: 'Authentication required');
      }
      // e.g. accessNotConfigured / SERVICE_DISABLED — surface Google's own
      // message, which includes the console URL to enable the Tasks API.
      return ServerException(
        message: googleMessage ??
            'Google Tasks API is not enabled for this project. '
                'Enable it in the Google Cloud console, then retry.',
        statusCode: statusCode,
      );
    }

    return ServerException(
      message: googleMessage ?? e.message ?? 'Server error ($statusCode)',
      statusCode: statusCode,
    );
  }

  /// Extracts `(message, reasons)` from a Google API error body of the shape
  /// `{ "error": { "message": ..., "errors": [{"reason": ...}],
  /// "details": [{"reason": ...}] } }`. Returns nulls/empties if absent.
  (String?, Set<String>) _parseGoogleError(dynamic data) {
    if (data is! Map) return (null, const {});
    final error = data['error'];
    if (error is! Map) return (null, const {});

    final message = error['message'] as String?;
    final reasons = <String>{};

    final errors = error['errors'];
    if (errors is List) {
      for (final item in errors) {
        if (item is Map && item['reason'] is String) {
          reasons.add(item['reason'] as String);
        }
      }
    }
    final details = error['details'];
    if (details is List) {
      for (final item in details) {
        if (item is Map && item['reason'] is String) {
          reasons.add(item['reason'] as String);
        }
      }
    }
    final status = error['status'];
    if (status is String) reasons.add(status);

    return (message, reasons);
  }
}
