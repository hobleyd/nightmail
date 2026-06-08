import 'dart:typed_data';

import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/todo_task.dart';
import '../entities/todo_task_attachment.dart';
import '../entities/todo_task_list.dart';

abstract interface class TasksRepository {
  Future<Either<Failure, List<TodoTaskList>>> getTaskLists();

  Future<Either<Failure, List<TodoTask>>> getTasks(
    String listId, {
    bool includeCompleted = false,
  });

  Future<Either<Failure, TodoTask>> createTask({
    required String listId,
    required String title,
    String? body,
    DateTime? dueDate,
    TodoTaskImportance importance = TodoTaskImportance.normal,
  });

  Future<Either<Failure, TodoTask>> updateTaskStatus({
    required String listId,
    required String taskId,
    required TodoTaskStatus status,
  });

  Future<Either<Failure, TodoTask>> updateTaskDueDate({
    required String listId,
    required String taskId,
    required DateTime? dueDate,
  });

  Future<Either<Failure, TodoTaskAttachment>> attachEmailToTask({
    required String listId,
    required String taskId,
    required String fileName,
    required Uint8List emlBytes,
  });

  Future<Either<Failure, List<TodoTaskAttachment>>> getTaskAttachments({
    required String listId,
    required String taskId,
  });

  Future<Either<Failure, Uint8List>> downloadTaskAttachment({
    required String listId,
    required String taskId,
    required String attachmentId,
  });
}
