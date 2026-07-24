import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/todo_task.dart';
import '../repositories/tasks_repository.dart';

/// Links a source email to a task by appending a marker to the task's notes.
/// Used when the provider has no attachment API (e.g. Google Tasks).
class AppendEmailLinkToTask
    implements UseCase<TodoTask, AppendEmailLinkToTaskParams> {
  const AppendEmailLinkToTask(this._tasksRepository);

  final TasksRepository _tasksRepository;

  @override
  Future<Either<Failure, TodoTask>> call(AppendEmailLinkToTaskParams params) {
    return _tasksRepository.appendEmailLink(
      listId: params.listId,
      taskId: params.taskId,
      emailId: params.emailId,
    );
  }
}

class AppendEmailLinkToTaskParams extends Equatable {
  const AppendEmailLinkToTaskParams({
    required this.listId,
    required this.taskId,
    required this.emailId,
  });

  final String listId;
  final String taskId;
  final String emailId;

  @override
  List<Object?> get props => [listId, taskId, emailId];
}
