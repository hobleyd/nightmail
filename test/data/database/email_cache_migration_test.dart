// Schema test for the v15 rekey of `cached_emails` and the v16 body split.
//
// Unlike the other migration tests here, this one really does step a v14
// database through `onUpgrade`: v15 rebuilds a table and copies its rows, and
// v16 then deliberately empties it. It builds the v14 shape by hand on a temp
// file (this repo has no `drift_schemas/` snapshots), stamps `user_version`,
// then opens `AppDatabase` on it.

import 'dart:io';

import 'package:drift/backends.dart' show QueryExecutor, QueryExecutorUser;
import 'package:drift/drift.dart' show OpeningDetails, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:nightmail/data/datasources/local/migration_local_datasource.dart';

/// The v14 `cached_emails`: same columns, primary key without `folder_id`.
const _v14CachedEmails = '''
CREATE TABLE cached_emails (
  email_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  folder_id TEXT NOT NULL,
  is_read INTEGER NOT NULL,
  has_attachments INTEGER NOT NULL,
  received_date_time_ms INTEGER NOT NULL,
  conversation_id TEXT NULL,
  cached_at_ms INTEGER NOT NULL,
  encrypted_data TEXT NOT NULL,
  PRIMARY KEY (email_id, account_id)
)''';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('nightmail_migration');
    file = File('${dir.path}/cache.sqlite');

    final v14 = NativeDatabase(file);
    // A no-op statement to force the file open before the raw DDL below.
    await v14.ensureOpen(_NoMigration());
    await v14.runCustom(_v14CachedEmails, const []);
    await v14.runCustom(
      'CREATE INDEX idx_cached_emails_account_folder '
      'ON cached_emails(account_id, folder_id, received_date_time_ms DESC)',
      const [],
    );
    await v14.runCustom(
      'INSERT INTO cached_emails VALUES '
      "('email-1', 'acct-1', 'inbox', 0, 0, 1000, 'conv-1', 1, 'payload-1'), "
      "('email-2', 'acct-1', 'archive', 1, 0, 2000, 'conv-2', 1, 'payload-2')",
      const [],
    );
    await v14.runCustom('PRAGMA user_version = 14', const []);
    await v14.close();
  });

  tearDown(() async => dir.delete(recursive: true));

  Future<List<String>> pkColumns(AppDatabase db) async {
    // A rowid table enforces its primary key with an auto-index, so its columns
    // are readable without parsing the DDL back out of sqlite_master.
    final rows = await db
        .customSelect(
          'SELECT name FROM pragma_index_info(?)',
          variables: [Variable<String>('sqlite_autoindex_cached_emails_1')],
        )
        .get();
    return rows.map((r) => r.read<String>('name')).toList();
  }

  test('the upgrade rekeys the table on folder_id', () async {
    final db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);

    expect(await pkColumns(db), ['email_id', 'account_id', 'folder_id']);

    // The index belongs to the old table and is dropped with it; every read of
    // a folder listing goes through it.
    final indexes = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND tbl_name = 'cached_emails'",
        )
        .get();
    expect(
      indexes.map((r) => r.read<String>('name')),
      contains('idx_cached_emails_account_folder'),
    );
  });

  // v16 splits bodies out into cached_email_details. A pre-v16 row carries its
  // body *inside* encrypted_data, which is the cost the split exists to remove,
  // and a migration cannot move it — it has no access to the async decryption
  // key. So the cache is emptied and refills on next open.
  test('the v16 upgrade adds the details table and empties the mail cache',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);

    expect(await db.select(db.cachedEmails).get(), isEmpty);
    expect(await db.select(db.cachedEmailDetails).get(), isEmpty);

    // Present and writable, not merely declared.
    await db.customStatement(
      'INSERT INTO cached_email_details VALUES '
      "('email-1', 'acct-1', 'detail-1')",
    );
    expect(
      (await db.select(db.cachedEmailDetails).get()).single.encryptedDetail,
      'detail-1',
    );
  });

  test('a migrated database can list one message under two folders', () async {
    final db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);

    // Self-contained: v16 empties whatever the fixture put there, so both rows
    // are written here. The point is that the widened key admits them at all.
    await db.customStatement(
      'INSERT INTO cached_emails VALUES '
      "('email-1', 'acct-1', 'inbox', 0, 0, 1000, 'conv-1', 1, 'payload-1'), "
      "('email-1', 'acct-1', 'archive', 0, 0, 1000, 'conv-1', 1, 'payload-1')",
    );

    final rows = await (db.select(db.cachedEmails)
          ..where((t) => t.emailId.equals('email-1')))
        .get();
    expect(rows.map((r) => r.folderId), containsAll(['inbox', 'archive']));
  });

  // v17 adds the account-migration job/ledger tables. Additive only (no data
  // to carry forward), but still exercised end to end from a real v14 file
  // to confirm the onUpgrade branch actually builds them and the unique
  // dedupe index that migration's resumability depends on.
  test('the v17 upgrade adds the migration job/ledger tables', () async {
    final db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);

    await db.upsertJob(
      jobId: 'src|tgt',
      sourceAccountId: 'src',
      targetAccountId: 'tgt',
      status: MigrationJobStatus.running,
    );
    await db.upsertLedgerRow(
      jobId: 'src|tgt',
      sourceFolderId: 'INBOX',
      sourceMessageId: 'msg-1',
      status: MigrationMessageStatus.done,
    );

    expect((await db.getJob('src|tgt'))?.status, MigrationJobStatus.running);
    expect(
      (await db.findLedgerRow(
        jobId: 'src|tgt',
        sourceFolderId: 'INBOX',
        sourceMessageId: 'msg-1',
        matchSourceFolderId: true,
      ))
          ?.status,
      MigrationMessageStatus.done,
    );

    // The dedupe index is UNIQUE — a second row for the same
    // (job, folder, message) must be rejected, not silently duplicated.
    await expectLater(
      db.into(db.migrationMessageLedger).insert(
            MigrationMessageLedgerCompanion.insert(
              jobId: 'src|tgt',
              sourceFolderId: 'INBOX',
              sourceMessageId: 'msg-1',
              status: MigrationMessageStatus.done.name,
              updatedAtMs: 0,
            ),
          ),
      throwsA(anything),
    );
  });

  // The tripwire: bumping the version without adding an `if (from < n)` branch
  // ships a schema the upgrade path never builds.
  test('schema version is 20', () {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    // v18 adds the commitments ledger tables (see
    // commitment_local_datasource_impl_test.dart for their round-trip).
    // v19 adds the scheduled-block columns to commitments; v20 the model's
    // effort estimate.
    expect(db.schemaVersion, 20);
  });

  // The additive commitments columns are guarded by `from` so that a pre-v18
  // database — which just created the table with every column — does not
  // add them a second time. Both paths must end in the same shape.
  group('commitments columns', () {
    Future<List<String>> commitmentColumns(AppDatabase db) async {
      final rows = await db
          .customSelect('SELECT name FROM pragma_table_info(?)',
              variables: [Variable<String>('commitments')])
          .get();
      return rows.map((r) => r.read<String>('name')).toList();
    }

    test('a pre-v18 database gets the full table once', () async {
      // The v14 fixture from setUp.
      final db = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(db.close);
      expect(
        await commitmentColumns(db),
        containsAll(['scheduled_event_id', 'scheduled_end_ms', 'estimated_minutes']),
      );
    });

    test('a v19 database gains estimated_minutes and keeps its rows', () async {
      final v19File = File('${dir.path}/v19.sqlite');
      final v19 = NativeDatabase(v19File);
      await v19.ensureOpen(_NoMigration());
      await v19.runCustom('''
CREATE TABLE commitments (
  id TEXT NOT NULL, account_id TEXT NOT NULL, email_id TEXT NOT NULL,
  conversation_id TEXT NULL, kind TEXT NOT NULL, status TEXT NOT NULL,
  due TEXT NOT NULL, urgency INTEGER NOT NULL, confidence REAL NOT NULL,
  email_date_ms INTEGER NOT NULL, detected_at_ms INTEGER NOT NULL,
  resolved_at_ms INTEGER NULL, encrypted_data TEXT NOT NULL,
  scheduled_event_id TEXT NULL, scheduled_start_ms INTEGER NULL,
  scheduled_end_ms INTEGER NULL,
  PRIMARY KEY (account_id, id)
)''', const []);
      await v19.runCustom(
        "INSERT INTO commitments VALUES ('iOwe:e1', 'acc', 'e1', NULL, 'iOwe', "
        "'open', 'today', 2, 0.9, 1000, 1000, NULL, '{}', NULL, NULL, NULL)",
        const [],
      );
      await v19.runCustom('PRAGMA user_version = 19', const []);
      await v19.close();

      final db = AppDatabase.forTesting(NativeDatabase(v19File));
      addTearDown(db.close);
      expect(await commitmentColumns(db), contains('estimated_minutes'));
      final row = (await db.select(db.commitments).get()).single;
      expect(row.id, 'iOwe:e1');
      expect(row.estimatedMinutes, isNull);
    });
  });
}

/// `ensureOpen` wants a `QueryExecutorUser`; the fixture above writes its own
/// DDL, so this one has no schema and no migration to run.
class _NoMigration extends QueryExecutorUser {
  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(
          QueryExecutor executor, OpeningDetails details) async =>
      {};
}
