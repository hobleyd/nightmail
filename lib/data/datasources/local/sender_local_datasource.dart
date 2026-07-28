import '../../../domain/repositories/sender_repository.dart';

abstract interface class SenderLocalDatasource {
  Future<void> upsertSender({
    required String accountId,
    required String address,
    required String name,
  });

  Future<List<KnownSenderEntry>> getSendersForAccount(String accountId);

  /// Substring match over this account's known senders, filtered in SQL.
  ///
  /// The recipient typeahead runs this on every keystroke, so it must not pull
  /// the whole table into Dart the way [getSendersForAccount] does. [query]
  /// must already be lower-cased and trimmed.
  Future<List<KnownSenderEntry>> searchSendersForAccount({
    required String accountId,
    required String query,
    int limit = 60,
  });

  Future<void> clearSendersForAccount(String accountId);

  Future<void> upsertAlias({
    required String accountId,
    required String address1,
    required String address2,
  });

  Future<Set<(String, String)>> getAliasesForAccount(String accountId);
}
