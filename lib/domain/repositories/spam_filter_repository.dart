import '../entities/email.dart';

abstract interface class SpamFilterRepository {
  Future<void> trainSpam(String accountId, List<Email> emails);
  Future<void> trainHam(String accountId, List<Email> emails);

  /// Returns the IDs of [emails] that the filter classifies as spam.
  /// Returns an empty set if the filter has not yet been trained.
  Future<Set<String>> classifyEmails(String accountId, List<Email> emails);

  /// Serializes the current filter state for [accountId], for syncing to
  /// another device (e.g. via the IMAP SPAMDB folder).
  Future<Map<String, dynamic>> exportState(String accountId);

  /// Replaces the local filter state for [accountId] with [remoteState],
  /// overwriting whatever was trained locally (last-write-wins).
  Future<void> importState(String accountId, Map<String, dynamic> remoteState);
}
