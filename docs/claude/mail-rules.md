# Mail Rules

Settings > Rules, across Microsoft Graph (and Nightware, which implements the
same resource) and Gmail. Cross-cuts `domain/entities/mail_rule.dart`,
`data/datasources/remote/mail_rule_codecs.dart`, `presentation/blocs/mail_rules`
and `presentation/pages/settings/mail_rules_page.dart`. Built in the shape of
[out-of-office.md](out-of-office.md) — read that first; the account-scoped
repository, the `UnsupportedFailure` for IMAP, the self-contained page and the
factory cubit are all the same decisions for the same reasons.

## A rule is a server setting

Graph's inbox `messageRules` (`/me/mailFolders/inbox/messageRules`), Gmail's
`/users/me/settings/filters`. They run however the user reads their mail and
nothing is cached; every change is followed by a quiet re-read rather than a
local patch, because Graph normalises what it is given and a Gmail edit comes
back under a new id.

**Graph is the standard.** `MailRuleConditionKind` and `MailRuleActionKind`
are Graph's predicate and action names verbatim — `GraphMailRuleCodec` uses
`kind.name` as the JSON key — plus three Gmail-only actions (`archive`,
`star`, `neverSpam`) with no Graph equivalent. What each provider can say is
a `MailRuleCapabilities` value (`.graph`, `.gmail`); the screen offers exactly
that set rather than branching on the account type.

## Never rewrite what the form cannot show

Graph **replaces** `conditions`, `exceptions` and `actions` whole on PATCH
(the same trap as `automaticRepliesSetting`), and a Gmail edit is a delete and
re-create. So a rule holding anything the entity does not model — Graph's
`categories`/`assignCategories`/`sensitivity`/`messageActionFlag`, a Gmail
forward, size test or `CATEGORY_*` label — decodes with
`hasUnsupportedParts` and opens **view-only**. Turning it on or off,
reordering and deleting still work: `setMailRuleEnabled` and
`reorderMailRules` PATCH only `isEnabled`/`sequence`, never the rule. Do not
"fix" a view-only rule by dropping the unknown keys on save.

`encode` always sends `exceptions` (as `{}` when empty) — omitted, a PATCH
leaves the old exceptions in place after the user removed them.

Graph's `isReadOnly` (rules Outlook keeps client-side) blocks everything but
viewing; `hasError` (usually a deleted target folder) is shown on the row.

**Reordering is a neighbour swap, never a renumber.** Graph refuses any PATCH
to a read-only rule, `sequence` included, so renumbering the whole list fails
part-way in any mailbox holding one. `MailRulesCubit.move` swaps the two
rules' sequences (two PATCHes) and `canMove` disables an arrow whose
neighbour is read-only. Equal sequences — Outlook leaves them — cannot be
swapped, so the moved rule steps one past its neighbour instead.

**The open side of a size range is written as a true bound**, not 0:
`maximumSize` Int32-max for "at least", `minimumSize` 0 for "at most". Graph
does not document what a zero maximum means, and if it is read literally "at
least 500 KB" matches nothing, with no error.

## From the mail list

Each desktop list row (and thread header) has a rule button beside the flag,
where a delete button used to be — delete is still the list toolbar, the
reading pane and the phone's swipe. `showNewRuleForEmail` opens the
same editor on the active account with one condition filled in: the sender,
as `fromAddresses` where the provider has it, else `senderContains` (Gmail).
No action is pre-chosen; a default one click from Save would usually be a
move or a delete.

**"Run on <folder> now"** (`MailRuleRunNow`, `core/rules`) is a checkbox on
a new rule's editor, unticked by default, naming the folder the mail list is
showing. From a list row that is the row's folder; from Settings > Rules it
is the folder behind the Settings dialog — `SettingsDialog.open` carries the
`EmailListBloc` across (read nullably: the macOS app-menu "About" opens
Settings from above HomePage's providers, and then there is no checkbox), and
it is offered only while the screen is on the active account.
A saved rule is run the same way from the **run button** on its Settings >
Rules row (left of Edit), shown under the same conditions as the checkbox and
disabled, with the reason as its tooltip, wherever the checkbox would be. It
runs the rule as stored, enabled or not, and asks first — with the count —
before a move or delete; marking read just happens. A view-only rule
(`hasUnsupportedParts`) is refused: the parts the entity does not model are
not in it, and a dropped condition or exception would widen the run.
No provider runs a rule on demand (Graph has no call; Gmail's "apply to
matching conversations" is its own client searching and relabelling), so the
app does it:

- **Over what the list holds, not the whole folder.** The folder cache is the
  recent pages only, and paging a Gmail folder costs ~1,010 units per 25 rows
  ([gmail-quota.md](gmail-quota.md)). The checkbox says older mail is left
  alone. Only rows that are themselves in the folder (`isMovableFrom`) — a
  thread's Sent copy listed beside its reply is not moved.
- **Matched with `MailRuleMatcher`, so only what it can test is offered.** An
  untestable condition answers false; as an *exception* that would make the
  run act on more mail than the rule says. Body tests are refused too — a
  list row has no body — and so is "has attachments" on Gmail, whose
  `format=metadata` rows never say. The checkbox is disabled with the reason.
- **Only move, delete and mark read** — what the mail list already does,
  through its own events so rows leave at once and the outbox carries the
  change. **Never forward**: that would send old mail on to other people.
- **Mark read before a move is awaited, not an event**: the list's events run
  concurrently, and a Graph move re-ids the message under a racing PATCH.
- Runs only after the save lands, on the draft the user typed, and only if
  the list still shows that folder on the same account — checked at run
  time, since `INBOX` is the same id on every Gmail and IMAP account.

## Gmail filters

- **No update.** `settings.filters` is create/get/list/delete, so
  `updateMailRule` creates the new filter **first** and deletes the old one
  after: a failed create leaves the original. An edit that lands back on the
  stored settings collides with the still-present original ("Filter already
  exists") and is treated as a no-op; the same 400 on a *new* filter is
  reported in words.
- **Actions are label arithmetic.** Move = add label + remove `INBOX`; copy =
  add label ("Apply label"); archive = remove `INBOX`; delete = add `TRASH`;
  mark read = remove `UNREAD`; importance high/low = add/remove `IMPORTANT`;
  star = add `STARRED`; never spam = remove `SPAM`. User labels are
  `Label_<n>`; any other system label makes the filter unsupported.
- **Criteria are search text, carried verbatim** as a single value, so an
  untouched filter writes back byte-for-byte. Several values are ORed, with
  multi-word ones bracketed. The editor separates alternatives with `;`
  (Outlook's separator) because commas occur inside phrases.
- **No forwarding.** Gmail forwards only to an address verified under
  Settings > Forwarding; that flow is not built, so forward is not offered and
  a filter that forwards is view-only.
- No names, no order, no disable: the list describes each filter from its
  criteria (`describeMailRule`) and hides the switch and the arrows.

## Permissions

Writing rules needs the same scope as writing an automatic reply —
`MailboxSettings.ReadWrite` on Graph, `gmail.settings.basic` on Gmail — and
reading needs nothing new (`MailboxSettings.Read`, `gmail.modify`). So the
cubit calls `hasOutOfOfficeWriteAccess`/`requestOutOfOfficeWriteAccess`
directly; everything in out-of-office.md about superseded scopes, refresh
scopes and shared mailboxes' credential owners applies unchanged.

## Nightware

Nightware may not serve `messageRules` yet; a 404/501 on the list from a
NightMail Server account becomes `UnsupportedFailure` ("not available on this
server yet") rather than an error with a useless retry.

## IMAP: rules NightMail runs itself

IMAP has no rules API this app speaks (ManageSieve, RFC 5804, would be the
server-side route), so an IMAP account's rules are **NightMail's own**: the
repository hands the screen a `LocalMailRulesDatasource` and
`LocalMailRuleRunner` applies them. `MailRuleCapabilities.local` is what can
be tested from an envelope and body and done with plain IMAP — no importance,
categories, size, headers, redirect; `star` is `\Flagged` here (labelled
"Flag it"). `runsOnServer: false` is the one flag the rest of the slice
branches on: no permission prompt (the OAuth scope checks answer false for
IMAP and would block every save), no connectivity check for edits, and a
screen header that says plainly the rules run **on this device, while
NightMail is open**. Mail that arrives while it is closed is handled at the
next launch; the mobile background service does not run them.

**Storage** is files in the app data directory, like `AppSettings`
(`MailRuleStore`): rules as Graph `messageRule` JSON, and progress — the
Inbox UIDVALIDITY and the highest UID offered to the rules — in a separate
file, because the runner writes it per message and the screen writes the
rules. Both written via temp-file-and-rename.

**Where it runs.** At the top of the poller's non-delta branch, for
`ImapAccount`s only (Gmail shares that branch), main window only, inside the
account's connection gate — first, so the counts and the Inbox page the cycle
reads already reflect what the rules did. A run that changed the Inbox forces
the replacing Inbox re-list **even on the baseline-priming first cycle**,
which otherwise lists nothing and would leave moved rows on screen. A rules
failure is logged (`[MailRules]` in diagnostics.log), never the cycle's.

The rules that keep it from doing damage:

- **Progress never starts at, or resets to, 0.** Missing or corrupt
  progress, a changed UIDVALIDITY, or rules switched on from none all start
  after the Inbox's current newest message (UIDNEXT-1 from a fresh SELECT)
  and process nothing already there. No enabled rules deletes the progress so
  the next switch-on starts from that moment. A start from 0 would move,
  delete or forward the whole Inbox history.
- **Claim before acting — at most once.** Progress is saved *before* a
  message's actions run. A missed move leaves mail visibly in the Inbox; a
  repeated forward or copy goes to other people. Where the Inbox accepts
  keywords (`\*` in PERMANENTFLAGS) the claim is also `$NightMailRules` on the
  message, and the search carries `UNKEYWORD $NightMailRules`, so another
  device (the phone) skips it on its next look. **Only with CONDSTORE is the
  claim a compare-and-set**: the arrivals fetch reads each MODSEQ and `claim`
  stores the keyword `UNCHANGEDSINCE` it; a MODIFIED answer means another
  device got there first, and the message is left. Without CONDSTORE a plain
  `+FLAGS` succeeds for both, so two devices that poll at the same moment —
  the usual case, since IDLE wakes both — can both act. Without keywords at
  all it is per device. The keyword is visible to other clients, some of
  which show it as a tag. Losing the network mid-message stops the run with
  that message's actions lost.
- **Failures stop the run early.** The datasource reports most dropped
  connections as a plain `ServerException('IMAP error')`, not a
  `NetworkException`, so a failed claim ends the run (a flag write almost only
  fails when the connection has gone), and so do two failed actions in a row
  — otherwise every remaining message in the batch would be claimed and none
  acted on. A single refused action is logged and the next tried; a rule
  whose folder has been deleted therefore fails with a log line only (there
  is no `hasError` for local rules).
- **`UID n+1:*` matches the last message even when nothing is new** (`*` is
  the last message and the range is unordered), so results at or below the
  mark are dropped. After a short batch progress jumps to UIDNEXT-1 from the
  same SELECT — anything below it not offered was claimed elsewhere or
  deleted; after a capped batch (50 per cycle) it stays at the last offered.
- **Bodies are read with `BODY.PEEK[]`** (`peekEmail`), and only when a rule
  tests the body; `getEmail`'s `BODY[]` would mark every new message read.
  Text tests match case-insensitively against rendered text, not markup.
- **Within a message:** rules in sequence; a rule that stops processing, or
  moves or deletes, ends the list. Actions that leave the message in place
  run first and the one move/delete last (it changes the id).
- **Nothing it does can feed itself.**
  - No move or copy into the Inbox: a copy arrives as new mail above the mark
    and matches again, every cycle. The picker leaves the Inbox out for IMAP
    and the runner refuses it anyway (a hand-edited file, an old rule).
  - No forward of a message whose `Auto-Submitted` header is anything but
    `no` (RFC 3834; read by a second small FETCH beside MODSEQ, kept apart
    from the envelope fetch because header fields fetched beside ENVELOPE
    replace it in the parser), and every rule forward is sent with
    `Auto-Submitted: auto-forwarded` (`forwardForRule`, not the shared
    `forwardEmail`). That is what breaks A→B→A between two accounts, and a
    bounce coming back. Forwards to the account's own address or aliases are
    refused outright.
- **Delete is Trash or nothing.** `trashEmail` refuses when the server has no
  Trash, where the app's own `deleteEmail` falls back to `\Deleted` +
  EXPUNGE — fine behind a confirmation dialog, not for a rule.
- **Forwards drop inline images.** `_forwardBuilder` re-attaches
  attachment-disposition parts only, so an HTML original's `cid:` images
  arrive broken — true of the app's own forward as well.

## Migrating rules with the mail

`AccountMigrationService` hands both job scopes (Inbox and whole account) to
`MailRuleMigrator` once the mail is across — after, so the folders an account
job has just created exist to file into. A rules failure never fails the job.

- **Strict translation** (`MailRuleTranslator`). A rule is copied only if the
  target can say exactly the same thing; a lost condition or exception makes
  a rule act on more mail, a delete rule most dangerously. Skipped rules are
  listed with the reason in the migration dialog. Loosenings, each bounded:
  - `fromAddresses`/`sentToAddresses` stand in as sender/recipient
    *contains* where the target lacks the exact test (Gmail) — Outlook's own
    "from X" rule is `fromAddresses`, and most Outlook rules would otherwise
    never reach Gmail.
  - "Stop processing" into Gmail (no rule order) is dropped only when no
    later rule deletes or forwards; otherwise the rule is skipped, since on
    Gmail both would run.
  - A move into Gmail's Trash/Archive becomes delete/archive; any other
    system label is skipped (filters file into user labels only).
- **Gmail's criteria are search syntax.** Leaving Gmail, only plain
  `a OR b` lists translate (anything with brackets, quotes, operators or
  `-` is skipped); entering Gmail, every value that is not a bare address
  or domain is quoted, or `-draft` would mean "not draft". Gmail to Gmail
  copies verbatim.
- **Folders** map by special kind first, then by full path against a *live*
  walk of the target (the cache misses folders the job just created, and
  creating one twice fails); missing ones are created level by level, or as
  one `A/B` label on Gmail, whose `__virtual__` parents cannot be created
  under.
- **Once per account pair.** The result is stored (`MailRuleStore`,
  `mail_rule_migration_<source>__<target>.json`) and a finished copy is never
  repeated — jobs re-run on every resume and rescan, and copying again would
  resurrect a migrated rule the user has since deleted or changed. Only
  `needsPermission` and `failed` retry. A rule identical to one on the target
  (or Gmail's "Filter already exists") counts as already there. Per pair, not
  per job, so an Inbox job and an account job do not copy twice.
- **Permission.** A background job cannot open a sign-in window, so a server
  target without the write scope records `needsPermission` and the dialog
  offers "Sign in to allow it, then copy rules". Checked only when
  `capabilities.runsOnServer` — the OAuth check answers false for IMAP.
- **NightMail's own IMAP rules pause while their account is a migration
  target** (`LocalMailRuleRunner`'s `isMigrationTarget`, any running or
  paused job): migrated mail arrives as new Inbox UIDs and the rules would
  act on mail the old server already handled. Progress is forgotten, so they
  restart from "now" afterwards. Gmail's `insert` and Graph's MIME create do
  not run server rules, so only IMAP needs this.
- **The old account's copies are the user's call.** Once the copy is done
  the status dialog asks whether to turn off the migrated rules on the old
  account — while mail reaches both, both sets act on it — and the answer is
  stored with the result (`SourceRulesDecision`), so it is asked once. Only
  `migratedSourceRuleIds` (copied, or already there) are switched off; a
  skipped rule has no copy and keeps working where it is. Each is a PATCH of
  `isEnabled` alone, so a view-only rule loses nothing. A server account
  without the write permission gets "Sign in and turn off" rather than a
  sign-in sprung on a plain button; a rule that will not switch off leaves
  the question open with the reason. Gmail filters cannot be switched off,
  so for a Gmail source the dialog says to delete them in Settings → Rules
  instead.

## Folder picker

`getMailRuleFolders` reads the local folder cache (the whole tree, walked by
`EmailRepositoryImpl.getMailFolders`), falling back to the same walk — without
writing the cache — for an account never opened. Folders are renamed to their
full path and sorted; Gmail's `__virtual__` path parents and SPAMDB are left
out, and on Gmail so is every system label (INBOX, SENT, TRASH…): Gmail
refuses some and reads others back as a different action, which would leave
the filter view-only the moment it was saved. A rule's current folder is always in the dropdown, as "(unknown folder)"
if need be: a `DropdownButton` whose value is missing from its items throws.
