# Out of Office Replies

Settings > Out of Office, across Microsoft Graph and Gmail. Cross-cuts `domain/repositories`, `data/datasources/remote`, and `presentation/blocs/out_of_office` — see [../../CLAUDE.md](../../CLAUDE.md) for architecture-wide rules.

## An Out of Office Reply Is a Server Setting, Not an App Preference

Settings > Out of Office edits the **mailbox's own** automatic reply — Graph's
`automaticRepliesSetting` on `/me/mailboxSettings`, Gmail's vacation responder
at `/users/me/settings/vacation`. Nothing about it is stored by the app or
cached: it applies however the user reads their mail, and the screen is a view
onto the provider.

`OutOfOfficeDatasource` is a narrow interface of its own rather than methods on
`EmailRemoteDatasource` — the same precedent as `ConversationFolderDatasource`.
Only two of the three providers have the concept, and putting it on the shared
interface would force `ImapDatasourceImpl` to stub a method it can never
honour. `OutOfOfficeRepositoryImpl` tests for it with `is` and answers
`UnsupportedFailure`, which the screen reports as "not available for this
account" rather than as something that broke.

The repository is **account-scoped**, not "the active account", and its
`_datasourceFor` returns null rather than falling back to the active account
the way `EmailRepositoryImpl`'s does. There the fallback is a convenience; here
it would write one mailbox's away message onto another's. The screen lists
every signed-in account for the same reason.

### The scope is asked for on Save, and Microsoft's has a trap

Both providers can **read** the setting under scopes every account already
holds — `MailboxSettings.Read` is in `MicrosoftAuthService._scopes`, and
`users.settings.getVacation` accepts `gmail.modify`. Only writing needs
anything new, so the form always loads and the consent lands on the button
that needs it.

- **`MailboxSettings.ReadWrite` supersedes `MailboxSettings.Read`.** That is
  why it is incremental even though it needs no admin consent and is not
  restricted: moving it into the base set leaves every account authorised
  before today holding a token that reads the setting fine and 403s the moment
  the user presses Save — a silent failure a long way from its cause. It is
  also why `grantsMailboxSettingsWrite` matches **whole scope tokens** rather
  than by substring: `MailboxSettings.Read` is a prefix of the write scope, and
  a `contains` test in the other direction reads every existing account as
  already able to write.
- **`_refreshScopes` must carry it.** A Microsoft refresh names the scopes it
  wants, so refreshing with the base list alone hands back a token *without*
  the write scope an hour after it was granted — the grant reads as having
  lapsed. Same trap as `filesReadScope`, and asking for an unconsented scope
  fails the refresh outright, so it is added only when the token proves it was
  consented to.
- **Gmail's `gmail.settings.basic` is incremental for the usual reason** — the
  consent belongs in front of the feature, not in front of *adding a mail
  account*. `grantsMailSettingsAccess` accepts `https://mail.google.com/` too:
  an account that granted the full-mailbox scope to empty its trash can already
  do this and must not be asked twice.
- **A decline is an answer, not an error.** Nothing has been changed, so the
  save simply does not happen and nothing is reported. The dialog says the
  provider is about to ask *before* the destructive-looking button, the same
  shape as the empty-trash consent.

### The two providers disagree about when

This is where the off-by-a-day bugs live, and the entity carries **wall-clock
local times rather than instants** because of it.

- **Graph stores a local time plus a zone name, and the zone is the
  *mailbox's*** — read from `mailboxSettings.timeZone`, which need not be the
  device's. So the bounds are carried across verbatim: `_parseMailboxDateTime`
  strips a trailing `Z` and parses the field values with no conversion, and
  `_mailboxDateTime` writes them back under the mailbox's own zone. Sending
  local field values labelled `UTC` — which `_graphDateTime` does, correctly,
  for calendar times that really are UTC — is how a Sydney user's "away from
  the 20th" arrives mid-morning on the 20th.
- **Gmail stores epoch milliseconds, serialised as a JSON *string*.** A parser
  that assumed a number would read every schedule as absent. `0` is Gmail's
  "no bound", not 1 January 1970.
- **The end date is inclusive.** The screen picks whole dates; the last day
  ends at 23:59:59, which is what "away until Friday" means and what Gmail's
  own UI does. Midnight *starting* the end date switches the responder off a
  day early, and the user loses their last day.
- **A mailbox with nothing scheduled reports `0001-01-01`** on Graph — a null
  date wearing a costume, so anything before 1900 parses to null rather than
  drawing a year on the form.

### Both writes are read-modify-write, and that is not an optimisation to remove

`updateVacation` is a **PUT**: every field left out is a field *cleared*, so a
partial write wipes the reply subject and both restrict-to flags. Graph
**replaces** a complex property rather than merging into it, so a PATCH naming
only the status and the dates drops `externalAudience` — and a mailbox left on
`none` answers nobody outside the organisation, which reads as the feature
half-working rather than as a setting that was thrown away.

Gmail's `responseSubject` is the field that still depends on this — the screen
has no control for it, and a partial PUT would wipe it. The audience flags are
*not* in that category any more (see below): they are chosen here, so they are
written rather than merged.

The message is carried as **HTML**, which is what both providers store
natively, so a reply written in Outlook or the Gmail web UI round-trips with
its formatting. Gmail's `responseBodyPlainText` is rewritten alongside the HTML
on every save, or it goes on sending the previous message to anything that
cannot render HTML.

### One audience control over two different models

`OutOfOfficeAudience` is a three-way choice — `everyone`, `contacts`,
`organisationOnly` — mapped exactly onto each provider:

| | `everyone` | `contacts` | `organisationOnly` |
|---|---|---|---|
| Graph `externalAudience` | `all` | `contactsOnly` | `none` |
| Gmail `restrictToDomain` | false | false | **true** |
| Gmail `restrictToContacts` | false | **true** | false |

Four things here are load-bearing:

- **The wording differs by provider, because the two genuinely do.** Microsoft
  always answers everyone *inside* the organisation and `externalAudience`
  governs only outsiders; Gmail's `restrictToContacts` is the whole rule, so a
  colleague who is not a contact gets nothing. Hence "My organisation and my
  contacts" against "People in my contacts" — one wording for both would be
  wrong for one of them. `outOfOfficeAudienceLabel` is where that lives.
- **Both Gmail flags are written from the one choice, never merged with what
  is already there.** A mailbox set *both* ways (Workspace only, and only
  reachable from Gmail's own UI) answers people in the domain **and** in the
  contacts; it reads back as `organisationOnly`, which stays true of it, and
  saving then widens it to the whole domain. Preserving the other flag instead
  was tried and is worse: move the audience twice and you land somewhere you
  never chose, by a rule you cannot see. A labelled option has to mean exactly
  what it says once it is chosen.
- **A personal `@gmail.com` is not offered "organisation only".**
  `restrictToDomain` means nothing there, so the option would be a control that
  silently does nothing. It is still *listed* when the mailbox is already set
  that way — a `DropdownButton` whose current value is missing from its own
  items throws. `isConsumerGoogleAddress` (`core/utils/consumer_email_domain.dart`)
  is the one rule, shared with `GmailAuthService.scopesForAccount`, because two
  copies of that list is how the same account comes to be two different things.
- **Graph answers a mailbox that has never had an automatic reply with no
  audience at all**, which reads as `everyone` — the answer that reaches the
  people the user is trying to tell.

### Microsoft's second message is a flag plus retained text

Graph has `internalReplyMessage` and `externalReplyMessage`;
`useSeparateExternalMessage` says whether the screen is using both, and
`externalMessageHtml` holds the text either way. The save sends
`effectiveExternalMessageHtml` — the external text when the option is on, the
one message when it is off — so what is stored always matches what the screen
shows.

The flag and the text are deliberately *separate*, rather than "null means the
same message": with one field, unticking the option either destroys the
external text with no undo, or leaves it in place while the screen claims one
message is going to everybody. Neither is acceptable, and the pair also
removes the old read-only advisory — a mailbox holding two different texts
simply opens with the option already on.

Narrowing the audience to `organisationOnly` switches the option off, since
nobody external is answered; the *text* survives, so widening again brings it
back. The checkbox is disabled with the reason rather than hidden — a control
that vanishes reads as a bug.

Gmail has one body in two renderings (`responseBodyHtml` /
`responseBodyPlainText`), so none of this is offered there.

### Two things about the screen

- **It builds its own cubit from `sl`**, the way `AiSettingsPage` does, rather
  than relying on the host dialog's providers. `SettingsDialog.open`'s `wrap()`
  is not the only provider site: the mobile section route builds its own,
  narrower one (it does not even forward `UpdateCubit`), so anything added to
  `wrap()` alone is absent on mobile. It is a `registerFactory`, not a
  singleton — a reused cubit would show the previous mailbox's draft on the way
  back in.
- **The message editor gets a fixed, non-scrolling area** — the fields scroll
  above it, the same shape and the same 160px height as the signature editor in
  `_AccountsSection`. It embeds the same native platform view, whose screen
  position is only recalculated on layout and never on scroll deltas, so nested
  in a scroll view it visually detaches from the form.

**The two messages share one editor, swapped through `setContent`.** It is
keyed on the *account*, never on the tab: rebuilding a platform view per tab
press is both slow and a chance to lose the last keystrokes. Three things make
that safe:

- **The tab press flushes with `getContent()` first.** The editor debounces
  changes by 300 ms, so the last thing typed is still in the webview, and it
  belongs to the body being left.
- **Changes are dropped while a swap is in flight**, and the guard is a
  monotonic id rather than a bool — two fast tab presses interleave, and only
  the last may declare the editor settled. Same shape as `_searchRequestId` in
  `recipient_input_field.dart`. The window that needs guarding is exactly
  "tab flipped, `setContent` not yet landed": `setContent` does **not** clear
  the pending `changeTimer`, but `fireChange` reads `editor.innerHTML` when it
  *fires* rather than when it was scheduled, so a late event after the swap
  reports the new body and is harmless.
- **Save flushes the same way.** Without it, whatever was typed in the last
  300 ms before the press is not in the cubit — which on a short message is
  most of it.

The **plain-text** editor (compose format = plain) tracks what its controller
holds as an *(account, slot)* pair, not an account. The compose-format
preference is loaded asynchronously, so that field always mounts on a rebuild
rather than the first paint — and if the tab had moved by then, filling it from
the internal body would write that text into the external one on the first
keystroke. Only `build` fills that controller; `_selectSlot` leaves it to the
rebuild, or the caret jumps to the start on the second pass.

Anything that takes the second message away while the editor is *showing* it
has to put the editor back — the two user paths (the checkbox, and narrowing
the audience) swap first and then change the state, with a post-frame net
behind them for anything else, since it cannot be done during build.

**A shared Microsoft mailbox is attempted rather than refused.** Graph exposes
`/users/{address}/mailboxSettings` and `GraphApiDatasourceImpl._base` already
points there (`_microsoftAuthConfig` sets `mailboxAddress` from
`parentAccountId`), so the path is right for free — but there is no
`MailboxSettings.*.Shared` delegated permission to check for in advance, and
whether a tenant honours it is unverified. If it does not, the save fails with
Graph's own message rather than the feature being taken away from mailboxes
where it might work.

**The scope, though, belongs to the owner.** A shared mailbox holds no
credentials of its own — its token lives under the signed-in parent's key, the
same resolution `_microsoftAuthConfig` makes — so `hasOutOfOfficeWriteAccess`
and `requestOutOfOfficeWriteAccess` both go through `_credentialOwnerFor`
first. Asking the shared account directly reads *no token at all*, which
reports "permission needed" forever and then signs in as the shared mailbox,
landing a second token under a key nothing reads. `account_manager_test.dart`
pins it.

