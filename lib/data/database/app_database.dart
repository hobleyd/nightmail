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

@DriftDatabase(tables: [CachedEmails])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await customStatement(
            'CREATE INDEX idx_cached_emails_account_folder '
            'ON cached_emails(account_id, folder_id, received_date_time_ms DESC)',
          );
        },
      );

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'nightmail_cache');
  }
}
