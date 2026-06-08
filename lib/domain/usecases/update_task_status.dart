import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/todo_task.dart';
import '../repositories/tasks_repository.dart';

class UpdateTaskStatus implements UseCase<TodoTask, UpdateTaskStatusParams> {
  const UpdateTaskStatus(this._repository);

  final TasksRepository _repository;

  @override
  Future<Either<Failure, TodoTask>> call(UpdateTaskStatusParams params) {
    return _repository.updateTaskStatus(
      listId: params.listId,
      taskId: params.taskId,
      status: params.status,
    );
  }
}

class UpdateTaskStatusParams extends Equatable {
  const UpdateTaskStatusParams({
    required this.listId,
    required this.taskId,
    required this.status,
  });

  final String listId;
  final String taskId;
  final TodoTaskStatus status;

  @override
  List<Object?> get props => [listId, taskId, status];
}
