import '../../../domain/repositories/sender_repository.dart';

abstract interface class SenderLocalDatasource {
  Future<void> upsertSender({
    required String accountId,
    required String address,
    required String name,
  });

  Future<List<KnownSenderEntry>> getSendersForAccount(String accountId);

  Future<void> clearSendersForAccount(String accountId);
}
