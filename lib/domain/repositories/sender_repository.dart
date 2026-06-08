abstract interface class SenderRepository {
  Future<void> recordSender({
    required String accountId,
    required String address,
    required String name,
  });

  Future<List<KnownSenderEntry>> getSendersForAccount(String accountId);

  Future<void> clearSendersForAccount(String accountId);
}

class KnownSenderEntry {
  const KnownSenderEntry({required this.address, required this.name});

  final String address;
  final String name;
}
