import '../../../domain/repositories/sender_repository.dart';

abstract interface class SenderLocalDatasource {
  Future<void> upsertSender({
    required String accountId,
    required String address,
    required String name,
  });

  Future<List<KnownSenderEntry>> getSendersForAccount(String accountId);

  Future<void> clearSendersForAccount(String accountId);

  Future<void> upsertAlias({
    required String accountId,
    required String address1,
    required String address2,
  });

  Future<Set<(String, String)>> getAliasesForAccount(String accountId);
}
