# Desktop Sub-Windows & FFI Isolation

How `desktop_multi_window` sub-windows relate to the main window, and the FFI-plugin hazard that follows from each getting its own isolate. See [../../../CLAUDE.md](../../../CLAUDE.md) for architecture-wide rules and [../../../macos/CLAUDE.md](../../../macos/CLAUDE.md) for the macOS-specific native-channel rules this interacts with.

## Sub-Windows and FFI Plugins

**Critical rule: an FFI plugin may only be initialized in the main window.**

`desktop_multi_window` re-enters `main()` with a fresh `FlutterEngine` for every
sub-window, so each one gets its own isolate, service locator and statics.
FFI plugins hand the native side a `NativeCallable` trampoline **owned by the
isolate that registered it**. When a sub-window closes, its isolate dies and the
trampoline is deleted — but the native library keeps the pointer. The next time
native code fires it, the VM aborts:

```
error: Callback invoked after it has been deleted.
isolate_group=(nil), isolate=(nil)
Lost connection to device.
```

That is a **`FATAL` in the VM, not a Dart exception** — no `try`/`catch` can
contain it, and it kills the whole process including the main window. Note the
`isolate=(nil)`: the callback ran on a native thread with no owning isolate,
which is the signature of this bug. Nothing in the Dart stack will point at the
plugin, and the symbolized frame is usually meaningless
(`InternalFlutterGpu_Texture_AsImage` or similar nearest-symbol noise).

Check `windows/flutter/generated_plugins.cmake` for what is affected —
`FLUTTER_FFI_PLUGIN_LIST` is the list of plugins with this hazard.
`flutter_local_notifications_windows` is the live one; it never disposes its
`NativeCallable` and the app never calls its `dispose()`.

`AppWindow.isMain` (`lib/core/platform/window_utils.dart`) is how code tells
which engine it is in. It is set from `main()` **before**
`configureDependencies()`, because lazy singletons decide at construction time
whether they may touch process-wide native resources.

### Closing a sub-window is a request, not an act

`windowManager.close()` *posts* the close (Windows `SC_CLOSE`) and reports
success either way, so a dropped one leaves a window on screen that has already
turned its `setPreventClose` guard off — see `_close` in `compose_window.dart`,
which retries and puts the guard back. `destroy()` is never an option in a
sub-window: it is `PostQuitMessage`/`NSApp.terminate` and takes the app with it.

### Draft autosaves are serialised, and everything that deletes waits on them

`ComposeFormState._saveDraft` chains every save behind the one on the wire
(`_saveInFlight`), and `_submit`, discard and the dispose flush all call
`_settleDraftSaves()` before reading `_serverDraftId`. Two overlapping
*creates* each mint a draft and only the second is remembered — the first
sat in Drafts for good and Send deleted the wrong one. Gmail showed it most:
a create is a `getProfile` round trip, a MIME build and an upload of the
whole raw message, which routinely outlasts the 1.5 s debounce between two
pauses in typing. Graph has the same shape with one request per attachment.

A queued save reads the fields when it *runs*, not when it was scheduled, and
a second queued save is coalesced into it (`_saveWaiting`). A save that
finishes after Send was pressed still records its id — that is what
`_submit` deletes. `compose_close_test.dart` holds a create on the wire with
`createGate` to pin all three paths.

### Where a window opens

`WindowBoundsService` persists geometry per display; the main window and each
*kind* of sub-window get their own file (`WindowBoundsService.forWindowKind`).
Compose and event-edit are the sub-windows that record one — `main()` restores it
instead of centring on the parent's screen, and `_close` saves before closing
because the close tears the engine down and a debounced save would never fire.
Event-edit saves the width *without* its schedule pane (`_withoutSchedulePane`),
since the pane opens closed and the form column doesn't grow to fill the window.

Bounds are logical pixels at the window's *current* scale factor, so restoring
onto a monitor at another scale takes a second `setBounds` once Dart's ratio
catches up (`_settleBounds`), while the window is still hidden — or it opens in
the wrong place and visibly jumps.

### How the notification plugin applies the rule

`NotificationService._plugin` returns null outside the main window, so every
call through it is a no-op — including `initialize`, so the `NativeCallable` is
never registered in a sub-window at all. Beware that the plugin is easy to
reach by accident: `NotificationService` self-initializes in its constructor and
is pulled in transitively by `CalendarBloc`, `TasksBloc` and `EventEditBloc`, so
merely opening the Calendar, Tasks or Event-Edit window used to be enough.

Reminders are not lost. `CalendarReminderService`/`TaskReminderService` run in
the main window only (started from `HomePage.build`), reconcile every account's
events against the persisted schedule tables, and are the authority for what the
OS actually holds. Sub-windows nudge them via `ReminderReconcileChannel` (a
`unidirectional` `WindowMethodChannel` — the app's only cross-window channel)
so a change applies at once instead of waiting up to 15 min for the next cycle.
`reconcileAll()` therefore coalesces rather than drops a request that lands
mid-cycle. Because the reconcilers re-derive state by *fetching* the account,
anything that nudges must commit to the server first.

macOS is exempt: its notifications go through a bespoke
`UNUserNotificationCenter` method channel that is process-wide and works from
any engine, so sub-windows there schedule directly.

**Known remaining hole:** hot restart replaces the root isolate, deleting the
main window's trampoline while the native plugin created by the old isolate
lives on — the same fatal abort, debug builds only. Upstream limitation; if you
hit this crash in `flutter run` and no sub-window was involved, that is why.

