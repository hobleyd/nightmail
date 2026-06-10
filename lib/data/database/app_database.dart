import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../datasources/local/delta_token_datasource.dart';

part 'app_database.g.dart';

/// Only index/query fields are stored in plaintext.
/// All user-visible content (subject, body, addresses) lives in [encryptedData].
class CachedEmails extends Table {
  TextColumn get emailId => text()();
  TextColumn get accountId => text()();
  TextColumn get folderId => text()();
  BoolColumn get isRead => boolean()();
  BoolColumn get hasAttachments => boolean()();
  IntColumn get receivedDateTimeMs => integer()();
  TextColumn get conversationId => text().nullable()();
  IntColumn get cachedAtMs => integer()();
  TextColumn get encryptedData => text()();

  @override
  Set<Column> get primaryKey => {emailId, accountId};
}

/// Plaintext sender cache — not encrypted so names can be queried for fuzzy matching.
class KnownSenders extends Table {
  TextColumn get accountId => text()();
  TextColumn get address => text()(); // always lower-cased
  TextColumn get name => text()();

  @override
  Set<Column> get primaryKey => {accountId, address};
}

/// Stores Microsoft Graph delta sync tokens per account and folder.
/// A delta link lets the poller fetch only changes since the last sync
/// rather than refetching the full folder.
class DeltaSyncTokens extends Table {
  TextColumn get accountId => text()();
  TextColumn get folderId => text()();
  TextColumn get deltaLink => text()();

  @override
  Set<Column> get primaryKey => {accountId, folderId};
}

@DriftDatabase(tables: [CachedEmails, KnownSenders, DeltaSyncTokens])
class AppDatabase extends _$AppDatabase implements DeltaTokenDatasource {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await customStatement(
            'CREATE INDEX idx_cached_emails_account_folder '
            'ON cached_emails(account_id, folder_id, received_date_time_ms DESC)',
          );
          await customStatement(
            'CREATE INDEX idx_known_senders_account '
            'ON known_senders(account_id)',
          );
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(knownSenders);
            await customStatement(
              'CREATE INDEX idx_known_senders_account '
              'ON known_senders(account_id)',
            );
          }
          if (from < 3) {
            // Clear sender cache so any junk/spam senders recorded before
            // this fix are removed.
            await customStatement('DELETE FROM known_senders');
          }
          if (from < 4) {
            await m.createTable(deltaSyncTokens);
          }
        },
      );

  Future<String?> loadDeltaToken(String accountId, String folderId) async {
    final q = select(deltaSyncTokens)
      ..where(
        (t) => t.accountId.equals(accountId) & t.folderId.equals(folderId),
      );
    return (await q.getSingleOrNull())?.deltaLink;
  }

  Future<void> saveDeltaToken(
    String accountId,
    String folderId,
    String deltaLink,
  ) =>
      into(deltaSyncTokens).insertOnConflictUpdate(
        DeltaSyncTokensCompanion(
          accountId: Value(accountId),
          folderId: Value(folderId),
          deltaLink: Value(deltaLink),
        ),
      );

  Future<void> clearDeltaTokensForAccount(String accountId) =>
      (delete(deltaSyncTokens)
            ..where((t) => t.accountId.equals(accountId)))
          .go();

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'nightmail_cache');
  }
}
