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
