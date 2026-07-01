import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/email.dart';
import '../entities/local_attachment.dart';
import '../repositories/email_repository.dart';

enum ComposeMode { newEmail, reply, replyAll, forward }

class SendEmail {
  const SendEmail(this._repository);

  final EmailRepository _repository;

  Future<Either<Failure, Unit>> call(SendEmailParams params) {
    return switch (params.mode) {
      ComposeMode.newEmail => _repository.sendEmail(
          toAddresses: params.toAddresses,
          ccAddresses: params.ccAddresses,
          subject: params.subject,
          body: params.body,
          bodyType: params.bodyType,
          newAttachments: params.newAttachments,
        ),
      ComposeMode.reply => _repository.replyToEmail(
          messageId: params.originalMessageId!,
          comment: params.body,
          replyAll: false,
          toAddresses: params.toAddresses,
          ccAddresses: params.ccAddresses,
          bodyType: params.bodyType,
          newAttachments: params.newAttachments,
        ),
      ComposeMode.replyAll => _repository.replyToEmail(
          messageId: params.originalMessageId!,
          comment: params.body,
          replyAll: true,
          toAddresses: params.toAddresses,
          ccAddresses: params.ccAddresses,
          bodyType: params.bodyType,
          newAttachments: params.newAttachments,
        ),
      ComposeMode.forward => _repository.forwardEmail(
          messageId: params.originalMessageId!,
          toAddresses: params.toAddresses,
          ccAddresses: params.ccAddresses,
          comment: params.body,
          excludedAttachmentIds: params.excludedAttachmentIds,
          bodyType: params.bodyType,
          newAttachments: params.newAttachments,
        ),
    };
  }
}

class SendEmailParams extends Equatable {
  const SendEmailParams({
    required this.mode,
    this.originalMessageId,
    this.toAddresses = const [],
    this.ccAddresses = const [],
    this.subject = '',
    required this.body,
    this.excludedAttachmentIds = const [],
    this.bodyType = EmailBodyType.text,
    this.newAttachments = const [],
  });

  final ComposeMode mode;
  final String? originalMessageId;
  final List<String> toAddresses;
  final List<String> ccAddresses;
  final String subject;
  final String body;
  final List<String> excludedAttachmentIds;
  final EmailBodyType bodyType;
  final List<LocalAttachment> newAttachments;

  @override
  List<Object?> get props =>
      [mode, originalMessageId, toAddresses, ccAddresses, subject, body, excludedAttachmentIds, bodyType, newAttachments];
}
