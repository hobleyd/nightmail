import '../../../domain/entities/todo_task.dart';
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
}
