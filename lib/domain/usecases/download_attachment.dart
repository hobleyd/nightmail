import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/email_repository.dart';

class DownloadAttachment
    implements UseCase<Uint8List, DownloadAttachmentParams> {
  const DownloadAttachment(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, Uint8List>> call(DownloadAttachmentParams params) {
    return _repository.downloadAttachment(
      messageId: params.messageId,
      attachmentId: params.attachmentId,
    );
  }
}

class DownloadAttachmentParams extends Equatable {
  const DownloadAttachmentParams({
    required this.messageId,
    required this.attachmentId,
  });

  final String messageId;
  final String attachmentId;

  @override
  List<Object?> get props => [messageId, attachmentId];
}
