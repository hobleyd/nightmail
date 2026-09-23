# Local Cache Database (sqlite / drift)

Why `nightmail_cache.sqlite` is never explicitly closed via `sqlite3_close_v2`,
and why every connection to it is opened in WAL mode with a busy timeout. See
[../../../CLAUDE.md](../../../CLAUDE.md) for architecture-wide rules.

## More Than One Connection Always Shares the File

Each `desktop_multi_window` sub-window is its own engine with its own service
locator, so a calendar or compose window holds a **second** drift connection to
the file the main window is writing mail and calendar rows into; on Android the
background mail service is a third. Neither drift nor `package:sqlite3` sets a
busy handler, so out of the box a connection that meets another's lock fails at
once with `SqliteException(5): database is locked`. It surfaced as "Could not
load events" in the calendar window: its fetch reads the pending-op queue while
the main window is mid-commit, and in the default rollback journal a committing
writer holds an exclusive lock that fails every concurrent *read*.

`AppDatabase.configureConnection` — the `setup` hook drift runs on every
connection, alongside the `leak()` below — therefore sets two pragmas:

- **`journal_mode = WAL`**: readers never wait on a writer, nor a writer on
  readers. Stored in the file, so applying it on every open is idempotent, and
  `macos_app_data_migration.dart` already copies the `-wal` sidecar with the
  database.
- **`busy_timeout`** (`AppDatabase.busyTimeout`): what WAL cannot cover — two
  writers — waits for the first commit instead of throwing. Per connection, so
  it has to be set at open time rather than in a migration.

Both are best-effort: a failure is logged and the open proceeds, since the
mode switch itself can report busy if another connection is mid-transaction,
and the next open will try again.

`test/data/database/connection_setup_test.dart` pins both pragmas and the
read-during-write behaviour against a real file.

## Nothing May Close the Cache Database

**`sqlite3_close_v2` is never called on `nightmail_cache.sqlite`.**
`AppDatabase._openConnection` passes drift a `setup` hook that calls
`Database.leak()` on every connection, which detaches the closing finalizer and
marks the connection borrowed. The process holds the handle until it exits.

Two generations of macOS crash reports are the same SIGSEGV in `sqlite3Close` on
a background `DartWorker` while quitting. The faulting instruction is `blr x8`
with `x8` = `sqlite3GlobalConfig.mutex.xMutexEnter` — NULL — while the handle
itself still passes `sqlite3SafetyCheckSickOrOk`. So the close was running
against a *mapping of libsqlite3 whose `sqlite3_initialize()` never ran*: the
crash log has `sqlite3.framework` mapped **twice**, two base addresses, one
UUID. Open through the initialised mapping, close through the other, and the
first mutex call dies. Same family as the sub-window FFI rule above — a native
resource outliving the isolate/mapping that set it up.

Both ways in had to be closed, which is why the fix is at *open* time:

- `package:sqlite3` attaches a `NativeFinalizer` whose callback **is**
  `sqlite3_close_v2`, and Dart fires native finalizers when an isolate group is
  torn down. That is the crash from before anything closed the database
  explicitly.
- Closing it explicitly at quit — the fix tried instead, and the reason
  `AppDelegate` holds `.terminateLater` over an `app_lifecycle` channel — only
  moved the same call earlier. That is the crash from after it.

`AppDatabase.close()` is still called at quit and still worth calling: it drains
in-flight queries and shuts the drift isolate down. It just stops short of
native sqlite3 now. An unclosed database at process exit is not data loss —
replaying an unclosed journal is the case SQLite is built for.

`test/data/database/leaked_sqlite_handle_test.dart` pins the two
`package:sqlite3` properties this rests on, because a version bump that changed
either would restore the crash silently.

**Prepared statements take the same route and are deliberately left alone.**
`package:sqlite3` attaches a second `NativeFinalizer` calling `sqlite3_finalize`
to every statement, and that opens with the same `sqlite3_mutex_enter(db->mutex)`
that dies here. Nothing is done about it because nothing has ever crashed there:
every report is `sqlite3Close`, including the whole pre-fix generation, when
statement finalizers were firing at every quit with nothing closing anything —
and `AppDatabase.close()` disposes drift's statement cache while the library is
still healthy. The gap left is the `.timeout(3 s)` in `_prepareForShutdown`,
where the close does not finish. A SIGSEGV in `sqlite3_finalize` at quit is that
gap, not a new bug.

