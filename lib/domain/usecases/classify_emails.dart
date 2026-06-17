import '../entities/email.dart';
import '../repositories/spam_filter_repository.dart';

class ClassifyEmails {
  const ClassifyEmails(this._repository);
  final SpamFilterRepository _repository;

  Future<Set<String>> call(ClassifyEmailsParams params) {
    return _repository.classifyEmails(params.accountId, params.emails);
  }
}

class ClassifyEmailsParams {
  const ClassifyEmailsParams({
    required this.accountId,
    required this.emails,
  });
  final String accountId;
  final List<Email> emails;
}
