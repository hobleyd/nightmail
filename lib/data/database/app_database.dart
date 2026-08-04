import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../domain/entities/email_folder.dart';
import '../datasources/local/delta_token_datasource.dart';
import '../datasources/local/folder_local_datasource.dart';
import '../datasources/local/pending_operations_datasource.dart';
import '../datasources/local/reminder_schedule_local_datasource.dart';
import '../datasources/local/task_reminder_schedule_local_datasource.dart';

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

/// Address-book cache backing the recipient typeahead, refreshed at most once
/// a day by `ContactCacheSyncService`. Plaintext for the same reason as
/// [KnownSenders] — [searchText] has to be `LIKE`-queryable.
///
/// [accountId] is a real account id for directory/personal contacts, or the
/// sentinel `__system__` for the OS address book (which is not account-scoped).
/// [source] is a `ContactSource.name`, used to rank matches.
///
/// The row class is renamed because drift would otherwise generate
/// `CachedContact`, which is the domain entity this table stores.
@DataClassName('CachedContactRow')
class CachedContacts extends Table {
  TextColumn get accountId => text()();
  TextColumn get address => text()(); // always lower-cased
  TextColumn get name => text()();

  /// `"<lower name> <lower address>"` — the single column the typeahead's
  /// `LIKE` runs against, so one index covers both name and address matching.
  TextColumn get searchText => text()();
  TextColumn get source => text()();
  IntColumn get updatedAtMs => integer()();

  @override
  Set<Column> get primaryKey => {accountId, address};
}

/// One row per account (plus `__system__`) recording when its slice of
/// [CachedContacts] was last refreshed, so a restart doesn't re-pull the whole
/// address book and a partial failure can be retried sooner than the full TTL.
class ContactSyncStates extends Table {
  TextColumn get accountId => text()();
  IntColumn get syncedAtMs => integer()();
  IntColumn get contactCount => integer().withDefault(const Constant(0))();

  /// `ok` | `partial` | `error` — `partial` and `error` use a shorter retry
  /// interval than a clean sync.
  TextColumn get status => text()();
  TextColumn get detail => text().nullable()();

  @override
  Set<Column> get primaryKey => {accountId};
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

/// Pairs of sender addresses the user has confirmed belong to the same person.
/// address1 < address2 (alphabetically, lower-cased) so each pair has one
/// canonical row regardless of which address was the incoming one.
class SenderAliases extends Table {
  TextColumn get accountId => text()();
  TextColumn get address1 => text()();
  TextColumn get address2 => text()();

  @override
  Set<Column> get primaryKey => {accountId, address1, address2};
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

/// Single-row blob holding the last good models.dev `api.json` fetch.
///
/// This is the cold-start fallback for the AI provider/model catalog: the
/// registry serves the in-memory catalog while online and parses this raw
/// blob on a cold offline launch (stale-while-revalidate). It is a raw blob,
/// not a parsed mirror of the catalog. [etag]/[lastModified] support
/// conditional refresh requests.
class CatalogCache extends Table {
  /// Always 0 — enforces a single row.
  IntColumn get id => integer().withDefault(const Constant(0))();
  TextColumn get rawJson => text()();
  DateTimeColumn get fetchedAt => dateTime()();
  TextColumn get etag => text().nullable()();
  TextColumn get lastModified => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Durable user AI configuration — the configured providers (catalog picks and
/// BYO custom endpoints). API keys are NOT stored here; they live in
/// flutter_secure_storage keyed by providerId.
class AiConfig extends Table {
  TextColumn get id => text()();
  TextColumn get providerId => text()();
  TextColumn get source => text()(); // catalog | user
  TextColumn get displayName => text().nullable()();
  TextColumn get apiBaseUrl => text().nullable()();
  TextColumn get wireProtocol => text()(); // openai | anthropic | google | ollama | azure
  TextColumn get kind => text()(); // cloud | local | selfHosted

  @override
  Set<Column> get primaryKey => {id};
}

/// Per-capability routing: maps each AI capability
/// (compose | summarize | triage | search) to a (providerId, modelId) so each
/// feature can use a different backend.
class CapabilityRouting extends Table {
  TextColumn get capability => text()();
  TextColumn get providerId => text()();
  TextColumn get modelId => text()();

  @override
  Set<Column> get primaryKey => {capability};
}

/// Tracks which calendar events currently have an OS-level reminder
/// notification scheduled, so the reconciliation pass in
/// [CalendarReminderService] can tell new/changed events (need scheduling)
/// apart from unchanged ones (skip) and detect events that disappeared or
/// lost their reminder (need cancelling), across app restarts.
class ScheduledReminders extends Table {
  TextColumn get accountId => text()();
  TextColumn get eventId => text()();
  IntColumn get triggerAtMs => integer()();
  IntColumn get reminderMinutes => integer()();
  IntColumn get eventStartMs => integer()();

  @override
  Set<Column> get primaryKey => {accountId, eventId};
}

/// The tasks counterpart of [ScheduledReminders]: tracks which to-do items
/// already have a due notification arranged, so [TaskReminderService] can tell
/// new/rescheduled tasks apart from unchanged ones and — crucially — knows
/// whether a task that fell due while the app was closed has been announced
/// yet, rather than either missing it or re-announcing it every cycle.
class ScheduledTaskReminders extends Table {
  TextColumn get accountId => text()();
  TextColumn get taskId => text()();
  TextColumn get listId => text()();
  IntColumn get triggerAtMs => integer()();
  IntColumn get dueAtMs => integer()();
  BoolColumn get osScheduled => boolean().withDefault(const Constant(false))();
  IntColumn get notifiedAtMs => integer().nullable()();

  @override
  Set<Column> get primaryKey => {accountId, taskId};
}

/// Queued mutations awaiting a server round-trip — the outbox that lets a
/// mutation apply to the cache and appear in the UI immediately (even
/// offline), replayed against the server later. [emailId] is rewritten in
/// place if an earlier queued op for the same message moves it and the
/// server assigns a new id (see [AppDatabase.remapEmailId]).
class PendingOperations extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get accountId => text()();
  TextColumn get emailId => text()();
  TextColumn get folderId => text().nullable()();
  TextColumn get opType => text()();
  TextColumn get payload => text()();
  IntColumn get createdAtMs => integer()();
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
}

@DriftDatabase(tables: [CachedEmails, KnownSenders, SenderAliases, CachedContacts, ContactSyncStates, DeltaSyncTokens, CachedFolders, LocalDrafts, CatalogCache, AiConfig, CapabilityRouting, ScheduledReminders, ScheduledTaskReminders, PendingOperations])
class AppDatabase extends _$AppDatabase
    implements
        DeltaTokenDatasource,
        FolderLocalDatasource,
        ReminderScheduleLocalDatasource,
        TaskReminderScheduleLocalDatasource,
        PendingOperationsDatasource {
  AppDatabase() : super(_openConnection());

  /// Test-only constructor: lets a unit test open the schema on an in-memory
  /// [QueryExecutor] (e.g. `NativeDatabase.memory()`) instead of the on-disk
  /// `nightmail_cache` file. Not used by production code.
  @visibleForTesting
  AppDatabase.forTesting(QueryExecutor executor) : super(executor);

  @override
  int get schemaVersion => 13;

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
          await customStatement(
            'CREATE INDEX idx_pending_operations_account_email_created '
            'ON pending_operations(account_id, email_id, created_at_ms)',
          );
          await customStatement(
            'CREATE INDEX idx_cached_contacts_account_search '
            'ON cached_contacts(account_id, search_text)',
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
          if (from < 7) {
            await m.createTable(senderAliases);
          }
          if (from < 8) {
            await m.createTable(catalogCache);
            await m.createTable(aiConfig);
            await m.createTable(capabilityRouting);
          }
          if (from < 9) {
            await m.createTable(scheduledReminders);
          }
          if (from < 10) {
            await m.createTable(pendingOperations);
            await customStatement(
              'CREATE INDEX idx_pending_operations_account_email_created '
              'ON pending_operations(account_id, email_id, created_at_ms)',
            );
          }
          if (from < 11) {
            await m.createTable(scheduledTaskReminders);
          }
          if (from < 12) {
            await m.createTable(cachedContacts);
            await m.createTable(contactSyncStates);
            await customStatement(
              'CREATE INDEX idx_cached_contacts_account_search '
              'ON cached_contacts(account_id, search_text)',
            );
          }
          if (from < 13) {
            // A reminder is now a series of alerts per event (the lead-time
            // one, then a countdown every five minutes to the start). Rows
            // written before that account for a single alert, and the
            // reconciler skips an event whose row still matches — so these
            // would never grow their countdown. Drop them and let the next
            // reconcile re-derive the full series; the table only records what
            // was handed to the OS, so nothing else is lost.
            await customStatement('DELETE FROM scheduled_reminders');
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

  // ReminderScheduleLocalDatasource implementation

  @override
  Future<List<ScheduledReminderRecord>> getScheduledReminders(
      String accountId) async {
    final rows = await (select(scheduledReminders)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    return rows
        .map((r) => ScheduledReminderRecord(
              accountId: r.accountId,
              eventId: r.eventId,
              triggerAtMs: r.triggerAtMs,
              reminderMinutes: r.reminderMinutes,
              eventStartMs: r.eventStartMs,
            ))
        .toList();
  }

  @override
  Future<void> upsertScheduledReminder({
    required String accountId,
    required String eventId,
    required int triggerAtMs,
    required int reminderMinutes,
    required int eventStartMs,
  }) =>
      into(scheduledReminders).insertOnConflictUpdate(
        ScheduledRemindersCompanion(
          accountId: Value(accountId),
          eventId: Value(eventId),
          triggerAtMs: Value(triggerAtMs),
          reminderMinutes: Value(reminderMinutes),
          eventStartMs: Value(eventStartMs),
        ),
      );

  @override
  Future<void> deleteScheduledReminder(String accountId, String eventId) =>
      (delete(scheduledReminders)
            ..where((t) =>
                t.accountId.equals(accountId) & t.eventId.equals(eventId)))
          .go();

  @override
  Future<void> clearScheduledRemindersForAccount(String accountId) =>
      (delete(scheduledReminders)
            ..where((t) => t.accountId.equals(accountId)))
          .go();

  // TaskReminderScheduleLocalDatasource implementation

  @override
  Future<List<ScheduledTaskReminderRecord>> getScheduledTaskReminders(
      String accountId) async {
    final rows = await (select(scheduledTaskReminders)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    return rows
        .map((r) => ScheduledTaskReminderRecord(
              accountId: r.accountId,
              listId: r.listId,
              taskId: r.taskId,
              triggerAtMs: r.triggerAtMs,
              dueAtMs: r.dueAtMs,
              osScheduled: r.osScheduled,
              notifiedAtMs: r.notifiedAtMs,
            ))
        .toList();
  }

  @override
  Future<void> upsertScheduledTaskReminder({
    required String accountId,
    required String listId,
    required String taskId,
    required int triggerAtMs,
    required int dueAtMs,
    required bool osScheduled,
    int? notifiedAtMs,
  }) =>
      into(scheduledTaskReminders).insertOnConflictUpdate(
        ScheduledTaskRemindersCompanion(
          accountId: Value(accountId),
          listId: Value(listId),
          taskId: Value(taskId),
          triggerAtMs: Value(triggerAtMs),
          dueAtMs: Value(dueAtMs),
          osScheduled: Value(osScheduled),
          notifiedAtMs: Value(notifiedAtMs),
        ),
      );

  @override
  Future<void> markTaskReminderNotified({
    required String accountId,
    required String taskId,
    required int notifiedAtMs,
  }) =>
      (update(scheduledTaskReminders)
            ..where(
                (t) => t.accountId.equals(accountId) & t.taskId.equals(taskId)))
          .write(ScheduledTaskRemindersCompanion(
        notifiedAtMs: Value(notifiedAtMs),
      ));

  @override
  Future<void> deleteScheduledTaskReminder(String accountId, String taskId) =>
      (delete(scheduledTaskReminders)
            ..where((t) =>
                t.accountId.equals(accountId) & t.taskId.equals(taskId)))
          .go();

  @override
  Future<void> clearScheduledTaskRemindersForAccount(String accountId) =>
      (delete(scheduledTaskReminders)
            ..where((t) => t.accountId.equals(accountId)))
          .go();

  // PendingOperationsDatasource implementation (the mutation outbox)

  @override
  Future<int> enqueue({
    required String accountId,
    required String emailId,
    String? folderId,
    required PendingOperationType opType,
    required String payload,
  }) =>
      into(pendingOperations).insert(
        PendingOperationsCompanion.insert(
          accountId: accountId,
          emailId: emailId,
          folderId: Value(folderId),
          opType: opType.name,
          payload: payload,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );

  @override
  Future<List<PendingOperationRecord>> getPendingOperations(
      String accountId) async {
    final rows = await (select(pendingOperations)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAtMs)]))
        .get();
    return rows
        .map((r) => PendingOperationRecord(
              id: r.id,
              accountId: r.accountId,
              emailId: r.emailId,
              folderId: r.folderId,
              opType: PendingOperationType.values.byName(r.opType),
              payload: r.payload,
              createdAtMs: r.createdAtMs,
              retryCount: r.retryCount,
              lastError: r.lastError,
            ))
        .toList();
  }

  @override
  Future<void> remapEmailId({
    required String accountId,
    required String oldEmailId,
    required String newEmailId,
  }) =>
      (update(pendingOperations)
            ..where((t) =>
                t.accountId.equals(accountId) & t.emailId.equals(oldEmailId)))
          .write(PendingOperationsCompanion(emailId: Value(newEmailId)));

  @override
  Future<void> removeOperation(int id) =>
      (delete(pendingOperations)..where((t) => t.id.equals(id))).go();

  @override
  Future<void> recordFailure({required int id, required String error}) async {
    final row = await (select(pendingOperations)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return;
    await (update(pendingOperations)..where((t) => t.id.equals(id))).write(
      PendingOperationsCompanion(
        retryCount: Value(row.retryCount + 1),
        lastError: Value(error),
      ),
    );
  }

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'nightmail_cache');
  }
}
