// drift runs `onUpgrade` outside a transaction and records the new
// `user_version` only after it returns. An app that dies in between leaves an
// additive column in the file and the version where it was, so the next open
// runs the same ALTER TABLE again. That once failed with "duplicate column
// name: scope" on every open, and with it every query: the Inbox spun forever.
// These rebuild that state on disk and open it again.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('nightmail_upgrade_test');
    file = File('${dir.path}/cache.sqlite');
    // A current-schema file, every column present.
    final db = AppDatabase.forTesting(NativeDatabase(file));
    await db.customSelect('SELECT 1').get();
    await db.close();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  void rewindVersion(int version) {
    final raw = sqlite3.open(file.path);
    raw.execute('PRAGMA user_version = $version');
    raw.close();
  }

  int userVersion() {
    final raw = sqlite3.open(file.path);
    final version = raw.select('PRAGMA user_version').single.values.single;
    raw.close();
    return version as int;
  }

  for (final from in [18, 19, 20]) {
    test('reopens a v$from file whose upgrade already added its columns',
        () async {
      rewindVersion(from);

      final db = AppDatabase.forTesting(NativeDatabase(file));
      final jobs = await db.customSelect('SELECT * FROM migration_jobs').get();
      await db.close();

      expect(jobs, isEmpty);
      expect(userVersion(), db.schemaVersion);
    });
  }
}
