import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/tasks_repository.dart';

class DownloadTaskAttachment
    implements UseCase<Uint8List, DownloadTaskAttachmentParams> {
  const DownloadTaskAttachment(this._repository);

  final TasksRepository _repository;

  @override
  Future<Either<Failure, Uint8List>> call(
      DownloadTaskAttachmentParams params) {
    return _repository.downloadTaskAttachment(
      listId: params.listId,
      taskId: params.taskId,
      attachmentId: params.attachmentId,
    );
  }
}

class DownloadTaskAttachmentParams extends Equatable {
  const DownloadTaskAttachmentParams({
    required this.listId,
    required this.taskId,
    required this.attachmentId,
  });

  final String listId;
  final String taskId;
  final String attachmentId;

  @override
  List<Object?> get props => [listId, taskId, attachmentId];
}
