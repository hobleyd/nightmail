import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/todo_task.dart';
import '../repositories/tasks_repository.dart';

class CreateTask implements UseCase<TodoTask, CreateTaskParams> {
  const CreateTask(this._repository);

  final TasksRepository _repository;

  @override
  Future<Either<Failure, TodoTask>> call(CreateTaskParams params) {
    return _repository.createTask(
      listId: params.listId,
      title: params.title,
      body: params.body,
      dueDate: params.dueDate,
      importance: params.importance,
    );
  }
}

class CreateTaskParams extends Equatable {
  const CreateTaskParams({
    required this.listId,
    required this.title,
    this.body,
    this.dueDate,
    this.importance = TodoTaskImportance.normal,
  });

  final String listId;
  final String title;
  final String? body;
  final DateTime? dueDate;
  final TodoTaskImportance importance;

  @override
  List<Object?> get props => [listId, title, body, dueDate, importance];
}
