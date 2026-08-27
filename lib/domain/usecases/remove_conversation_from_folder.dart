import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/email_repository.dart';

class RemoveConversationFromFolderParams extends Equatable {
  const RemoveConversationFromFolderParams({
    required this.conversationId,
    required this.folderId,
  });

  final String conversationId;

  /// The folder the conversation is listed under and is to leave.
  final String folderId;

  @override
  List<Object?> get props => [conversationId, folderId];
}

/// Takes a conversation out of a folder none of its messages is in.
///
/// The fallback a folder-scoped move drops to when the per-message move has
/// nothing to act on — see [EmailRepository.removeConversationFromFolder].
/// Fails with [UnsupportedFailure] on a provider that files a message in
/// exactly one folder, where the situation cannot arise.
class RemoveConversationFromFolder
    implements UseCase<Unit, RemoveConversationFromFolderParams> {
  const RemoveConversationFromFolder(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(
      RemoveConversationFromFolderParams params) {
    return _repository.removeConversationFromFolder(
      conversationId: params.conversationId,
      folderId: params.folderId,
    );
  }
}
