abstract interface class SenderRepository {
  Future<void> recordSender({
    required String accountId,
    required String address,
    required String name,
  });

  Future<List<KnownSenderEntry>> getSendersForAccount(String accountId);

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
