import 'package:drift/drift.dart';

import '../../../domain/entities/cached_contact.dart';
import '../../database/app_database.dart';
import 'contact_cache_local_datasource.dart';
import 'like_escape.dart';

/// Sentinel account id for the OS address book, which is not tied to a mail
/// account and is therefore searched alongside every account's own contacts.
/// Chosen to be impossible to collide with a real account id (a UUID).
const systemContactsAccountId = '__system__';

class ContactCacheLocalDatasourceImpl implements ContactCacheLocalDatasource {
  const ContactCacheLocalDatasourceImpl({required AppDatabase database})
      : _database = database;

  final AppDatabase _database;

  @override
  Future<void> replaceForAccount({
    required String accountId,
    required List<CachedContact> contacts,
    required String status,
    String? detail,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await _database.transaction(() async {
      await (_database.delete(_database.cachedContacts)
            ..where((t) => t.accountId.equals(accountId)))
          .go();
      // One batch for the whole account: drift wraps it in a single prepared
      // statement run, which matters when a large tenant directory arrives as
      // tens of thousands of rows.
      await _database.batch((b) {
        b.insertAll(
          _database.cachedContacts,
          contacts.map(
            (c) => CachedContactsCompanion.insert(
              accountId: accountId,
              address: c.address,
              name: c.name,
              searchText: c.searchText,
              source: c.source.name,
              updatedAtMs: nowMs,
            ),
          ),
          mode: InsertMode.insertOrReplace,
        );
      });
      await _database
          .into(_database.contactSyncStates)
          .insertOnConflictUpdate(ContactSyncStatesCompanion.insert(
            accountId: accountId,
            syncedAtMs: nowMs,
            contactCount: Value(contacts.length),
            status: status,
            detail: Value(detail),
          ));
    });
  }

  @override
  Future<void> markSyncFailed({
    required String accountId,
    required String detail,
  }) async {
    final existing = await (_database.select(_database.contactSyncStates)
          ..where((t) => t.accountId.equals(accountId)))
        .getSingleOrNull();
    await _database
        .into(_database.contactSyncStates)
        .insertOnConflictUpdate(ContactSyncStatesCompanion.insert(
          accountId: accountId,
          syncedAtMs: DateTime.now().millisecondsSinceEpoch,
          contactCount: Value(existing?.contactCount ?? 0),
          status: 'error',
          detail: Value(detail),
        ));
  }

  @override
  Future<List<CachedContact>> search({
    required String accountId,
    required String query,
    int limit = 60,
  }) async {
    if (query.isEmpty) return [];
    final escaped = escapeLikePattern(query);
    final prefix = '$escaped%';
    final wordPrefix = '% $escaped%';
    final substring = '%$escaped%';

    // Ranking is done in SQL because LIMIT has to be applied to already-ordered
    // rows — pulling every substring hit into Dart to sort would defeat the
    // point of the index on (account_id, search_text).
    //   0 — search_text or address starts with the query
    //   1 — a word inside search_text starts with the query ("hob" → "David Hobley")
    //   2 — matches somewhere else in the middle
    final rows = await _database.customSelect(
      'SELECT address, name, source, '
      'CASE '
      "  WHEN search_text LIKE ? ESCAPE '\\' THEN 0 "
      "  WHEN address LIKE ? ESCAPE '\\' THEN 0 "
      "  WHEN search_text LIKE ? ESCAPE '\\' THEN 1 "
      '  ELSE 2 '
      'END AS match_rank '
      'FROM cached_contacts '
      'WHERE (account_id = ? OR account_id = ?) '
      "  AND search_text LIKE ? ESCAPE '\\' "
      "ORDER BY match_rank ASC, name = '' ASC, length(search_text) ASC "
      'LIMIT ?',
      variables: [
        Variable.withString(prefix),
        Variable.withString(prefix),
        Variable.withString(wordPrefix),
        Variable.withString(accountId),
        Variable.withString(systemContactsAccountId),
        Variable.withString(substring),
        Variable.withInt(limit),
      ],
      readsFrom: {_database.cachedContacts},
    ).get();

    return rows
        .map((r) => CachedContact(
              address: r.read<String>('address'),
              name: r.read<String>('name'),
              source: ContactSource.parse(r.read<String>('source')),
            ))
        .toList();
  }

  @override
  Future<ContactSyncStatus?> syncStatus(String accountId) async {
    final row = await (_database.select(_database.contactSyncStates)
          ..where((t) => t.accountId.equals(accountId)))
        .getSingleOrNull();
    if (row == null) return null;
    return ContactSyncStatus(
      syncedAt: DateTime.fromMillisecondsSinceEpoch(row.syncedAtMs),
      contactCount: row.contactCount,
      status: row.status,
      detail: row.detail,
    );
  }

  @override
  Future<bool> hasContacts(String accountId) async {
    final row = await _database.customSelect(
      'SELECT 1 FROM cached_contacts WHERE account_id = ? LIMIT 1',
      variables: [Variable.withString(accountId)],
      readsFrom: {_database.cachedContacts},
    ).getSingleOrNull();
    return row != null;
  }

  @override
  Future<List<String>> cachedAccountIds() async {
    final rows = await _database.select(_database.contactSyncStates).get();
    return rows.map((r) => r.accountId).toList();
  }

  @override
  Future<void> clearAccount(String accountId) async {
    await _database.transaction(() async {
      await (_database.delete(_database.cachedContacts)
            ..where((t) => t.accountId.equals(accountId)))
          .go();
      await (_database.delete(_database.contactSyncStates)
            ..where((t) => t.accountId.equals(accountId)))
          .go();
    });
  }
}
