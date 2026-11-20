import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../../core/usecases/usecase.dart';
import '../../repositories/mail_rules_repository.dart';

class SetMailRuleEnabled implements UseCase<Unit, SetMailRuleEnabledParams> {
  const SetMailRuleEnabled(this._repository);

  final MailRulesRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(SetMailRuleEnabledParams params) =>
      _repository.setMailRuleEnabled(
        params.accountId,
        params.ruleId,
        params.enabled,
      );
}

class SetMailRuleEnabledParams extends Equatable {
  const SetMailRuleEnabledParams({
    required this.accountId,
    required this.ruleId,
    required this.enabled,
  });

  final String accountId;
  final String ruleId;
  final bool enabled;

  @override
  List<Object?> get props => [accountId, ruleId, enabled];
}
