import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/todo_task.dart';
import '../repositories/tasks_repository.dart';

class UpdateTaskDueDate implements UseCase<TodoTask, UpdateTaskDueDateParams> {
  const UpdateTaskDueDate(this._repository);

  final TasksRepository _repository;

  @override
  Future<Either<Failure, TodoTask>> call(UpdateTaskDueDateParams params) {
    return _repository.updateTaskDueDate(
      listId: params.listId,
      taskId: params.taskId,
      dueDate: params.dueDate,
    );
  }
}

class UpdateTaskDueDateParams extends Equatable {
  const UpdateTaskDueDateParams({
    required this.listId,
    required this.taskId,
    required this.dueDate,
  });

  final String listId;
  final String taskId;
  final DateTime? dueDate;

  @override
  List<Object?> get props => [listId, taskId, dueDate];
}
