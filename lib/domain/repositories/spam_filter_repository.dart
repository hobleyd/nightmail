import '../entities/email.dart';

abstract interface class SpamFilterRepository {
  Future<void> trainSpam(String accountId, List<Email> emails);
  Future<void> trainHam(String accountId, List<Email> emails);

  /// Returns the IDs of [emails] that the filter classifies as spam.
  /// Returns an empty set if the filter has not yet been trained.
  Future<Set<String>> classifyEmails(String accountId, List<Email> emails);
}
