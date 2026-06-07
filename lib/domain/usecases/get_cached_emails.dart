import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/email.dart';
import '../repositories/email_repository.dart';

class GetCachedEmailsParams extends Equatable {
  const GetCachedEmailsParams({
    required this.accountId,
    required this.folderId,
  });

  final String accountId;
  final String folderId;

  @override
  List<Object?> get props => [accountId, folderId];
}

class GetCachedEmails implements UseCase<List<Email>, GetCachedEmailsParams> {
  const GetCachedEmails(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, List<Email>>> call(GetCachedEmailsParams params) {
    return _repository.getCachedEmails(
      accountId: params.accountId,
      folderId: params.folderId,
    );
  }
}
