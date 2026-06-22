import '../../../domain/repositories/sender_repository.dart';
import '../../database/app_database.dart';
import 'sender_local_datasource.dart';

class SenderLocalDatasourceImpl implements SenderLocalDatasource {
  const SenderLocalDatasourceImpl({required AppDatabase database})
      : _database = database;

  final AppDatabase _database;

  @override
  Future<void> upsertSender({
    required String accountId,
    required String address,
    required String name,
  }) async {
    await _database.into(_database.knownSenders).insertOnConflictUpdate(
          KnownSendersCompanion.insert(
            accountId: accountId,
            address: address,
            name: name,
          ),
        );
  }

  @override
  Future<List<KnownSenderEntry>> getSendersForAccount(
      String accountId) async {
    final rows = await (_database.select(_database.knownSenders)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    return rows
        .map((r) => KnownSenderEntry(address: r.address, name: r.name))
        .toList();
  }

  @override
  Future<void> clearSendersForAccount(String accountId) async {
    await (_database.delete(_database.knownSenders)
          ..where((t) => t.accountId.equals(accountId)))
        .go();
  }

  @override
  Future<void> upsertAlias({
    required String accountId,
    required String address1,
    required String address2,
  }) async {
    await _database
        .into(_database.senderAliases)
        .insertOnConflictUpdate(
          SenderAliasesCompanion.insert(
            accountId: accountId,
            address1: address1,
            address2: address2,
          ),
        );
  }

  @override
  Future<Set<(String, String)>> getAliasesForAccount(String accountId) async {
    final rows = await (_database.select(_database.senderAliases)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    return rows.map((r) => (r.address1, r.address2)).toSet();
  }
}
