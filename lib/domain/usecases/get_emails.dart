import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/email.dart';
import '../repositories/email_repository.dart';

class GetEmails implements UseCase<List<Email>, GetEmailsParams> {
  const GetEmails(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, List<Email>>> call(GetEmailsParams params) {
    return _repository.getEmails(
      folderId: params.folderId,
      top: params.top,
      skip: params.skip,
      filter: params.filter,
      orderBy: params.orderBy,
      olderThan: params.olderThan,
      windowEnd: params.windowEnd,
    );
  }
}

class GetEmailsParams extends Equatable {
  const GetEmailsParams({
    this.folderId,
    this.top = 25,
    this.skip = 0,
    this.filter,
    this.orderBy = 'receivedDateTime desc',
    this.olderThan,
    this.windowEnd,
  });

  final String? folderId;
  final int top;
  final int skip;
  final String? filter;
  final String orderBy;

  /// Continue the folder below this instant — see `EmailRepository.getEmails`.
  final DateTime? olderThan;

  /// The top of the stretch this page answers for, so the cache replaces it.
  final DateTime? windowEnd;

  @override
  List<Object?> get props =>
      [folderId, top, skip, filter, orderBy, olderThan, windowEnd];
}
