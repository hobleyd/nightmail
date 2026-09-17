# Local Cache Database (sqlite / drift)

Why `nightmail_cache.sqlite` is never explicitly closed via `sqlite3_close_v2`. See [../../../CLAUDE.md](../../../CLAUDE.md) for architecture-wide rules.

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

