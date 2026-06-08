import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/todo_task_attachment.dart';
import '../repositories/tasks_repository.dart';

class GetTaskAttachments
    implements UseCase<List<TodoTaskAttachment>, GetTaskAttachmentsParams> {
  const GetTaskAttachments(this._repository);

  final TasksRepository _repository;

  @override
  Future<Either<Failure, List<TodoTaskAttachment>>> call(
      GetTaskAttachmentsParams params) {
    return _repository.getTaskAttachments(
      listId: params.listId,
      taskId: params.taskId,
    );
  }
}

class GetTaskAttachmentsParams extends Equatable {
  const GetTaskAttachmentsParams({
    required this.listId,
    required this.taskId,
  });

  final String listId;
  final String taskId;

  @override
  List<Object?> get props => [listId, taskId];
}
