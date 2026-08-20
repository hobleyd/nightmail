import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:sqlite3/sqlite3.dart' show Database;

import '../../domain/entities/email_folder.dart';
import '../datasources/local/delta_token_datasource.dart';
import '../datasources/local/folder_local_datasource.dart';
import '../datasources/local/migration_local_datasource.dart';
import '../datasources/local/pending_calendar_operations_datasource.dart';
import '../datasources/local/pending_operations_datasource.dart';
import '../datasources/local/reminder_schedule_local_datasource.dart';
import '../datasources/local/task_reminder_schedule_local_datasource.dart';

part 'app_database.g.dart';

/// Only index/query fields are stored in plaintext.
/// All user-visible content (subject, body, addresses) lives in [encryptedData].
///
/// A row is *one message as seen in one folder's listing*, not one message.
/// [folderId] is in the primary key because both providers expand a folder page
/// with the same thread's copies from other folders, and those copies are cached
/// under the folder being listed — so with a key of {emailId, accountId} an
/// `insertOrReplace` moved the row, and listing any folder quietly emptied the
/// cache of every other folder that shared a conversation with it. An Inbox of
/// twelve long-running threads drained to whatever the last delta had added.
///
/// The cost is that a message the user has opened stores its body once per
/// folder it appears in; inline images are keyed by message id in a separate
/// store and are not duplicated.
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
  Set<Column> get primaryKey => {emailId, accountId, folderId};
}

/// A message's heavy half: its body, its inline image bytes, its attachment
/// metadata and any meeting invite — everything the *reading pane* needs and a
/// list row never shows.
///
/// Split out of [CachedEmails] because a folder listing decrypts every row it
/// returns, and these fields are effectively all of the bytes. One real mailbox
/// measured 36 MB across a Sent folder's 223 rows, four of them ~7.6 MB apiece
/// (a body with images inlined as data URIs), which cost ~2.4 s of pure-Dart
/// AES-GCM on the UI isolate *before* any network — every time the folder was
/// opened, to draw rows that only need sender, subject, date and preview.
///
/// Keyed by message, **not** by folder, unlike [CachedEmails]: a body belongs to
/// the message, so the same 7.6 MB is no longer stored once per folder the
/// message appears in. That also means a thin list/poll fetch — which carries no
/// body — simply does not write here, so an already-cached body survives without
/// the read-merge-rewrite dance it used to take.
class CachedEmailDetails extends Table {
  TextColumn get emailId => text()();
  TextColumn get accountId => text()();
  TextColumn get encryptedDetail => text()();

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

/// Offline-first cache of calendar events, so the calendar paints from disk
/// while the provider is still being asked. Refreshed by
/// `CalendarCacheSyncService`, which holds today through four weeks ahead and
/// drops anything that finished more than a fortnight ago.
///
/// Only the range/lookup fields are plaintext; everything user-visible
/// (subject, location, attendees, body preview) lives in [encryptedData], the
/// same split [CachedEmails] uses.
///
/// [iCalUid] is here as a column rather than only inside the blob because the
/// invitation-side mutations (accept/decline from a mail banner) know the
/// meeting by its iCalendar UID and nothing else — that lookup has to be
/// indexed SQL, not a decrypt-everything scan.
///
/// The row class is renamed because drift would otherwise generate
/// `CachedCalendarEvent`, too close to the `CalendarEvent` entity it stores.
@DataClassName('CachedCalendarEventRow')
class CachedCalendarEvents extends Table {
  TextColumn get accountId => text()();
  TextColumn get eventId => text()();

  /// Event bounds in UTC epoch ms. Range queries match on *overlap*, so a
  /// multi-day event still belongs to every week it spans.
  IntColumn get startMs => integer()();
  IntColumn get endMs => integer()();

  TextColumn get iCalUid => text().nullable()();
  TextColumn get seriesMasterId => text().nullable()();
  IntColumn get cachedAtMs => integer()();
  TextColumn get encryptedData => text()();

  @override
  Set<Column> get primaryKey => {accountId, eventId};
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

/// Queued calendar mutations awaiting a server round-trip — the calendar
/// counterpart of [PendingOperations], kept separate because its ops target an
/// event (or the invitation email that carries one) rather than a message in a
/// folder, and because a calendar op must never be serialised behind an IMAP
/// mailbox mutation that has nothing to do with it.
///
/// [targetId] is an event id for the calendar-side ops and an email id for the
/// invitation-side ones; which it is follows from [opType]. See
/// [PendingCalendarOperationType].
class PendingCalendarOperations extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get accountId => text()();
  TextColumn get targetId => text()();
  TextColumn get opType => text()();
  TextColumn get payload => text()();
  IntColumn get createdAtMs => integer()();
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
}

/// One row per (source account, target account) account-migration job — see
/// AccountMigrationService. [id] is `'<sourceAccountId>|<targetAccountId>'`,
/// upserted rather than appended: re-running a completed job just catches up
/// any new source mail and retries prior failures, so there is only ever one
/// row per pair, not one per run.
class MigrationJobs extends Table {
  TextColumn get id => text()();
  TextColumn get sourceAccountId => text()();
  TextColumn get targetAccountId => text()();
  TextColumn get status => text()();
  IntColumn get createdAtMs => integer()();
  IntColumn get updatedAtMs => integer()();
  TextColumn get lastError => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Per-message progress for one [MigrationJobs] row — both the resumability
/// checkpoint and the dedupe guard against copying the same source message
/// twice. `status` moves pending -> inProgress -> written -> done (or ->
/// failed); `written` is a distinct step from `done` so a crash between the
/// provider call succeeding and the ledger update committing is detectable
/// on resume rather than silently re-copying.
@DataClassName('MigrationMessageLedgerRow')
class MigrationMessageLedger extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get jobId => text()();
  TextColumn get sourceFolderId => text()();
  TextColumn get sourceMessageId => text()();
  TextColumn get status => text()();
  TextColumn get destFolderId => text().nullable()();
  TextColumn get destMessageId => text().nullable()();
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
  IntColumn get updatedAtMs => integer()();
}

@DriftDatabase(tables: [CachedEmails, CachedEmailDetails, KnownSenders, SenderAliases, CachedContacts, ContactSyncStates, DeltaSyncTokens, CachedFolders, LocalDrafts, CatalogCache, AiConfig, CapabilityRouting, ScheduledReminders, ScheduledTaskReminders, PendingOperations, CachedCalendarEvents, PendingCalendarOperations, MigrationJobs, MigrationMessageLedger])
class AppDatabase extends _$AppDatabase
    implements
        DeltaTokenDatasource,
        FolderLocalDatasource,
        ReminderScheduleLocalDatasource,
        TaskReminderScheduleLocalDatasource,
        PendingOperationsDatasource,
        PendingCalendarOperationsDatasource,
        MigrationLocalDatasource {
  AppDatabase() : super(_openConnection());

  /// Test-only constructor: lets a unit test open the schema on an in-memory
  /// [QueryExecutor] (e.g. `NativeDatabase.memory()`) instead of the on-disk
  /// `nightmail_cache` file. Not used by production code.
  @visibleForTesting
  AppDatabase.forTesting(QueryExecutor executor) : super(executor);

  @override
  int get schemaVersion => 17;

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
          await _createCalendarCacheIndexes();
          await _createMigrationIndexes();
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
          if (from < 14) {
            await m.createTable(cachedCalendarEvents);
            await m.createTable(pendingCalendarOperations);
            await _createCalendarCacheIndexes();
          }
          if (from < 15) {
            // folder_id joins the primary key — see [CachedEmails]. SQLite
            // cannot alter one, so drift rebuilds the table and copies the rows
            // across; every existing row is already unique under the wider key,
            // so nothing is lost and no cached mail has to be re-fetched. The
            // index goes with the old table and has to be put back.
            await m.alterTable(TableMigration(cachedEmails));
            await customStatement(
              'DROP INDEX IF EXISTS idx_cached_emails_account_folder',
            );
            await customStatement(
              'CREATE INDEX idx_cached_emails_account_folder '
              'ON cached_emails(account_id, folder_id, received_date_time_ms DESC)',
            );
          }
          if (from < 16) {
            await m.createTable(cachedEmailDetails);
            // The cached mail itself has to go. Every existing row carries its
            // body and inline images *inside* `encrypted_data`, which is the
            // cost this split exists to remove — leaving them would keep every
            // folder they are in as slow as before, and they cannot be moved
            // here by a migration, which has no access to the async decryption
            // key. This is a cache: the folders repopulate on next open, and
            // the one cold load is the whole price.
            await customStatement('DELETE FROM cached_emails');
          }
          if (from < 17) {
            await m.createTable(migrationJobs);
            await m.createTable(migrationMessageLedger);
            await _createMigrationIndexes();
          }
        },
      );

  Future<void> _createMigrationIndexes() async {
    // UNIQUE, not a plain index: a second row for the same tuple would make
    // the "already done?" dedupe lookup ambiguous, so the constraint itself
    // is what a resumed job's upsert-on-conflict relies on.
    await customStatement(
      'CREATE UNIQUE INDEX idx_migration_ledger_job_folder_message '
      'ON migration_message_ledger(job_id, source_folder_id, source_message_id)',
    );
    await customStatement(
      'CREATE INDEX idx_migration_ledger_job_status '
      'ON migration_message_ledger(job_id, status)',
    );
  }

  Future<void> _createCalendarCacheIndexes() async {
    // The calendar always asks "what overlaps this range", so start_ms leads
    // the index and end_ms rides along to keep the overlap test off the rows.
    await customStatement(
      'CREATE INDEX idx_cached_calendar_events_account_start '
      'ON cached_calendar_events(account_id, start_ms, end_ms)',
    );
    // The invitation-side mutations look a meeting up by its iCalendar UID.
    await customStatement(
      'CREATE INDEX idx_cached_calendar_events_account_uid '
      'ON cached_calendar_events(account_id, i_cal_uid)',
    );
    await customStatement(
      'CREATE INDEX idx_pending_calendar_ops_account_created '
      'ON pending_calendar_operations(account_id, created_at_ms)',
    );
  }

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

  // PendingCalendarOperationsDatasource implementation (the calendar outbox)

  @override
  Future<int> enqueueCalendarOperation({
    required String accountId,
    required String targetId,
    required PendingCalendarOperationType opType,
    required String payload,
  }) =>
      into(pendingCalendarOperations).insert(
        PendingCalendarOperationsCompanion.insert(
          accountId: accountId,
          targetId: targetId,
          opType: opType.name,
          payload: payload,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );

  @override
  Future<List<PendingCalendarOperationRecord>> getPendingCalendarOperations(
      String accountId) async {
    final rows = await (select(pendingCalendarOperations)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAtMs)]))
        .get();
    return rows
        .map((r) => PendingCalendarOperationRecord(
              id: r.id,
              accountId: r.accountId,
              targetId: r.targetId,
              opType: PendingCalendarOperationType.values.byName(r.opType),
              payload: r.payload,
              createdAtMs: r.createdAtMs,
              retryCount: r.retryCount,
              lastError: r.lastError,
            ))
        .toList();
  }

  @override
  Future<void> removeCalendarOperation(int id) =>
      (delete(pendingCalendarOperations)..where((t) => t.id.equals(id))).go();

  @override
  Future<void> recordCalendarOperationFailure({
    required int id,
    required String error,
  }) async {
    final row = await (select(pendingCalendarOperations)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return;
    await (update(pendingCalendarOperations)..where((t) => t.id.equals(id)))
        .write(PendingCalendarOperationsCompanion(
      retryCount: Value(row.retryCount + 1),
      lastError: Value(error),
    ));
  }

  @override
  Future<void> clearCalendarOperationsForAccount(String accountId) =>
      (delete(pendingCalendarOperations)
            ..where((t) => t.accountId.equals(accountId)))
          .go();

  // MigrationLocalDatasource implementation (account migration)

  MigrationJobRecord _toJobRecord(MigrationJob row) => MigrationJobRecord(
        id: row.id,
        sourceAccountId: row.sourceAccountId,
        targetAccountId: row.targetAccountId,
        status: MigrationJobStatus.values.byName(row.status),
        createdAtMs: row.createdAtMs,
        updatedAtMs: row.updatedAtMs,
        lastError: row.lastError,
      );

  MigrationLedgerRecord _toLedgerRecord(MigrationMessageLedgerRow row) =>
      MigrationLedgerRecord(
        id: row.id,
        jobId: row.jobId,
        sourceFolderId: row.sourceFolderId,
        sourceMessageId: row.sourceMessageId,
        status: MigrationMessageStatus.values.byName(row.status),
        destFolderId: row.destFolderId,
        destMessageId: row.destMessageId,
        retryCount: row.retryCount,
        lastError: row.lastError,
        updatedAtMs: row.updatedAtMs,
      );

  @override
  Future<MigrationJobRecord> upsertJob({
    required String jobId,
    required String sourceAccountId,
    required String targetAccountId,
    required MigrationJobStatus status,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final existing =
        await (select(migrationJobs)..where((t) => t.id.equals(jobId)))
            .getSingleOrNull();
    final createdAtMs = existing?.createdAtMs ?? nowMs;
    await into(migrationJobs).insertOnConflictUpdate(
      MigrationJobsCompanion.insert(
        id: jobId,
        sourceAccountId: sourceAccountId,
        targetAccountId: targetAccountId,
        status: status.name,
        createdAtMs: createdAtMs,
        updatedAtMs: nowMs,
      ),
    );
    return MigrationJobRecord(
      id: jobId,
      sourceAccountId: sourceAccountId,
      targetAccountId: targetAccountId,
      status: status,
      createdAtMs: createdAtMs,
      updatedAtMs: nowMs,
      lastError: null,
    );
  }

  @override
  Future<MigrationJobRecord?> getJob(String jobId) async {
    final row = await (select(migrationJobs)..where((t) => t.id.equals(jobId)))
        .getSingleOrNull();
    return row == null ? null : _toJobRecord(row);
  }

  @override
  Future<List<MigrationJobRecord>> getResumableJobs() async {
    final rows = await (select(migrationJobs)
          ..where((t) => t.status.isIn(
                [MigrationJobStatus.running.name, MigrationJobStatus.paused.name],
              )))
        .get();
    return rows.map(_toJobRecord).toList();
  }

  @override
  Future<void> setJobStatus({
    required String jobId,
    required MigrationJobStatus status,
    String? lastError,
  }) =>
      (update(migrationJobs)..where((t) => t.id.equals(jobId))).write(
        MigrationJobsCompanion(
          status: Value(status.name),
          updatedAtMs: Value(DateTime.now().millisecondsSinceEpoch),
          lastError: Value(lastError),
        ),
      );

  @override
  Future<MigrationLedgerRecord?> findLedgerRow({
    required String jobId,
    required String sourceFolderId,
    required String sourceMessageId,
    required bool matchSourceFolderId,
  }) async {
    final query = select(migrationMessageLedger)
      ..where((t) =>
          t.jobId.equals(jobId) & t.sourceMessageId.equals(sourceMessageId));
    if (matchSourceFolderId) {
      query.where((t) => t.sourceFolderId.equals(sourceFolderId));
    }
    final row = await query.getSingleOrNull();
    return row == null ? null : _toLedgerRecord(row);
  }

  @override
  Future<void> upsertLedgerRow({
    required String jobId,
    required String sourceFolderId,
    required String sourceMessageId,
    required MigrationMessageStatus status,
    String? destFolderId,
    String? destMessageId,
    String? lastError,
    bool incrementRetry = false,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // Read-then-write rather than insertOnConflictUpdate: the dedupe
    // constraint is a raw-SQL UNIQUE index (see _createMigrationIndexes),
    // not a drift-declared key drift's typed upsert could target, and a job
    // processes one message at a time so there is no concurrent writer to
    // race against the same row.
    final existing = await (select(migrationMessageLedger)
          ..where((t) =>
              t.jobId.equals(jobId) &
              t.sourceFolderId.equals(sourceFolderId) &
              t.sourceMessageId.equals(sourceMessageId)))
        .getSingleOrNull();
    final retryCount = incrementRetry
        ? (existing?.retryCount ?? 0) + 1
        : (existing?.retryCount ?? 0);
    if (existing != null) {
      await (update(migrationMessageLedger)..where((t) => t.id.equals(existing.id)))
          .write(MigrationMessageLedgerCompanion(
        status: Value(status.name),
        destFolderId: Value(destFolderId ?? existing.destFolderId),
        destMessageId: Value(destMessageId ?? existing.destMessageId),
        retryCount: Value(retryCount),
        lastError: Value(lastError),
        updatedAtMs: Value(nowMs),
      ));
    } else {
      await into(migrationMessageLedger).insert(
        MigrationMessageLedgerCompanion.insert(
          jobId: jobId,
          sourceFolderId: sourceFolderId,
          sourceMessageId: sourceMessageId,
          status: status.name,
          destFolderId: Value(destFolderId),
          destMessageId: Value(destMessageId),
          retryCount: Value(retryCount),
          lastError: Value(lastError),
          updatedAtMs: nowMs,
        ),
      );
    }
  }


  @override
  Future<List<MigrationLedgerRecord>> getFailedRows(String jobId) async {
    final rows = await (select(migrationMessageLedger)
          ..where((t) =>
              t.jobId.equals(jobId) &
              t.status.equals(MigrationMessageStatus.failed.name)))
        .get();
    return rows.map(_toLedgerRecord).toList();
  }

  /// Runs inside drift's background isolate as each connection is opened, and
  /// gives the `sqlite3*` handle away to nobody: the process keeps it until it
  /// exits.
  ///
  /// **Nothing may call `sqlite3_close_v2` on this app's database.** Two
  /// generations of macOS crash reports are the same SIGSEGV inside
  /// `sqlite3Close` on a background `DartWorker` while quitting, and the
  /// faulting instruction is `blr x8` where `x8` is
  /// `sqlite3GlobalConfig.mutex.xMutexEnter` — NULL. The handle itself is
  /// valid (its `eOpenState` magic passes `sqlite3SafetyCheckSickOrOk`), so the
  /// close is executing against a *mapping of libsqlite3 whose
  /// `sqlite3_initialize()` never ran* — the crash log has
  /// `sqlite3.framework` mapped **twice**, at two base addresses with one
  /// UUID. A handle opened through the initialised mapping, closed through the
  /// other, dies on the first mutex call.
  ///
  /// Both call paths had to go, which is why this is at *open* time rather
  /// than a change to the shutdown code:
  ///
  /// - `package:sqlite3` attaches a `NativeFinalizer` whose callback *is*
  ///   `sqlite3_close_v2` (`ffi/bindings.dart`), and Dart fires native
  ///   finalizers when an isolate group is torn down. That is the crash that
  ///   was reported before anything closed the database explicitly.
  /// - Closing it explicitly at quit — the fix that was tried instead — only
  ///   moved the same call earlier, which is the crash reported after it.
  ///
  /// `leak()` detaches that finalizer *and* marks the connection borrowed, so
  /// `close()` stops before `sqlite3_close_v2` too (`implementation.dart`,
  /// `database.dart`). Every other operation is unaffected, and
  /// [AppDatabase.close] still does the part worth doing: it drains in-flight
  /// queries and shuts the isolate down.
  ///
  /// Leaving a database unclosed at process exit is not data loss. Recovering
  /// a journal or WAL that nobody checkpointed is the case SQLite is built
  /// for — it is the same state a power cut leaves behind, and the next open
  /// replays it.
  ///
  /// Must stay a static tear-off: drift sends it to the background isolate.
  static void _keepHandleUntilProcessExit(CommonDatabase db) {
    (db as Database).leak();
  }

  static QueryExecutor _openConnection() {
    return driftDatabase(
      name: 'nightmail_cache',
      native: DriftNativeOptions(setup: _keepHandleUntilProcessExit),
    );
  }
}
