import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/todo_task.dart';
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
}
