abstract interface class SenderRepository {
  Future<void> recordSender({
    required String accountId,
    required String address,
    required String name,
  });

  Future<List<KnownSenderEntry>> getSendersForAccount(String accountId);

  /// Substring match over this account's known senders, filtered in SQL rather
  /// than by loading the whole table — the recipient typeahead calls this on
  /// every keystroke. [query] must already be lower-cased and trimmed.
  Future<List<KnownSenderEntry>> searchSendersForAccount({
    required String accountId,
    required String query,
    int limit = 60,
  });

  Future<void> clearSendersForAccount(String accountId);

  Future<void> mergeSenders({
    required String accountId,
    required String address1,
    required String address2,
  });

  /// Returns normalized alias pairs: each tuple has address1 < address2.
  Future<Set<(String, String)>> getAliasesForAccount(String accountId);
}

class KnownSenderEntry {
  const KnownSenderEntry({required this.address, required this.name});

  final String address;
  final String name;
}
