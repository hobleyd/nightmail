import 'package:drift/drift.dart';

import '../../../domain/repositories/sender_repository.dart';
import '../../database/app_database.dart';
import 'like_escape.dart';
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
  Future<List<KnownSenderEntry>> searchSendersForAccount({
    required String accountId,
    required String query,
    int limit = 60,
  }) async {
    if (query.isEmpty) return [];
    final escaped = escapeLikePattern(query);
    final prefix = '$escaped%';
    final wordPrefix = '% $escaped%';
    final substring = '%$escaped%';

    // Mirrors the ranking in ContactCacheLocalDatasourceImpl.search so the two
    // result sets can be merged without re-sorting from scratch. There is no
    // stored search_text column here, so the name/address concatenation is
    // built inline; idx_known_senders_account keeps the scan to one account.
    final rows = await _database.customSelect(
      "SELECT address, name, "
      'CASE '
      "  WHEN lower(name) LIKE ? ESCAPE '\\' THEN 0 "
      "  WHEN address LIKE ? ESCAPE '\\' THEN 0 "
      "  WHEN lower(name) LIKE ? ESCAPE '\\' THEN 1 "
      '  ELSE 2 '
      'END AS match_rank '
      'FROM known_senders '
      'WHERE account_id = ? '
      "  AND (lower(name) LIKE ? ESCAPE '\\' OR address LIKE ? ESCAPE '\\') "
      'ORDER BY match_rank ASC, length(name) ASC '
      'LIMIT ?',
      variables: [
        Variable.withString(prefix),
        Variable.withString(prefix),
        Variable.withString(wordPrefix),
        Variable.withString(accountId),
        Variable.withString(substring),
        Variable.withString(substring),
        Variable.withInt(limit),
      ],
      readsFrom: {_database.knownSenders},
    ).get();

    return rows
        .map((r) => KnownSenderEntry(
              address: r.read<String>('address'),
              name: r.read<String>('name'),
            ))
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
