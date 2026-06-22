import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/local_attachment.dart';
import '../repositories/email_repository.dart';

class SaveServerDraftParams {
  const SaveServerDraftParams({
    this.existingDraftId,
    required this.toAddresses,
    this.ccAddresses = const [],
    required this.subject,
    required this.body,
    this.newAttachments = const [],
  });

  final String? existingDraftId;
  final List<String> toAddresses;
  final List<String> ccAddresses;
  final String subject;
  final String body;
  final List<LocalAttachment> newAttachments;
}

class SaveServerDraft {
  const SaveServerDraft(this._repository);

  final EmailRepository _repository;

  Future<Either<Failure, String>> call(SaveServerDraftParams params) {
    if (params.existingDraftId != null) {
      return _repository.updateServerDraft(
        draftId: params.existingDraftId!,
        toAddresses: params.toAddresses,
        ccAddresses: params.ccAddresses,
        subject: params.subject,
        body: params.body,
        newAttachments: params.newAttachments,
      );
    }
    return _repository.createServerDraft(
      toAddresses: params.toAddresses,
      ccAddresses: params.ccAddresses,
      subject: params.subject,
      body: params.body,
      newAttachments: params.newAttachments,
    );
  }
}
