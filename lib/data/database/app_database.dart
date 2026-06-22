import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../domain/entities/email_folder.dart';
import '../datasources/local/delta_token_datasource.dart';
import '../datasources/local/folder_local_datasource.dart';

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

/// Cached mail folder metadata for offline-first startup.
/// Not encrypted — contains only IDs, names, and counts.
class CachedFolders extends Table {
  TextColumn get accountId => text()();
  TextColumn get folderId => text()();
  TextColumn get displayName => text()();
  IntColumn get totalItemCount => integer()();
  IntColumn get unreadItemCount => integer()();
  TextColumn get parentFolderId => text().nullable()();
  BoolColumn get isHidden => boolean()();
  IntColumn get childFolderCount => integer()();

  @override
  Set<Column> get primaryKey => {accountId, folderId};
}

/// Local draft emails saved automatically while composing.
/// Drafts are stored per account and cleaned up when sent.
class LocalDrafts extends Table {
  TextColumn get draftId => text()();
  TextColumn get accountId => text()();
  TextColumn get toAddresses => text()();
  TextColumn get ccAddresses => text()();
  TextColumn get subject => text()();
  TextColumn get body => text()();
  IntColumn get savedAtMs => integer()();

  @override
  Set<Column> get primaryKey => {draftId};
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

@DriftDatabase(tables: [CachedEmails, KnownSenders, DeltaSyncTokens, CachedFolders, LocalDrafts])
class AppDatabase extends _$AppDatabase
    implements DeltaTokenDatasource, FolderLocalDatasource {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 6;

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
          if (from < 5) {
            await m.createTable(cachedFolders);
          }
          if (from < 6) {
            await m.createTable(localDrafts);
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

  // FolderLocalDatasource implementation

  @override
  Future<List<EmailFolder>> getCachedFolders(String accountId) async {
    final rows = await (select(cachedFolders)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    return rows
        .map((r) => EmailFolder(
              id: r.folderId,
              displayName: r.displayName,
              totalItemCount: r.totalItemCount,
              unreadItemCount: r.unreadItemCount,
              parentFolderId: r.parentFolderId,
              isHidden: r.isHidden,
              childFolderCount: r.childFolderCount,
            ))
        .toList();
  }

  @override
  Future<void> cacheFolders({
    required String accountId,
    required List<EmailFolder> folders,
  }) =>
      batch((b) {
        b.insertAllOnConflictUpdate(
          cachedFolders,
          folders
              .map((f) => CachedFoldersCompanion.insert(
                    accountId: accountId,
                    folderId: f.id,
                    displayName: f.displayName,
                    totalItemCount: f.totalItemCount,
                    unreadItemCount: f.unreadItemCount,
                    parentFolderId: Value(f.parentFolderId),
                    isHidden: f.isHidden,
                    childFolderCount: f.childFolderCount,
                  ))
              .toList(),
        );
      });

  @override
  Future<void> clearFoldersForAccount(String accountId) =>
      (delete(cachedFolders)
            ..where((t) => t.accountId.equals(accountId)))
          .go();

  Future<void> saveDraft({
    required String draftId,
    required String accountId,
    required String toAddresses,
    required String ccAddresses,
    required String subject,
    required String body,
  }) =>
      into(localDrafts).insertOnConflictUpdate(
        LocalDraftsCompanion(
          draftId: Value(draftId),
          accountId: Value(accountId),
          toAddresses: Value(toAddresses),
          ccAddresses: Value(ccAddresses),
          subject: Value(subject),
          body: Value(body),
          savedAtMs: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );

  Future<void> deleteDraft(String draftId) =>
      (delete(localDrafts)..where((t) => t.draftId.equals(draftId))).go();

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'nightmail_cache');
  }
}
