import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/email.dart';
import '../entities/folder_listing.dart';
import '../repositories/email_repository.dart';

class CacheEmailsParams extends Equatable {
  const CacheEmailsParams({
    required this.accountId,
    required this.folderId,
    required this.emails,
    this.window,
  });

  final String accountId;
  final String folderId;
  final List<Email> emails;

  /// The stretch of the folder [emails] answers for, when they are a listed
  /// page — its cached rows are replaced. See [ListingWindow].
  final ListingWindow? window;

  @override
  List<Object?> get props => [accountId, folderId, emails, window];
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
      window: params.window,
    );
  }
}
