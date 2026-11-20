import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../../core/usecases/usecase.dart';
import '../../entities/email_folder.dart';
import '../../repositories/mail_rules_repository.dart';

class GetMailRuleFolders implements UseCase<List<EmailFolder>, String> {
  const GetMailRuleFolders(this._repository);

  final MailRulesRepository _repository;

  @override
  Future<Either<Failure, List<EmailFolder>>> call(String accountId) =>
      _repository.getMailRuleFolders(accountId);
}
