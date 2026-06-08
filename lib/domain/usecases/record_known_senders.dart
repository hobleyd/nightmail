import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/email.dart';
import '../repositories/sender_repository.dart';

class RecordKnownSenders implements UseCase<Unit, RecordKnownSendersParams> {
  const RecordKnownSenders(this._repository);

  final SenderRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(RecordKnownSendersParams params) async {
    try {
      for (final email in params.emails) {
        final name = email.from.name;
        if (name == null || name.isEmpty) continue;
        await _repository.recordSender(
          accountId: params.accountId,
          address: email.from.address.toLowerCase(),
          name: name,
        );
      }
      return const Right(unit);
    } catch (e) {
      return Left(CacheFailure(message: e.toString()));
    }
  }
}

class RecordKnownSendersParams extends Equatable {
  const RecordKnownSendersParams({
    required this.accountId,
    required this.emails,
  });

  final String accountId;
  final List<Email> emails;

  @override
  List<Object?> get props => [accountId, emails];
}
