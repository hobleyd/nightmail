import 'package:sqlite3/common.dart' show CommonDatabase;

/// Nothing to do on web: the database lives in a worker with no native
/// finalizer and no second libsqlite3 mapping to close it through.
void keepHandleUntilProcessExit(CommonDatabase db) {}
