// Every connection to the cache file is opened through
// `AppDatabase.configureConnection`. Two of the three things it does are
// pragmas whose absence is silent until two windows collide on the file, so
// they are pinned here against a real on-disk database.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nightmail_setup_test');
    path = '${dir.path}/cache.sqlite';
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('puts the file into write-ahead logging', () {
    final db = sqlite3.open(path);
    AppDatabase.configureConnection(db);

    expect(db.select('PRAGMA journal_mode').single.values.single, 'wal');

    // The mode is stored in the file: a connection that did not run the setup
    // still finds it, which is what makes running it on every open idempotent.
    final other = sqlite3.open(path);
    expect(other.select('PRAGMA journal_mode').single.values.single, 'wal');
    other.close();
  });

  test('gives the connection a busy timeout instead of failing at once', () {
    final db = sqlite3.open(path);
    AppDatabase.configureConnection(db);

    expect(
      db.select('PRAGMA busy_timeout').single.values.single,
      AppDatabase.busyTimeout.inMilliseconds,
    );
  });

  test('a reader is not locked out by a writer mid-transaction', () {
    final writer = sqlite3.open(path);
    AppDatabase.configureConnection(writer);
    writer.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    writer.execute("INSERT INTO t (v) VALUES ('committed')");

    final reader = sqlite3.open(path);
    AppDatabase.configureConnection(reader);

    // In the default rollback journal this read would meet the writer's lock
    // and throw `database is locked`; in WAL it sees the last commit.
    writer.execute('BEGIN IMMEDIATE');
    writer.execute("INSERT INTO t (v) VALUES ('pending')");
    final rows = reader.select('SELECT v FROM t');
    expect(rows.map((r) => r['v']), ['committed']);
    writer.execute('COMMIT');

    expect(reader.select('SELECT v FROM t').length, 2);
  });

  test('still leaks the handle, so nothing ever calls sqlite3_close_v2', () {
    final db = sqlite3.open(path);
    db.execute('CREATE TABLE t (x INTEGER)');
    final handle = db.handle;
    AppDatabase.configureConnection(db);

    // What drift does when AppDatabase.close() shuts its isolate down. With
    // the connection marked borrowed this must stop short of closing it.
    db.close();

    // Adopting the handle proves it is still an open connection (see
    // leaked_sqlite_handle_test.dart for why a freed pointer could not do this).
    final adopted = sqlite3.fromPointer(handle, borrowed: true);
    adopted.execute('INSERT INTO t VALUES (1)');
    expect(adopted.select('SELECT x FROM t').single['x'], 1);

    sqlite3.fromPointer(handle).close();
  });
}
