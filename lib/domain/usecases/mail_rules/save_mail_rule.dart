import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../../core/usecases/usecase.dart';
import '../../entities/mail_rule.dart';
import '../../repositories/mail_rules_repository.dart';

class SaveMailRule implements UseCase<Unit, SaveMailRuleParams> {
  const SaveMailRule(this._repository);

  final MailRulesRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(SaveMailRuleParams params) =>
      _repository.saveMailRule(params.accountId, params.rule);
}

class SaveMailRuleParams extends Equatable {
  const SaveMailRuleParams({required this.accountId, required this.rule});

  final String accountId;
  final MailRule rule;

  @override
  List<Object?> get props => [accountId, rule];
}
