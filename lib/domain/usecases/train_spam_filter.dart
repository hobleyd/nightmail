import '../entities/email.dart';
import '../repositories/spam_filter_repository.dart';

class TrainSpamFilter {
  const TrainSpamFilter(this._repository);
  final SpamFilterRepository _repository;

  Future<void> call(TrainSpamFilterParams params) {
    return params.isSpam
        ? _repository.trainSpam(params.accountId, params.emails)
        : _repository.trainHam(params.accountId, params.emails);
  }
}

class TrainSpamFilterParams {
  const TrainSpamFilterParams({
    required this.accountId,
    required this.emails,
    required this.isSpam,
  });
  final String accountId;
  final List<Email> emails;
  final bool isSpam;
}
