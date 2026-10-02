# Commitments

The Commitments pane (`HomeView.commitments`, `CommitmentsDayPanel`) reads
mail, calendar and tasks as one stream of obligations: what you owe, what
you are waiting on, and which received mail needs a decision. It is the
first consumer of the System One (typed decision) providers described in
[ai-subsystem.md](ai-subsystem.md). See [../../CLAUDE.md](../../CLAUDE.md)
for the layer rules this follows.

## The pipeline

```
Sent + Inbox cache ─► DetectCommitments ─► System One model (Triage route)
                           │                    noul / choice / score answers
                           ▼
                 commitments + commitment_scans (drift)
                           │
                           ▼  resolution pass (no model)
                   CommitmentsCubit ─► CommitmentsDayPanel
```

* **Input is the local cache only.** `CommitmentsCubit` finds the active
  account's Sent and Inbox folders in the folder cache by well-known id or
  display name (`isSentMailFolder`, `isInboxFolder`) and takes the newest
  60 rows of each. The only network the pane causes is the model's calls.
* **One request per unscanned message**, capped at 30 per scan
  (`DetectCommitmentsParams.maxToClassify`). Messages the model has seen are
  recorded in `commitment_scans`, including the ones that produced nothing,
  so a metered API is never asked the same question twice. A mid-scan
  provider failure keeps what was classified and surfaces as a warning line,
  not an empty pane.
* **The state the model sees** is structured (`direction`, `subject`,
  `from`, `to`, `date`, `body`), and `body` is the *newest reply only*
  (`latestReplyText`) capped at 1500 characters — so quoted history cannot
  be read as the sender's own words, and so it fits the ~512-token window of
  the smaller Laya checkpoints. A folder listing carries previews only;
  when no body is cached the preview stands in.
* **Questions.** Sent mail: *does the sender promise something* (→ I owe),
  *does the sender ask for something* (→ they owe me), a coarse due choice
  (`today` / `this_week` / `later` / `none`) and a three-level urgency score.
  Received mail: *does this need action or a reply* (→ needs action), *does
  the sender promise to deliver something* (→ they owe me), a bulk /
  newsletter / notification veto, and the same due and urgency questions.
  A noul answer counts at ≥ 0.6. The due choice is coarse **on purpose**: a
  System One model picks an option, it cannot write a date.

## The ledger

`Commitment` is keyed `(kind, emailId)` — `id = '<kind>:<emailId>'` — so one
sent message can raise both an *I owe* and a *they owe me*, and a re-scan can
never duplicate either. `upsertCommitments` preserves an existing row's
status: a user's *done* or *dismissed* survives re-detection. Who / subject /
excerpt travel in one encrypted blob (`CacheEncryptionService`), the query
columns are plaintext, same split as the mail cache.

**Resolution** runs after every scan over everything open and uses no model:

| kind | closed automatically when |
|---|---|
| they owe me | the counterpart wrote back in the same thread, after the message that raised it |
| needs action | the account holder replied in the same thread, after receiving it |
| I owe | never — a later message of mine may be "still working on it"; only Done closes it |

Threads are matched on `conversationId`, so IMAP mail (no thread id) is
never auto-resolved.

## The pane

Today (cached calendar events for the day, the count of task-reminder rows
due today across every list, and every commitment due today or overdue),
You owe, Waiting on (with age), Needs a decision (with "N emails need action
· M don't", where M is scanned Inbox messages that produced no row). Tapping
a row opens its message exactly as a task's linked mail does
(`EmailDetailLoadRequested` + `EmailListThreadFocusRequested` +
`HomeCubit.selectEmail`); Done / Dismiss call the cubit. A completed poll
cycle (`MailPollerState.pollGeneration`) triggers a scan; an account switch
reloads. Both listeners are optional so the pane works where those blocs are
absent.

Triage without a System One route is a **setup card**, not an error: the
pane stays usable and points at Settings › AI.

### In its own window

Double-clicking the footer button opens a `commitments` sub-window
(`CommitmentsWindowApp`), like Calendar and Tasks. Two things differ from
those:

* **It is sized to the screen it was opened from** (`_screenInfo` in
  `main()`), because the layout is designed for that: from
  `CommitmentsDayPanel.kBoardMinWidth` (960 px) the pane stops stacking its
  sections and lays them out as a four-column board (`_BoardBody`) — Today,
  You owe, Waiting on, Needs a decision — each column scrolling on its own,
  each item a card that also shows the excerpt of what was said and an
  explicit Open action. The board stops growing at 1760 px and sits centred
  on wider screens. The same `LayoutBuilder` switch applies to the docked
  pane, so dragging it that wide gives the board too. The window's geometry
  is remembered per display (`commitmentsWindowBounds`) and wins over the
  screen-sized default once the user has moved it.
* **It has no reading pane**, so a row opens its message in an email-view
  window instead: `CommitmentsDayPanel.onOpenEmail` is the override, and the
  window fetches the full body with `GetEmail` first (the ledger holds only
  the message id), then hands the email-view window the same map the main
  window's double-clicked list row does.

The sub-window has no `MailPollerCubit`; the pane's poll listener is
optional, so there the ledger refreshes on open and on the Refresh button.

## Scheduling a time block

Every row and card has **Schedule** beside Done and Dismiss. It books a
calendar event for the commitment, chosen by `SuggestTimeBlock` (pure, under
`domain/usecases/commitments/`) from a quick look at the coming days:

* **Horizon from the due reading**: *today* → today only (or the next
  working day once the working window has passed); *this week* → through
  Friday, never fewer than two days; *later* / *none* → the next five working
  days. Weekends are skipped.
* **Load** is busy minutes inside the working window (9–17), overlapping
  meetings merged; free and all-day events do not count.
* **Least load wins, earliest day on a tie**, then the first run of the
  requested length (default 1 h, on a 30-minute grid, after now) that no
  meeting overlaps. If the lightest day has no gap the next lightest is
  tried; if nothing fits anywhere the block opens the lightest day flagged
  `hasConflict`.

The suggestion is only a starting point. `ScheduleCommitmentDialog` lets the
user move it, in two layouts chosen by window width (1100 px):

* **Compact** (the docked pane, phones): the candidate days as a list with
  load bars, a start-time dropdown with the busy slots marked, and length
  chips (30 min – 2 h).
* **Wide** (the detached window): a week grid — one column per candidate
  day against an hour axis, meetings drawn to scale, the proposed block in
  accent, the now-line — where a click in a day column puts the block there
  (snapped to the grid, kept inside the working window), beside a details
  column with the reason, the chosen time, length chips and the conflict
  warning.

Confirming calls `CommitmentsCubit.schedule`, which creates the event through
`CreateCalendarEvent` with a subject that reads in a week view ("Migration
numbers — for Sarah", "Reply to James: …", "Follow up with AWS: …"), the
excerpt in the description, a 15-minute reminder and the local IANA timezone
(`localIanaTimezone`). The event id and times are recorded on the ledger
(schema v19: `scheduled_event_id`, `scheduled_start_ms`, `scheduled_end_ms`)
and survive re-detection like the status does. Scheduling again **moves** the
same event (`UpdateCalendarEvent`); if that fails because the event was
deleted by hand, a new one is created. The row then shows the block's day and
time in place of its age. The main window's reminder reconciler picks the new
event up on its next cycle, so the cubit does not touch the notification
plugin (which must not be initialised from a sub-window anyway).

## Future Me: the week-ahead forecast

`ForecastWorkload` (pure, `domain/usecases/commitments/`) turns the calendar
cache, the open ledger and the task-reminder rows into a `WorkloadForecast`
on every refresh; `CommitmentsCubit._contextFor` computes it from the same
two-week calendar read that feeds Today, so it costs no extra I/O.

* **Per day** (today and the next working days, five in all): *capacity* is
  the working window minus meetings — where the user's own commitment
  blocks are **not** meetings, they are demand already placed — and
  *demand* is blocked time plus 60 min per unscheduled commitment landing
  that day plus 30 min per task due. A commitment lands on its block's day
  if it has one; otherwise today when due today or overdue, the week's last
  working day when due this week, nowhere when open-ended. **Overloaded**
  means demand exceeds capacity; *tight* means more than three quarters
  spoken for.
* **A `RebalancePlan` per overloaded day**: its movable items, least urgent
  first (blocks, then unscheduled commitments — an item due today that
  lands on today cannot move), each sent to the freest other day its
  deadline allows, into a real free slot found by `SuggestTimeBlock`, with
  earlier moves counted as pseudo-events so two never take the same slot;
  the plan stops once the day fits. `RebalanceDialog` shows the moves with
  checkboxes and applies the kept ones through `CommitmentsCubit.applyMoves`
  (each a `schedule`, so a block is moved rather than duplicated).
* **Open slots**: gaps of 45 min or more left in today after now, each
  paired with the most pressing unscheduled commitment (overdue first, then
  urgency, then due, then age). A slot is **freed** when a meeting
  overlapped it at the previous forecast and is gone now — the cubit keeps
  the previous calendar snapshot for this, and `_freedSlotStarts` keeps the
  label on the slot across refreshes until it is filled or has passed.
  `fillSlot` books an hour (or the whole gap if shorter).

`WorkloadStrip` shows it: in the side pane a "Week ahead" box with a
pressure cell per day, a warning row per overloaded day with **Rebalance**,
and the open slot with **Schedule**; in the detached window a full-width row
of day cards above the board — stacked bar of meetings / blocked / estimated
against the working day, the numbers, Overloaded / Tight badges, Rebalance —
with the open slot as its own callout at the end.

Not built: natural-language control.

## Deliberate limits

* Active account only, like the Tasks pane. `EmailRepository.getEmail` has
  no account parameter, so a cross-account body fetch is not available.
* Folder matching by display name does not survive a localized Graph
  mailbox ("Posteingang", "Gesendete Elemente") — the same bet
  `MailPollerCubit` and `junk_folder.dart` make.
* Time-blocking, "Future Me" workload forecasting and natural-language
  control from the product vision are scheduling engines, not a pane; they
  are not here.
* `HomeView.commitments` is persisted through `AppSettings.saveActiveView`
  like the other views, so the pane reopens where it was left.
