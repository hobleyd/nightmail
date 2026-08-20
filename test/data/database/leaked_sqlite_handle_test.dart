import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// `AppDatabase._keepHandleUntilProcessExit` calls `Database.leak()` on every
/// connection drift opens, because a `sqlite3_close_v2` running while the
/// process comes down is what crashed the app (SIGSEGV in `sqlite3Close`, twice
/// over, once from the `NativeFinalizer` that calls it and once from an
/// explicit close). The fix rests entirely on two properties of
/// `package:sqlite3` that no test in the app would otherwise notice breaking,
/// so pin them here — a version bump that changed either would put the crash
/// back silently.
void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nightmail_leak_test');
    path = '${dir.path}/leak.sqlite';
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('a leaked handle survives close(), so nothing calls sqlite3_close_v2',
      () {
    final db = sqlite3.open(path);
    db.execute('CREATE TABLE t (x INTEGER)');

    final handle = db.leak();

    // What drift does when AppDatabase.close() shuts its isolate down. With
    // the connection marked borrowed this must stop short of closing it.
    db.close();

    // Adopting the handle proves it is still an open connection: a closed one
    // could not be read through, and reusing a freed `sqlite3*` would not
    // reliably answer with the row either.
    final adopted = sqlite3.fromPointer(handle, borrowed: true);
    adopted.execute('INSERT INTO t VALUES (1)');
    expect(adopted.select('SELECT x FROM t').single['x'], 1);

    // Tidy up for real, while the library is healthy — the app never does this
    // and relies on process exit instead.
    sqlite3.fromPointer(handle).close();
  });

  test('a leaked connection is still fully usable for queries', () {
    // leak() only gives up *ownership*. If it degraded the connection, drift
    // would be running every query in the app through a crippled handle.
    final db = sqlite3.open(path);
    final handle = db.leak();

    db.execute('CREATE TABLE t (x INTEGER)');
    final stmt = db.prepare('INSERT INTO t VALUES (?)');
    for (var i = 0; i < 3; i++) {
      stmt.execute([i]);
    }
    stmt.close();

    expect(db.select('SELECT x FROM t ORDER BY x').map((r) => r['x']),
        [0, 1, 2]);

    db.close();
    sqlite3.fromPointer(handle).close();
  });
}
