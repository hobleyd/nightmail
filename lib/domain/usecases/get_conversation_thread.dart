import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/email.dart';
import '../repositories/email_repository.dart';

class GetConversationThread
    implements UseCase<List<Email>, GetConversationThreadParams> {
  const GetConversationThread(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, List<Email>>> call(
      GetConversationThreadParams params) {
    return _repository.getConversationThread(
      conversationId: params.conversationId,
      folderId: params.folderId,
    );
  }
}

class GetConversationThreadParams extends Equatable {
  const GetConversationThreadParams({
    required this.conversationId,
    this.folderId,
  });

  final String conversationId;

  /// Only used by IMAP, whose thread lookup cannot span folders. Pass the
  /// folder the anchor message lives in where it is known.
  final String? folderId;

  @override
  List<Object?> get props => [conversationId, folderId];
}
