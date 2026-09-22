# Notifications & Reminders

The overdue-tasks badge and the OS notification-budget rules behind `CalendarReminderService`/`TaskReminderService`. See [../../../CLAUDE.md](../../../CLAUDE.md) for architecture-wide rules and [../calendar/CLAUDE.md](../calendar/CLAUDE.md) for where the underlying events come from.

## The Overdue-Tasks Badge

The red dot on the folder panel's Tasks icon counts `scheduled_task_reminders`
rows (`OverdueTasksCubit`), not `TasksBloc` — the bloc holds one list of one
account, and `TaskReminderService` already walks every list on a 15-min cycle.
`isTaskOverdue` (`core/utils/task_due.dart`) is the shared rule, so the dot and
the pane's red due line can't disagree.

## A Scheduled Reminder Is a Request the OS May Discard

`CalendarReminderService` fetches **14 days** ahead but only hands alerts to the
OS for the next **36 hours**, capped at **48 alerts** across every account.
Those two numbers are the fix for reminders that silently never fired.

A meeting is not one alert. `NotificationService.reminderOffsets` expands a lead
time into a countdown — a 15-minute reminder is 15/10/5/0 — so one event costs up
to five. A fortnight of a working calendar therefore asked for *hundreds*. On a
real mailbox: **99 events, 321 requests**, against **100 rows** retained for the
app in usernoted's `record` table, all undelivered
(`~/Library/Group Containers/group.com.apple.usernoted/db2/db`). That table is
not documented as *the* pending set, so treat the ratio as the finding rather
than 100 as the ceiling. The figure usually quoted for the cap is iOS's 64; the
macOS one is not published.

Three things turned an overflow into permanent silence:

- **`UNUserNotificationCenter.add` reports success for a request it discards.**
  Nothing on the Dart side learned.
- **The row is written regardless.** `scheduled_reminders` records what was
  *asked for*, not what is queued.
- **`osRetainsSchedule` then believes the row.** The `unchanged` test skips that
  event on every later pass, so a dropped alert was never re-armed — for the
  life of the event, across restarts included.

The symptom is arbitrary rather than total: some alerts of a series survive and
others do not, so a meeting announces itself at the start with no warning
beforehand. Which of a triple the OS evicts is not documented and was not
established; the ratio is the finding.

Five things here are load-bearing:

- **The fetch window and the scheduling window are separate.** The fetch has to
  reach far enough to notice a meeting whose lead time is days long; the queue
  must not. A pass runs every 15 minutes, so the horizon rolls forward long
  before anything inside it fires.
- **No row for an event nothing was queued for.** This is the whole point of
  deleting the row for anything outside the horizon or past the budget — a row
  left behind is a claim the `unchanged` skip believes, which is precisely how a
  meeting comes to be skipped silently once it *does* come into range.
- **The budget is per app, so it cannot be spent per account.** Hence the two
  phases: fetch every account, then choose across all of them at once, soonest
  trigger first. Spending it one mailbox at a time would hand the first account
  everything. It stops rather than skips when full — taking a later, cheaper
  event once a nearer one has been refused puts the queue out of order for no
  gain. 48 rather than 64 because `TaskReminderService` queues into the same
  pool. **Expect the budget, not the horizon, to be what actually binds** on a
  working calendar — 48 alerts is roughly a day of meetings, well inside 36
  hours — so tuning the horizon alone will usually change nothing.
- **The OS is asked what it holds rather than assumed.**
  `NotificationService.pendingReminders()` returns a `PendingReminders`
  snapshot, taken once per pass (macOS `getPendingNotificationRequests` over the
  notifications channel; `pendingNotificationRequests()` elsewhere), and
  `holdsSeries` re-arms an "unchanged" event whose alerts have gone. That covers
  the cap *and* a schedule cleared behind the app's back, and it is what makes
  the row trustworthy rather than aspirational.
- **Null means "nothing learned", never "nothing pending".** A sub-window owns
  no plugin, Linux holds reminders in in-process timers (already covered by
  `osRetainsSchedule`), and a platform call can fail. Treating null as empty
  would reschedule the entire calendar every pass, which is the overflow again.

`holdsSeries` expects only the offsets still in the future — scheduling skips
the ones already gone by — so a meeting mid-countdown is not judged missing over
alerts it has already delivered, and a series with nothing left to fire is held
vacuously rather than rescheduled forever.

`PendingReminders` carries either macOS's keys verbatim or the hashed integer
ids `_idFor` derives from them, because that is how the two platform families
address an alert. The key format (`accountId::eventId`, then `::offset` for each
follow-up) is a contract with both `scheduleEventReminder` and the
`<kind>_reminder_` prefix the Swift side strips, which is why
`calendar_reminder_service_test.dart` pins it literally.

No migration is needed for rows written by earlier builds: the first pass finds
them outside the horizon and clears them, or finds the OS holding nothing and
re-arms.

## An Alert for an Account This Process Does Not Have Is Nobody's

Both reconcilers only ever visit the accounts in `AccountManager.accounts`, and
`clearAccount` only runs for a removal this process saw. So an alert keyed to
any other account id is one nothing in the process will ever cancel or move —
it fires on whatever schedule it was given.

Observed on a real machine: a meeting moved from today to tomorrow still
announced itself at today's time, three times. The alerts that fired belonged
to a **debug build** run that morning. Debug and release share the bundle id,
so they share the OS notification pool and (since the data-directory
consolidation) `~/.nightmail`; but the Keychain is per code signature, so the
debug build could not see the release build's accounts and had the same two
mailboxes added under fresh ids. Its reconciler queued today's meetings under
those ids and quit at 11:34. The release build rescheduled *its* copy of the
series for tomorrow correctly, and had no way to know the other copy existed.

Each pass therefore ends with an orphan sweep (`_clearOrphans` /
`_clearOrphanRows`), against two sources:

- **The rows** — every account id in `scheduled_reminders` /
  `scheduled_task_reminders` that is not configured has its alerts cancelled
  and its rows deleted. This is what a shared database leaves behind.
- **The OS's pending list** — `PendingReminders.orphanedEvents` reads the
  account id back out of each `accountId::eventId[::offset]` key and cancels
  any series under an unknown account. This is what a build with its *own*
  data directory leaves behind. Calendar only: the snapshot is of `event`
  alerts, and hashed integer ids (every platform but macOS) carry no account.

Two things here are deliberate:

- **Skipped while the account list is empty.** That is more likely the moment
  before accounts load than a user who removed every one, and `clearAccount`
  already handles removal. Cancelling everything on a transient empty list
  would re-arm the whole calendar on the next pass — the overflow again.
- **Two builds running at once will fight**, each cancelling the other's
  alerts every 15 minutes and re-arming its own when `holdsSeries` finds them
  gone. That is a developer-only situation and the alternative — alerts that
  cannot be cancelled by anyone — is what this section is about. If it bites,
  run one build at a time.

