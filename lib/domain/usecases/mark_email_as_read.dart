import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/email.dart';
import '../repositories/email_repository.dart';

class MarkEmailAsRead implements UseCase<Email, MarkEmailAsReadParams> {
  const MarkEmailAsRead(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, Email>> call(MarkEmailAsReadParams params) {
    return _repository.markAsRead(
      id: params.id,
      isRead: params.isRead,
      accountId: params.accountId,
    );
  }
}

class MarkEmailAsReadParams extends Equatable {
  const MarkEmailAsReadParams({
    required this.id,
    required this.isRead,
    this.accountId,
  });

  final String id;
  final bool isRead;

  /// Targets a specific, possibly-non-active account — see
  /// [EmailRepository.markAsRead]. Null falls back to the active account.
  final String? accountId;

  @override
  List<Object?> get props => [id, isRead, accountId];
}
