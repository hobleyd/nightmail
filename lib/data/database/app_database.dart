import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

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

@DriftDatabase(tables: [CachedEmails, KnownSenders])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 3;

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
        },
      );

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'nightmail_cache');
  }
}
