import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:sqlite3/sqlite3.dart' show Database;

/// See `AppDatabase._keepHandleUntilProcessExit`. Native only:
/// `package:sqlite3/sqlite3.dart` is the FFI API, which web can't compile.
void keepHandleUntilProcessExit(CommonDatabase db) {
  (db as Database).leak();
}
