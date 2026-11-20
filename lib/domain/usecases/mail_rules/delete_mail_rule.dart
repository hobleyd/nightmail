import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../../core/usecases/usecase.dart';
import '../../repositories/mail_rules_repository.dart';

class DeleteMailRule implements UseCase<Unit, DeleteMailRuleParams> {
  const DeleteMailRule(this._repository);

  final MailRulesRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(DeleteMailRuleParams params) =>
      _repository.deleteMailRule(params.accountId, params.ruleId);
}

class DeleteMailRuleParams extends Equatable {
  const DeleteMailRuleParams({required this.accountId, required this.ruleId});

  final String accountId;
  final String ruleId;

  @override
  List<Object?> get props => [accountId, ruleId];
}
