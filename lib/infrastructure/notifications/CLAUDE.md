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

## The Countdown Tidies Itself

A 15-minute reminder delivers four banners. Left alone they pile up, so each
platform is asked to fold the series into one thing, in its own idiom. Every
mechanism keys off the *series key* — `<acct>::<event>`, the alert key with
the `::offset` stripped — so all of them depend on the key format pinned by
`calendar_reminder_service_test.dart`; change one, change all.

- **macOS** does both halves in Swift. At scheduling, every alert gets
  `threadIdentifier = event_reminder_<series>`, so Notification Center stacks
  the countdown even when it lands with NightMail not running. At delivery,
  `willPresent` calls `removeEarlierAlerts`, which reads the delivered list and
  removes the other alerts of the same series — the one being presented is
  excluded by identifier, and nothing outside the
  `event_reminder_<series>[::offset]` namespace is touched. "Starting now"
  therefore stands alone. This is the only platform with a delivery hook.
- **Linux** replaces outright: the in-process timers all `show` under one
  display id, the series key's, and the plugin hands a repeated id to the
  daemon as `replaces_id`. The timers themselves stay filed under each alert's
  own key so a cancel can reach them.
- **iOS** groups by `threadIdentifier`, which stacks with the latest on top.
- **Android** groups by `groupKey`, with the lead alert as the group summary —
  Android only *displays* an explicit group as one when it has a summary. A
  series scheduled after its lead time has passed has none and shows singly.
- **Windows** groups under a `WindowsHeader` per series; Action Center collapses
  the toasts under it, latest first. The header's `arguments` carry the same
  payload as the toasts so pressing it opens the meeting.

None of the plugin platforms remove earlier alerts: there is no callback at
delivery time, and a scheduled notification's id is also its alarm/toast
identity, so a shared id would replace the *pending* alerts rather than the
delivered ones.

## Two Builds of the App Cannot See Each Other's Alerts

Observed twice on a real machine: a meeting the organiser had moved still
announced itself at its original time, three times over. Both times the alerts
belonged to a **debug build** run earlier — `flutter run` adds the same two
mailboxes under fresh account ids, because the Keychain is per code signature
(`usesDataProtectionKeychain: kReleaseMode`), and its reconciler queued the
day's meetings under those ids. The release build reconciled *its* copy of the
series correctly and could do nothing about the other.

The first fix (commit 3c4bd1c) assumed the two builds share one OS notification
pool because they share a bundle id, and swept "orphan" alerts — any keyed to
an account this process does not have — from both the rows and the OS's
pending list. It shipped, ran every 15 minutes, and cleared nothing. Verified
in usernoted's own database (`~/Library/Group Containers/group.com.apple.usernoted/db2/db`,
macOS 27.0): every `record` row carries a `srce` UUID, all of the debug build's
requests share one and all of the release build's share another, stable across
relaunches and days. **The daemon files an app's pending requests under the
code-signing identity that queued them.** Both builds deliver through the same
`app` row, but `getPendingNotificationRequests` in one build never lists the
other's requests and `removePendingNotificationRequests` never removes them.
Sixteen debug-build alerts queued at 16:39 survived fifteen release passes and
fired the next day.

So the fix is at the source. `AppConfig.schedulesOsReminders` is true only in a
release build (or with `--dart-define=NIGHTMAIL_DEBUG_REMINDERS=true`); in any
other build a reconcile pass is a **drain** — `NotificationService.drainReminders`
cancels every event and task request this build's identity holds, and the
service deletes the rows *its own* accounts wrote — and nothing is fetched or
scheduled. Four things here are deliberate:

- **The drain is not keyed by account.** The accounts a developer run held
  last week may since have been re-added under fresh ids; the OS is asked what
  it holds and all of it goes. This is also what clears the leftovers of every
  debug run made before this change: the first debug launch afterwards is the
  cleanup.
- **The row deletion *is* keyed by account.** `~/.nightmail` is shared with the
  release build, whose rows are its record of what it holds. Deleting them
  would make it re-arm its whole calendar next pass. (The orphan-rows sweep
  below does exactly that from the debug side, which is why the drain returns
  before reaching it.)
- **The overdue-tasks badge is dark in such a build**, since it counts the rows
  the drain deletes. Set the define to see it, and quit the debug build before
  the meetings it queued fall due — nothing else can cancel them.
- **The release-side orphan sweep stays**, for what it *can* reach: an account
  removed while the app was not running, or re-added under a fresh id, leaves
  rows and alerts under this build's own identity. `_clearOrphans` /
  `_clearOrphanRows` cancel and delete those, from both the rows and (calendar
  only — hashed integer ids carry no account) the OS's pending list. Skipped
  while the account list is empty, which is more likely the moment before
  accounts load than a user who removed every one; `clearAccount` handles
  removal. A debug build's rows in the shared database are still deleted here;
  the cancel that goes with them is a no-op, and harmless.

To see what is queued and by whom, decode `record.data` (a binary plist holding
the request identifier and `srce`) for the rows whose `app_id` maps to
`au.com.sharpblue.nightmail`; undelivered ones have `delivered_date IS NULL`.
