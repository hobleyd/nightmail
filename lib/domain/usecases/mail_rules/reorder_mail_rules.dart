import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../../core/usecases/usecase.dart';
import '../../repositories/mail_rules_repository.dart';

class ReorderMailRules implements UseCase<Unit, ReorderMailRulesParams> {
  const ReorderMailRules(this._repository);

  final MailRulesRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(ReorderMailRulesParams params) =>
      _repository.reorderMailRules(params.accountId, params.sequences);
}

class ReorderMailRulesParams extends Equatable {
  const ReorderMailRulesParams({
    required this.accountId,
    required this.sequences,
  });

  final String accountId;

  /// Rule id → new sequence, for the rules that move.
  final Map<String, int> sequences;

  @override
  List<Object?> get props => [accountId, sequences];
}
