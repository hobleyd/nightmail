import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/todo_task_list.dart';
import '../repositories/tasks_repository.dart';

class GetTaskLists implements UseCase<List<TodoTaskList>, NoParams> {
  const GetTaskLists(this._repository);

  final TasksRepository _repository;

  @override
  Future<Either<Failure, List<TodoTaskList>>> call(NoParams params) {
    return _repository.getTaskLists();
  }
}
