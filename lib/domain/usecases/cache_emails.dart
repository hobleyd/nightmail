import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/email.dart';
import '../repositories/email_repository.dart';

class CacheEmailsParams extends Equatable {
  const CacheEmailsParams({
    required this.accountId,
    required this.folderId,
    required this.emails,
  });

  final String accountId;
  final String folderId;
  final List<Email> emails;

  @override
  List<Object?> get props => [accountId, folderId, emails];
}

class CacheEmails implements UseCase<Unit, CacheEmailsParams> {
  const CacheEmails(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(CacheEmailsParams params) {
    return _repository.cacheEmails(
      accountId: params.accountId,
      folderId: params.folderId,
      emails: params.emails,
    );
  }
}
