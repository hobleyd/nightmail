import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/email.dart';
import '../entities/folder_listing.dart';
import '../repositories/email_repository.dart';

class GetCachedEmailsParams extends Equatable {
  const GetCachedEmailsParams({
    required this.accountId,
    required this.folderId,
    this.from,
    this.after,
    this.limitThreads,
  });

  final String accountId;
  final String folderId;

  /// Read a window of the folder rather than all of it: threads dated at or
  /// after [from], after [after], at most [limitThreads] of them — see
  /// `EmailRepository.getCachedWindow`. All null reads the whole folder.
  final DateTime? from;
  final CacheCursor? after;
  final int? limitThreads;

  bool get isWindow => from != null || after != null || limitThreads != null;

  @override
  List<Object?> get props => [accountId, folderId, from, after, limitThreads];
}

class GetCachedEmails implements UseCase<List<Email>, GetCachedEmailsParams> {
  const GetCachedEmails(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, List<Email>>> call(GetCachedEmailsParams params) {
    if (params.isWindow) {
      return _repository
          .getCachedWindow(
            accountId: params.accountId,
            folderId: params.folderId,
            from: params.from,
            after: params.after,
            limitThreads: params.limitThreads,
          )
          .then((r) => r.map((window) => window.emails));
    }
    return _repository.getCachedEmails(
      accountId: params.accountId,
      folderId: params.folderId,
    );
  }
}
