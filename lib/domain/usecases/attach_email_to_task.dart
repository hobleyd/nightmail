import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/todo_task_attachment.dart';
import '../repositories/email_repository.dart';
import '../repositories/tasks_repository.dart';

class AttachEmailToTask
    implements UseCase<TodoTaskAttachment, AttachEmailToTaskParams> {
  const AttachEmailToTask(this._emailRepository, this._tasksRepository);

  final EmailRepository _emailRepository;
  final TasksRepository _tasksRepository;

  @override
  Future<Either<Failure, TodoTaskAttachment>> call(
      AttachEmailToTaskParams params) async {
    final bytesResult = await _emailRepository.getRawEmailBytes(params.emailId);
    return bytesResult.fold(
      Left.new,
      (bytes) => _tasksRepository.attachEmailToTask(
        listId: params.listId,
        taskId: params.taskId,
        fileName: params.fileName,
        emlBytes: bytes,
      ),
    );
  }
}

class AttachEmailToTaskParams extends Equatable {
  const AttachEmailToTaskParams({
    required this.emailId,
    required this.listId,
    required this.taskId,
    required this.fileName,
  });

  final String emailId;
  final String listId;
  final String taskId;
  final String fileName;

  @override
  List<Object?> get props => [emailId, listId, taskId, fileName];
}
