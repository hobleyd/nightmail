import 'dart:typed_data';

import '../../../domain/entities/todo_task.dart';
import '../../models/todo_task_attachment_model.dart';
import '../../models/todo_task_list_model.dart';
import '../../models/todo_task_model.dart';

abstract interface class TasksRemoteDatasource {
  Future<List<TodoTaskListModel>> getTaskLists();

  Future<List<TodoTaskModel>> getTasks(
    String listId, {
    bool includeCompleted = false,
  });

  Future<TodoTaskModel> createTask({
    required String listId,
    required String title,
    String? body,
    DateTime? dueDate,
    TodoTaskImportance importance = TodoTaskImportance.normal,
  });

  Future<TodoTaskModel> updateTaskStatus({
    required String listId,
    required String taskId,
    required TodoTaskStatus status,
  });

  Future<TodoTaskModel> updateTaskDueDate({
    required String listId,
    required String taskId,
    required DateTime? dueDate,
  });

  Future<TodoTaskAttachmentModel> attachEmailToTask({
    required String listId,
    required String taskId,
    required String fileName,
    required Uint8List emlBytes,
  });

  /// Appends a `nightmail://email/<emailId>` marker to the task's notes and
  /// returns the updated task. For providers without attachment support.
  Future<TodoTaskModel> appendEmailLinkToNotes({
    required String listId,
    required String taskId,
    required String emailId,
  });

  Future<List<TodoTaskAttachmentModel>> getTaskAttachments({
    required String listId,
    required String taskId,
  });

  Future<Uint8List> downloadTaskAttachment({
    required String listId,
    required String taskId,
    required String attachmentId,
  });
}
