import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../../core/usecases/usecase.dart';
import '../../entities/mail_rule.dart';
import '../../repositories/mail_rules_repository.dart';

class GetMailRules implements UseCase<MailRuleSet, String> {
  const GetMailRules(this._repository);

  final MailRulesRepository _repository;

  @override
  Future<Either<Failure, MailRuleSet>> call(String accountId) =>
      _repository.getMailRules(accountId);
}
