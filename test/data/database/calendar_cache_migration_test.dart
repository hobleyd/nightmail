// Schema test for the v14 calendar-cache tables.
//
// SCOPE / LIMITATION: same as `ai_migration_test.dart` — this repo has no
// `drift_schemas/` snapshots, so a true version-stepping harness (build a v13
// database, run `onUpgrade`, diff against v14) is not available. Opening
// `AppDatabase` in memory runs `onCreate`, which issues the same `createTable`
// calls and the same `_createCalendarCacheIndexes()` the `if (from < 14)`
// upgrade branch does.
//
// The indexes are the part actually worth asserting: they are raw SQL naming
// drift's *generated* column names (`i_cal_uid` from `iCalUid`), so a rename
// upstream would break both migration paths at runtime with nothing in the Dart
// analyzer to catch it.

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/database/app_database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  Future<Set<String>> indexNames(String table) async {
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?",
          variables: [Variable<String>(table)],
        )
        .get();
    return rows.map((r) => r.read<String>('name')).toSet();
  }

  test('schema version is 14', () {
    expect(db.schemaVersion, 14);
  });

  test('the calendar cache is indexed for both of its lookups', () async {
    final names = await indexNames('cached_calendar_events');
    // Range queries ("what overlaps this week") and the UID lookup the
    // invitation-side mutations depend on.
    expect(names, contains('idx_cached_calendar_events_account_start'));
    expect(names, contains('idx_cached_calendar_events_account_uid'));
  });

  test('the calendar outbox is indexed by account and queue order', () async {
    expect(await indexNames('pending_calendar_operations'),
        contains('idx_pending_calendar_ops_account_created'));
  });

  test('the calendar cache index really covers i_cal_uid', () async {
    // Proves the raw-SQL column name matches what drift generated: SQLite
    // resolves index columns at CREATE time, so a mismatch would have thrown
    // during onCreate — but assert the shape too, so a silently-renamed index
    // covering the wrong column cannot pass.
    final rows = await db
        .customSelect(
            "SELECT name FROM pragma_index_info('idx_cached_calendar_events_account_uid')")
        .get();
    expect(rows.map((r) => r.read<String>('name')),
        containsAll(['account_id', 'i_cal_uid']));
  });
}
