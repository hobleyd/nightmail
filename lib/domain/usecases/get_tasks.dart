import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/todo_task.dart';
import '../repositories/tasks_repository.dart';

class GetTasks implements UseCase<List<TodoTask>, GetTasksParams> {
  const GetTasks(this._repository);

  final TasksRepository _repository;

  @override
  Future<Either<Failure, List<TodoTask>>> call(GetTasksParams params) {
    return _repository.getTasks(
      params.listId,
      includeCompleted: params.includeCompleted,
    );
  }
}

class GetTasksParams extends Equatable {
  const GetTasksParams({
    required this.listId,
    this.includeCompleted = false,
  });

  final String listId;
  final bool includeCompleted;

  @override
  List<Object?> get props => [listId, includeCompleted];
}
