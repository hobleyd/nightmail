# Chat — Teams chats and channels, Google Chat, and Slack

The Chat button (third in `ViewShortcutButtons`, right of Tasks) opens a
pane beside the reading pane (`HomeView.chat`, `ChatPanel`) — a one-on-one
with the selected email's sender, or anyone else on it the account can chat
with, from the dropdown. Double-clicking it
opens the chat window (`'chat'` sub-window, `ChatWindowApp`): every chat and
channel on the left, grouped (Chats; Teams › channels) and newest first; the
open one's history on the right, channel threads beside it; search on top.

A conversation with nothing new in a week (`ChatListState.quietAfter`,
`isQuiet`), or never anything at all (`ChatConversation.noMessages`: Graph
lists it with `lastMessagePreview: null`, Google without `lastActiveTime`,
Slack's history is empty; a NightMail Server sends Graph's explicit null
for a Talk room whose newest message is still `conversation_created`, from
Nightware 1.86), or nothing known yet (a channel or Slack conversation whose
lookup has not landed — Slack lists none with activity), waits under a "Show N older" row at the foot of its section —
quiet Teams channels are regrouped by team below that row. Unread ones and
the open one always show; a lookup that fails is asked again next poll. A
deleted message is a single "Deleted message" line with no sender: the
providers send none, so it used to read "Unknown".

## More than one chat system: the pane's header

The account's own chat (Teams, NightMail Server, Google Chat — "platform
chat") and any Slack workspace connected in Settings > General are the
**chat systems** (`ChatRepository.sources`, `ChatSource`): platform first,
when the account has one, then each workspace.

- **The Chat button is always the plain toggle** (click: pane; double-click:
  window). Its dot is any system's unread, and with more than one system the
  tooltip names which ("Chat — 3 unread in Slack · Acme"). It used to be a
  menu of the systems when there were two or more; that menu, and the
  `takeSwitched` bookkeeping it needed to tell "switch" from "close", went
  after 1.63.
- **The pane's header is the system** (`ChatSourcePicker`): its icon and
  name, and with more than one a dropdown of them, each with its own red dot
  and count, a tick on the one shown, "Reconnect" on a refused workspace. A
  red dot beside the arrow means another system has unread chats. Picking one
  sets `ChatUnreadCubit.choose` and the pane follows `ChatUnreadState.chosen`.
- **The double-click** still opens the chat window, which starts on the
  active account's platform chat; Slack workspaces are further entries in
  its picker (and where it starts when the account has no chat).
- **The pane's "Open chat window"** opens it on the pane's system and
  open conversation (`ChatWindowTarget`): in the creation arguments, or
  pushed to a window already open (`openTarget`, its
  `setWindowMethodHandler`). The window waits for the system to be in its
  picker — a Slack workspace only after its Keychain read — before the
  default choice, and opens the conversation as its cached list knows it
  (members included). A person with no chat yet opens just the system.

`ChatUnreadCubit` is now the button's whole model: the systems, unread per
system (`unreadCount` for each), and the choice. An account switch re-reads
the systems; a stale choice falls back to the first.

## Colleagues, and outsiders you already chat with

The dropdown lists the people on the email the account can chat with
(`ChatRepository.reachable`). First the colleagues (`colleagues`): an
address on one of the account's own domains (aliases included; never a
personal domain like `gmail.com`/`outlook.com`, the same rule as compose's
internal-reply signature), or one the daily address-book sync cached as
`ContactSource.directory` for that account — which covers a tenant with
several domains. Local only: SQL on the cache's primary key.

Then anyone else with an existing one-on-one (`findOneOnOne`, at most 8 per
email): an existing chat has already passed both tenants' external-access
rules. Nothing lets a user ask whether a *new* chat with an outsider would be
allowed — Teams federation and Google's external-chat settings are admin
policy, and the only test is creating the chat — so an outsider with no chat
is left out rather than offered to fail on send. On Graph the lookup scans the
cached chat list (refreshed at most every 2 minutes); on Google it is one
`findDirectMessage` per outsider.

Teams often lists a federated (external) member with no `email`, so
`findOneOnOne` falls back to the email's display name for a member without an
address — only when exactly one one-on-one matches, never guessing between
two people who share a name.

## Providers behind one interface

`ChatRemoteDatasource` is what the repository talks to:
`GraphChatDatasource` (Microsoft 365 and NightMail Server) and
`GoogleChatDatasource` (Google Workspace). `searchesOnServer` and
`findsOneOnOneDirectly` are the two places they differ in kind.

## One Graph client for Microsoft 365 and NightMail Server

`GraphChatDatasource` speaks Graph's `/me/chats`, `/chats/{id}/messages`,
`/me/joinedTeams`, `/teams/{t}/channels/{c}/messages[/{id}/replies]`. A
NightMail Server serves the same routes over Nextcloud Talk (nightware ADR
0009, phases 23–24), so nothing here branches on the provider except search.
It is built per call from the account's own Graph client
(`AccountManager.chatDatasourceForAccount`) — the credential owner's: a shared
mailbox has no chats, so its pane shows its parent's.

Load-bearing:

- **Ask only what both servers accept.** Nightware refuses `$filter` on chat
  listings and any `$orderby` but newest first; `$top` is at most 50. Finding
  a person's one-on-one is therefore a scan of the listed chats with
  `$expand=members`, never a filtered query (`ChatRepositoryImpl.findOneOnOne`,
  over a list cached for two minutes).
- **Members are bound on the account's own root**
  (`{graphBaseUrl}/users('…')`) — a literal Microsoft URL would leak a server
  account's request to Microsoft (`no_hardcoded_graph_urls_test`). Microsoft
  documents binding by directory id only, and `users('{address}')` resolves
  a UPN, which is not the mail address in every tenant; so on Microsoft the
  address is resolved first (`/me`, then `/users/{upn}`, `mail eq`, and
  `proxyAddresses` for an alias) and a miss is an external address. Nightware
  resolves an address itself (ADR 0009 D2), so it is bound by address.
- **`$expand=members,lastMessagePreview` may be refused.** Microsoft lists
  both as expandable but only ever shows them one at a time. A 400 on the
  combined request switches that root (for the session) to two listings
  merged by id.
- **A nextLink is followed only on the account's own scheme/host/port** — it
  is fetched with the bearer token.
- **Opening the pane never creates a chat.** On Nightware a new one-on-one is
  a Talk room the other person sees at once. The chat is created by the first
  message sent (`startOneOnOne`); until then the pane holds a `ChatPerson`.
- **Graph's 1:1 and group chats have no threads.** Only channel posts do
  (Talk threads on Nightware). Channel messages are listed with
  `$expand=replies`; the thread panel re-reads `/replies`.

## Consent (Microsoft 365 only)

`Chat.ReadWrite` (`MicrosoftAuthService.chatScope`) is incremental, asked
for the first time Chat opens. Channels (`channelScopes`: `Team.ReadBasic.All`,
`Channel.ReadBasic.All`, `ChannelMessage.Read.All`, `ChannelMessage.Send`) are a
*second* request from the window's "Show team channels", because
`ChannelMessage.Read.All` is admin-consent-required: a combined request would
fail with AADSTS65001 in any tenant whose administrator has not approved it,
and take chats down with it. Both are in `_refreshScopes` only when the token
already carries them (`chat_scope_test.dart`). A NightMail Server asks for
nothing: its token carries everything it published.

**Consent always runs in the main window.** The chat window is its own
isolate; a sign-in there would replace the Keychain token while the main
window's auth service kept refreshing from the old one — without the new
scopes — and the next refresh would drop them again. `requestChatAccess` in a
sub-window goes over `ChatConsentChannel` and waits for the main window's
answer (`home_page.dart` registers the listener).

## Cache on disk

Every list and conversation paints from disk first, then the server's answer
replaces it (`ChatLocalDatasource`, schema v22 `cached_chat_lists` /
`cached_chat_messages`). Keyed by chat id (an account id or `slack:{team}`),
one **encrypted** JSON blob per list and per conversation — the same
`CacheEncryptionService` as mail, so no message text is readable in the
file; a blob that will not decrypt is a miss. A conversation keeps its newest
`maxMessages` (100). Pagination cursors are never stored (Graph's skiptokens
expire): "load older" always continues from the fresh page.

- **Opening** (`ChatConversationCubit._load`): the cache paints, then the
  newest page is joined onto it — only where they meet (`joinCached`). A
  page that ends after the newest cached message (more arrived than a page
  holds) or that is the whole history stands alone; anything else would
  show a gap as if nothing were missing, or keep a deleted message. Offline,
  the cache stands with the error above it. The cache holds *rendered*
  bodies, so "load older" lets the server's copy of a message the cache
  supplied replace it (edits, reactions, a custom emoji the cached rendering
  predates) rather than deduplicating in the cache's favour.
- **The list** (`ChatListCubit.load`) paints `cachedConversations` while
  access and the listing are asked. Listings with no activity (channels,
  every Slack conversation) take it from the cache on disk, so the order
  survives a restart; the Slack activity fill still re-reads up to 40 per
  load, cache-known ones included — their activity may be days old. Writes
  of the list wait out a 2 s burst (`_saveList`) rather than encrypting it
  once per filled conversation.
- **The pane's one-on-one** (`findOneOnOne` on Graph and Google, which scan
  the list): a hit in the in-memory list, or the cached one after a restart,
  opens at once — a one-on-one's id never changes — and the listing
  refreshes behind it. Only a miss waits for the server.
- **Removal:** `AccountCubit.removeAccount` and Slack disconnect call
  `ChatRepository.forgetAccount`.

## No push; polling, with deltas where the provider has them

Graph change notifications need a webhook, which NightMail can't offer
(Nightware has them since ADR 0009 D11, for other clients). What NightMail
gets instead is the `chat` signal on a NightMail Server's change stream
(nightware ADR 0007 D5), which refreshes the unread dot — see below. The open
conversation is polled every 10 s
(`ChatConversationCubit.pollInterval`) — for what changed since a
**watermark**, the newest *server* timestamp seen (never the device clock,
whose skew would silently drop messages):

| Provider | `messagesSince` | Edits/reactions? |
|---|---|---|
| Microsoft 365 chats | `$orderby=lastModifiedDateTime desc` + `$filter=… gt X and … lt X+1d` (Graph filters only ordered by the same property, only as a range) | yes — `complete` |
| Teams channels, NightMail Server | none (nightware answers any `$filter` with 400) | — |
| Slack | `conversations.history?oldest=` | no |
| Google Chat (unthreaded) | `filter=createTime > "…"` | no |

A delta is merged by id — except a message older than anything shown:
Graph's delta reports a reaction to one weeks back, and inserting it would
sit an orphan under the history with a gap above it; "load older" reaches it
in its place. More than a page of changes (Slack `has_more`,
Google `nextPageToken`, Graph past four pages) is not trusted: null, and the
newest page is read instead. Where deltas only bring new messages, every
`fullPageEvery` (6th) poll reads the full page anyway, for edits, deletions,
reactions and reply counts. A server that refuses a delta with 400/405/501
is asked for pages from then on (`ChatRepository._noDelta`). Slack's limit
counts calls, not bytes, so its delta saves parsing, not quota — the speed
users feel is the cache. The window's list is re-read every 60 s; no
provider has a delta for listing chats. Channel listings carry no activity, so each
channel's newest post is read once per window load, four at a time, and the
list re-sorts as they land. Every async result is checked against a
generation counter — a reply for a conversation or account the user has moved
off is dropped.

## Unread dot, bold rows, and unread chats in the pane

Everything unread comes from one place, `ChatRepository.unreadConversations`
(the recent listing below, minus chats marked read here, titled and given
members from the full list — in memory or the cache on disk — since the
recent listing has none). Where neither knows the chat, an unread
one-on-one is named by its newest message's sender — in an unread
one-on-one always the other person (Graph: `lastMessagePreview.from`;
Google: the newest message the unread check already reads, remembered in
`_titles`). `unreadCount` is its length.

- **The chat window** bolds a row (and gives it a dot) only when the poll
  names it: `ChatListCubit` lays the poll's keys over every listing
  (`_withUnread`), because Slack's and Google's full listings carry no read
  state and Graph's ignores marks made a moment ago. Opening a row un-bolds
  it at once (`select`). The sort — most recent first or by name — is a menu
  beside search (`ChatListState.sortByName`), remembered in
  `AppSettings.chat_sort_by_name`.
- **The pane's unread list** is the top of the pane — 30% to start; drag
  the divider below it (`_SplitHandle`) to resize, kept as a fraction in
  `AppSettings.chat_pane_split`, clamped so a row of the list and room for
  the composer always show: the chosen
  system's unread chats and channels (`ChatUnreadState.unreadChats`), newest
  first, in the chat window's row (`ChatConversationRow`). Clicking one opens
  it in the rest of the pane and holds it there across emails (`_held`)
  until something else is picked or the system changes; it stays listed,
  highlighted, after it is read. Nothing unread: "No unread chats".
- **A field at the foot of the unread list** ("Find a chat or channel",
  just above the divider) swaps the list for every chat and channel whose
  name, team or members match (`matchChats`, shared with `ChatPanePicker`),
  newest first; picking one (click, or Enter for the first) opens and holds
  it like an unread pick and clears the field, and the list scrolls to its
  row (an older chat sorts below the rows in view); Escape clears. The first
  keystroke lists the system's conversations — the disk cache, then one
  `conversations()` per pane and system — never merely opening the pane.
- **Switching away and back keeps the pick.** Meetings, Tasks or email
  dispose the pane; its pick (`_chat`, `_picked`, `_held`, the email and
  system it was made on, the chosen person) is kept in a static
  `_lastOpen` on dispose and restored in `initState`, so it reopens on the
  same chat or channel. The usual rules still apply on return: another
  system lets it go, and a dropdown pick (not `_held`) lets go if another
  email was selected meanwhile.

## Finding anyone from the pane

The bar between the unread list and the conversation is a menu
(`ChatPanePicker`) of the email's people with a field on top: typing
matches the email's people, the address book and every listed chat and
channel. It is always there once the system has chat access, even for one
person or no email at all.

- **People** come from the contacts typeahead (`SearchContacts` — local
  SQL, never the network; see `lib/infrastructure/contacts/CLAUDE.md`), then
  through `reachable`, the same gate as the email's people: an outsider
  with no one-on-one is never offered. On Google each outsider is a
  `findDirectMessage`, so answers are remembered for as long as the menu
  is open, not asked per keystroke.
- **Chats and channels** are matched in Dart on title, team and members
  over `cachedConversations` (disk) and then one `conversations()` per
  menu — in the main window that is often the first listing this isolate
  has made, since the unread poll uses `listRecentChats`.
- A person or chat picked here holds the pane until another email or
  system is selected (`_picked`, `_chat`) — unlike a pick from the unread
  list, which outlasts the email. Enter takes the first match.
- `MenuAnchor` maps every arrow key to focus traversal; the field maps
  left/right back to cursor movement, or they would jump out of it
  (`chat_pane_picker_test.dart`). Up/down still move into the list.

The Chat button carries the Tasks button's red dot while any of the active
account's recent chats is unread (`ChatUnreadCubit`, main window only).

- **Rule** (`GraphChatDatasource.isUnread`): the newest message
  (`lastMessagePreview`) is someone else's, not a system event, in a chat
  that is not hidden, and later than `viewpoint.lastMessageReadDateTime` —
  equal is read. A null marker is unread: never read on Microsoft; on
  Nightware the marker is not on the newest message (phase 23 notes).
- **"Someone else"** needs the user's id: `/me`'s `id`, once per account
  (root plus own addresses — every Microsoft 365 account shares one root).
  Nightware names users by Keycloak id in `/me` and in `from.user.id` alike
  (ADR 0009 D2). Until it is known nothing is unread — no false dots.
- **A NightMail Server signals it**: `ChatUnreadCubit` also refreshes when
  the account's change stream names `chat` (including on `ready`), so a new
  message or a chat read elsewhere shows within ~10 s. The server's signal
  covers new messages, reads, renames and chats joined or left — not edits,
  deletions or reactions — and only reaches the main window (the stream is
  main-window only), so the chat window and the open conversation keep their
  timers.
- **The poll is light**: every 60 s, only for an account with chat access
  (never prompts consent), one page of `/me/chats` with
  `$expand=lastMessagePreview` alone (`listRecentChats`) — not
  `conversations(refresh:)`, which lists every team's channels and replaces
  the members-bearing cache `findOneOnOne` scans.
- **Marking read**: `ChatConversationCubit` marks a chat read
  (`markChatReadForUser`) when its newest message is someone else's — once
  per newest message, and only while the app is in the foreground, or a
  message arriving while the user is away would turn read in Teams too. One
  skipped while away is marked on resume (`AppLifecycleListener`) and on
  every poll, whatever it brought: the polls after it are usually empty
  deltas, and before 1.64.3 the chat — and the pane dropdown's dot — stayed
  lit until it was opened again. "Newest" includes a reply in the open
  thread when it is newer than every post, and a conversation opened from
  the unread list (`unread`) is marked once whatever its newest message is
  (`_openedUnread`): a Slack channel lit by a thread reply often has the
  user's own post, or one marked earlier, as its newest, and nothing was
  sent — it stayed lit while the thread was read.
  Microsoft wants `user {id, tenantId}` (tenant from `/organization`);
  Nightware takes the id alone. The mark is local first: `markRead` counts
  the chat read and announces it on `readKeys` before it asks the server, so
  the pane's unread list and the dot drop it at once (`ChatUnreadCubit`
  drops every `readKeys` key); `reads`, which re-polls every system, fires
  after the server answers. Until 2.0.0 everything waited for that answer,
  and a channel read in the pane sat in the unread list for the round trip
  — visible when the user moved straight on to the next one. The repository also counts a chat it marked as
  read until something newer arrives, since Microsoft's read state can trail
  the mark. A chat read in the chat window (its own isolate) clears at once
  too, and one read in the pane un-bolds in the window: `ChatReadRelay`
  passes each `markRead` (`readKeys`, `here`) to the other window — main to
  the open window through its method handler, the window to main over the
  `chat_read` channel — which takes it as `readElsewhere` (counted read until
  something newer, never passed back). This matters for Slack: a channel
  whose workspace lacks `channels:write` stays unread on Slack's side, so
  the other window's poll alone would bold it again. One read in Teams or
  Slack itself clears on the next poll. A mark that fails (offline) is not retried for
  that message; the next message from someone else marks it again.
- **No dot** for Teams channels: Graph has no per-user read state on
  channel messages.
- **Google** (`GoogleChatDatasource.listRecentChats`): `spaces.list` carries
  no read state, so each of the 20 most recently active spaces whose
  `lastActiveTime` moved since the last poll costs a
  `users/me/spaces/{s}/spaceReadState` and, when that is behind, its newest
  message (to tell the user's own from someone else's). A quiet poll is the
  one listing. Marking read PATCHes `lastReadTime` to now (`updateMask`);
  Google coerces it to the newest message's time. Thread replies keep their
  own read state, which this ignores. Needs `chat.users.readstate` — part of
  `chatScopes`, so a token from before it asks for consent again, once.

## Search

Microsoft 365: `POST /search/query` with `entityTypes: ['chatMessage']`,
`size` 25 (chats and channels; a hit carries a highlighted `summary` and no
body, and names its sender as `from.emailAddress`, not `from.user`).
NightMail Server and Google have no search route, so `ChatRepositoryImpl._scan` reads the
newest 100 messages of the 20 most recent conversations and matches text —
recent history only. A real fix is a search route in nightware (Talk's unified
search provider), not a bigger scan here.

Nightware's conformance fixtures for these routes are copied into
`test/fixtures/nightware_chat/` and replayed through the parser
(`graph_chat_fixture_replay_test.dart`); refresh them when nightware changes
one.

## Drafts

Text typed in a composer and not sent stays with the place it was typed
(`ChatDrafts`, `presentation/blocs/chat/chat_drafts.dart`): opening another
chat or channel empties the box, and coming back — or reopening the Chat
pane, or closing and reopening a thread — puts it back, with its `@` picks.

- **Keyed by where it was typed** (`ChatDrafts.keyOf`): account + conversation
  `key` (or `p:<email>` for a person not chatted with yet), plus `t:<postId>`
  for the thread composer. The two composers never share a draft.
- **A lazy singleton in `sl`, in memory only.** The pane's
  `ChatConversationCubit` is a factory that dies with the pane, so the store
  is handed to it (`cubit.drafts`). Each window is its own engine: the Chat
  window keeps its own drafts, and nothing survives a quit.
- **Saved on leaving, not per keystroke**: `_ComposerState._stash` runs when
  the key changes and in `dispose` (the narrow list composer is disposed
  while a thread is open). An edit in progress is not a draft — the text
  from before it (`_draft`) is what is kept.
- **A person's chat gaining its conversation is not a move**
  (`_moveDraft`'s `started`): the found or newly created chat keeps the box
  as it is, or the first send would wipe it mid-flight.
- **A send outlives the move.** Moving off mid-send stashes the text; when
  it lands, `_sendingFrom`'s draft is dropped and only a box still showing
  that place is emptied. So `ChatConversationCubit.send` returns true when
  the server took it even after the generation moved on — false there left
  a sent message as a draft, one Enter from going twice.
- **Coming back to an open edit**: a list edit stays open while a narrow
  pane shows a thread, so the rebuilt box takes the edit up again
  (`initState` → `_onEditing`) with the draft behind it.

## Editing your own messages

The pencil on your own message (on hover with a mouse, always on a touch
screen), or Up in an empty composer for your newest one, turns the composer
into the edit: "Editing message" banner, Save instead of Send, Esc or × to
leave it. Whatever was half-typed comes back afterwards
(`_ComposerState._draft`). A thread reply is edited in the thread's composer,
anything else in the conversation's (`ChatConversationState.editingInThread`).

- **What is offered:** `ChatConversationCubit.canEdit` — your own
  (`senderUserId == ownUserId`, so nothing until that is known), not deleted
  or a system note, the provider can here (`ChatRemoteDatasource.canEdit`),
  and the message has an `editableText`.
- **`ChatMessage.editableText`** is the body as you would type it, set by
  each parser from the raw message and kept in the cache (`editable`). It is
  **null whenever plain text cannot say the message again** — so a message
  whose save would silently strip something offers no edit at all:
  - Slack (`editableTextOf`): any `<@U…>`, `<#C…>`, `<!here>` or labelled
    link (sent text goes through `escapeText`, so they would come back as raw
    markup), a file, an attachment or a layout block. A bare link Slack
    linked itself is kept as typed; `&lt;`/`&gt;`/`&amp;` are undone.
  - Graph (`editableTextOf`): a mention, any attachment (file, quoted reply,
    card), or HTML beyond `<p>`/`<div>`/`<br>`, `<emoji alt>` and a link whose
    label is its own address — the wrapping Teams gives typed text. Saved as
    `contentType: text`.
  - Google (`editableTextOf`): any `annotations` (a read mention is plain
    `@Name` in `text` with a `USER_MENTION` annotation over it; Drive chips
    and custom emoji are annotations too), a card, or `<users/…>`/
    `<url|label>` markup. `*bold*` and the like are typed text there, and
    round-trip.
- **Calls:** Graph `PATCH` on the chat message, channel post or
  `…/messages/{replyToId}/replies/{id}` (204, no body — the edit is what was
  sent); Google `messages.patch?updateMask=text` (echoes the message; its
  rendering wins); Slack `chat.update` (`chat:write` covers your own).
  Every provider's result is merged onto the message shown
  (`ChatMessage.withEdit`) rather than re-parsed, so reactions and replies the
  response leaves out stay.
- **Two composers, one edit.** The pencil records which composer owns the
  edit (`startEdit(m, inThread:)` — a tile in the thread panel says so), and
  only that composer calls `saveEdit`; the other keeps calling `send`, which
  never looks at `editing`. Deciding by `state.editing` alone let a reply
  typed in the thread overwrite a post being edited in the list.
- **Microsoft 365 channels can't be edited.** Graph wants
  `ChannelMessage.ReadWrite` (admin consent) for a channel edit; NightMail
  asks for `ChannelMessage.Read.All` + `ChannelMessage.Send` only, so
  `GraphChatDatasource.canEdit` is false for an M365 channel and no pencil
  shows. Adding the scope to `channelScopes` would make every existing token
  fail `grantsChannels` and send every tenant back through admin consent — a
  separate decision. NightMail Server channels edit fine (nightware maps the
  PATCH routes onto Talk, which may refuse an old message; the refusal shows
  as "Could not edit the message: …" with the edit left open).
- An edit of the newest message updates the list's preview
  (`ChatRepositoryImpl._retouch`) without moving the conversation.

## Tagging people with `@`

Typing `@` at the start of a word in either composer opens a list above the
box of who the conversation can tag (`_MentionList`, `matchMentions`):
Up/Down move, Enter or Tab picks, Esc closes it, a click or tap picks. A
pick writes `@Name ` into the box and remembers the person (`_picked`); at
send, every pick still written as `@Name` goes as the provider's tag
(`splitMentions` in `domain/entities/chat_mentions.dart`), and one the user
deleted or retyped goes as the text it now is.

- **Keys go to the list first.** `_onKey` sits under `CallbackShortcuts`, so
  while the list is open it takes Enter (else it would send), Esc (else it
  would leave an edit or drop a pasted picture) and Up (else it would start
  an edit). The widget tests press Enter and check nothing was sent.
- **Only a word-starting `@`** (start, space or `(` before it), on one line,
  three words at most — `bob@example.com` never opens it. Never in an edit:
  a save is text only, and a message with a mention has no `editableText`
  anyway. Picks and the roster are dropped when the conversation, account
  or (thread composer) thread changes, as a pasted picture is.
- **Split, then escape.** Each provider escapes the text runs its own way
  and emits its own tag for the mention runs; replacing `@Name` in
  already-escaped text would miss a name with `&` or `<` in it.
- **Who is offered** (`ChatConversationCubit.mentionable`): the provider's
  roster (`ChatRemoteDatasource.mentionable`), asked once on the first `@`
  and kept per conversation, then anyone who has written in the loaded
  messages or thread whom it missed — never the user (`ownUserId`), and
  never an app or bot (`ChatMessage.senderIsApp`: Graph puts
  `from.application`'s id in `senderUserId`, and tagging it as `aadUser`
  is a 400). Each new `@` asks the cubit again, so someone who has just
  written is offered; only the network roster is cached.
  - Graph: `/chats/{id}/members` (`Chat.ReadWrite`). **A Microsoft 365
    channel has no roster** — it needs `ChannelMember.Read.All` (admin
    consent; adding it to `channelScopes` would send every tenant back
    through consent, as with edits) — so only people who wrote are offered.
    A NightMail Server lists `/teams/{t}/channels/{c}/members`.
  - Google: `spaces.members` (humans only). A membership may come without a
    `displayName` under user auth; those are named from People
    `people:batchGet` (`directory.readonly`, which photos already use), and
    anyone still nameless is left out.
  - Slack: `conversations.members`, named from `users.info` — or, with more
    than 40 unknown, one `users.list` sweep (Tier 2, once an hour per
    workspace) rather than a burst of `users.info`.
- **On the wire:**
  - Graph: only when a tag survives, the body becomes
    `contentType: html` — text escaped, newlines `<br>`, each tag
    `<at id="n">Name</at>` with a `mentions` entry (`aadUser`), every
    occurrence its own id (nightware refuses a repeat). Otherwise the
    message is the plain `text` body it always was. A pasted picture's
    caption carries them too. Nightware turns `<at>` into Talk's `@"uid"`.
  - Google: `<users/{id}>` in `text`; Google makes the annotation.
  - Slack: `<@U…>` in the escaped text, in a post or a picture's comment.

## Replying in a thread from a chat

- **Where:** `ChatConversationCubit.threads` — every `hasThreads`
  conversation as before, plus whatever `ChatRemoteDatasource.canThread`
  allows: on Slack a DM and a group DM, which thread exactly as channels do
  (`conversations.replies`, `thread_ts`, `reply_count`; `conversations.history`
  leaves replies out). The DM keeps its bubbles; `hasThreads` (post cards,
  Google's reply stitching, the null delta) is untouched — flipping it would
  have redrawn every DM as cards.
- **The link** is the channels' Reply / "N replies", always shown, under the
  bubble; never on a tile inside the thread panel. The message whose thread
  is open is highlighted. Opening a thread puts the caret in its own
  composer ("Reply"), narrow or beside the list. A reply sent from the thread bumps its parent's
  count at once (`withOneMoreReply`) and stays out of the DM's list.
- **Two composers, one target each.** `send(text, inThread:)`: only the
  thread's composer answers in the thread. Before this, the wide view's list
  composer also posted into whichever thread was open — a new channel post
  became a reply.
- **Not offered:** Teams and NightMail Server chats (Graph documents no
  threads in a chat and no way to send a quoted reply — `messageReference`
  is not a documented attachment type; nightware has no support either);
  Google DMs and group chats (`messageReplyOption` is "only supported in
  named spaces"; a threaded named space already has Reply). Google does let
  a message quote another (`quotedMessageMetadata`) — a possible quoted
  reply there, not built.

## Pasting a picture

Cmd+V (Ctrl+V on Windows and Linux) in a composer with a picture on the
clipboard puts a thumbnail above the box (× or Esc drops it); Send or Enter
sends it with whatever is typed, or alone. Anything else pastes as text, as
before.

- **Reading the clipboard is native:** `readImage` on the
  `au.com.sharpblue.nightmail/clipboard` channel (`clipboard_image.dart`),
  registered on every engine — the pane and the chat window both paste —
  by `MainFlutterWindow.swift`, `windows/runner/clipboard_image.cpp` (GDI+)
  and `linux/runner/clipboard_image.cc` (GTK). Not `super_clipboard`: an FFI
  plugin, banned outside the main window (`lib/core/platform/CLAUDE.md`).
  Mobile answers nothing and pastes text.
- **One rule on every desktop, in this order:** one copied image file (Finder,
  Explorer's `CF_HDROP`, a file manager's `text/uri-list`) pastes its
  contents, never its icon — any other file is a text paste; then
  **anything carrying text pastes as text**, even with a picture beside it
  (Word's copy of a paragraph carries a picture of it); then the picture —
  macOS `public.png`/`public.tiff`, Windows the registered `PNG` format
  (Chrome, Office, Snipping Tool) or `CF_DIB` (PrtScn, read as a `.bmp` so
  a screenshot's zero alpha is ignored), Linux any image target. PNG,
  JPEG and GIF files under the limit go as they are; anything else is
  PNG, or JPEG halved until it is under ~2.8 MB (Graph's 4 MB request
  limit, with the bytes as base64).
- **Linux reads asynchronously** (`gtk_clipboard_request_*`, answered when
  GTK has the data): the `wait_for_*` calls spin a nested main loop inside
  a platform-channel handler. When the clipboard is owned in-process GTK
  answers synchronously, before `clipboard_image_read` returns.
- **The paste is `PasteTextIntent`, overridden** around the `TextField`
  (`_ImagePasteAction`): `EditableText`'s paste is overridable, and the
  field's own action is only reachable as `callingAction` while `invoke`
  runs, so it is taken before the clipboard is awaited. The right-click
  menu's Paste calls the field directly and stays text-only.
- **Where it is offered** (`ChatConversationCubit.canSendImage`): an open
  conversation (a one-on-one not started yet begins with text), not while
  editing, and `ChatRemoteDatasource.canSendImage` — every provider but a
  NightMail Server, whose chat API (nightware) has no hosted contents.
  Elsewhere the paste falls through to text.
- **Teams:** one `POST` with `contentType: html`, the picture in
  `hostedContents` under temporary id 1 and referred to as
  `../hostedContents/1/$value` (`imageMessageBody`), drawn at most 360 px
  wide — Teams uses the `<img>`'s size, and a screenshot's pixels would fill
  the conversation. `Chat.ReadWrite`/`ChannelMessage.Send` cover it.
- **Google:** `media.upload` to `/upload/v1/{space}/attachments:upload`
  (multipart/related: `{filename}` then the bytes; a whole URL beside the
  client's `/v1` base, sent as bytes so a 401 retry can resend it), then
  `messages.create` with the returned `attachmentDataRef`. The
  `chat.messages` scope NightMail holds covers the upload.
- **Slack:** `files.getUploadURLExternal`, the bytes POSTed to its
  `upload_url` (no token — the URL is the credential), then
  `files.completeUploadExternal` with `channel_id`, `thread_ts` and the text
  as `initial_comment`. Slack posts the message itself afterwards and names
  no `ts`, so `_uploaded` looks for the file id in the newest history (or
  the thread) a few times (`uploadWaits`, ~5 s in all). Failing that, a
  stand-in is shown; the next full page read drops it for the real one.
  Needs `files:write` (added after 1.62.0): a workspace connected before is told to
  connect again rather than flagged, and a `missing_scope` from either
  method is not a reconnect (`_call`).
- **Your own picture shows at once.** The repository seeds the image cache
  with the pasted bytes under the `src` the sent message carries
  (`_seedImage`): Google and Slack process an upload after answering, and a
  miss would otherwise stay a miss until restart.

## Reacting to a message

- **Anyone's message**, not a deleted or system one
  (`ChatConversationCubit.canReact`). On desktop a smiley button sits beside
  the pencil's slot and shows on hover (`_Hover` wraps a tile that offers
  either); a touch screen has no hover, so a long press on the message opens
  the same menu. The menu is `quickReactions` (`core/text/emoji.dart`):
  Teams' six, then six more — no picker dependency. Tapping a reaction chip
  that is not the user's adds the user's; the user's own chips are outlined.
- **Taking one off:** tapping the user's own (outlined) chip removes it
  (`ChatConversationCubit.unreact`) — Graph `POST …/unsetReaction`, Slack
  `reactions.remove` (`no_reaction`: already gone), Google `reactions.list`
  filtered `emoji.unicode = "…" AND user.name = "users/…"` then `DELETE` of
  each one found (Google deletes by the reaction's name only). Google's
  summaries name no one, so a Google chip is known to be the user's only
  once they added it here, or the server answered a repeat as already there
  (`withReactor`) — then the next tap takes it off.
- **Calls and scopes:** Graph `POST …/setReaction` `{reactionType: "🎉"}` on
  the chat message, post or reply (`Chat.ReadWrite`; a Microsoft 365
  *channel* needs only `ChannelMessage.Send`, which NightMail already holds,
  so unlike an edit it works there; nightware serves the same routes and
  takes unicode). Google `POST {message}/reactions`
  `{emoji: {unicode}}` under `chat.messages`. Slack `reactions.add` by name
  (`emojiShortcode`, presentation selector ignored, so ❤ and ❤️ are both
  `heart`; a custom emoji's `:name:` as is) under `reactions:write`.
- **Never counted twice.** `ChatReaction.userIds` keeps who reacted where
  the listing says (Graph `user.user.id`, Slack `users`; Google's summaries
  name no one). The cubit skips a reaction the user already gave, and
  `react` reports whether the server added one: Graph keeps a repeat as one
  (204 either way; nightware's Talk accepts it too), Slack answers
  `already_reacted`, and Google is *assumed* to answer 409 — undocumented,
  unverified; a 200 would show one too many until the next page read. The
  last two come back false and nothing is counted. The count goes up only after
  the server has it, and not if a poll brought it in meanwhile.
- **Slack's `reactions:write` was added later.** A workspace connected
  before lacks it: `react` checks `SlackWorkspace.scopes` first and says
  "Connect this Slack workspace again in Settings to add reactions."
  rather than flagging the workspace, and a `missing_scope` from
  `reactions.add` is not a reconnect (`_call`). The Slack app must have the
  scope too: `tool/setup_slack_app.sh --update <app id>`.

## Renaming a chat or channel

The pencil beside the open conversation's title (the chat window's header,
the pane's) opens a name dialog; Save renames it on the server, and the
header, the list row and the cached list (`ChatRepositoryImpl
.renameConversation`, in place — no reorder) follow at once. What is
offered is `ChatRemoteDatasource.canRename`:

- **Teams and NightMail Server group chats:** `PATCH /chats/{id}`
  `{topic}` (`Chat.ReadWrite`). Microsoft answers 204, nightware the chat;
  the title is what was sent either way. Never a one-on-one, and not a
  meeting chat (its topic is the meeting's). An empty topic is not sent —
  nightware refuses one.
- **NightMail Server channels:** `PATCH /teams/{t}/channels/{c}`
  `{displayName}` (nightware `UpdateChannel`). A Microsoft 365 channel
  needs `ChannelSettings.ReadWrite.All`, admin consent — not offered, for
  the same reason as channel edits.
- **Slack channels** (public and private; Slack names no DM or group DM):
  `conversations.rename` under `channels:write`/`groups:write`. The name is
  sent as Slack takes it (`slackChannelName`: no `#`, lowercase, whitespace
  as hyphens) and the title comes back as `#name` from Slack's answer. A
  workspace connected before 1.58.1 lacks those scopes: the rename is not
  sent and says to connect again, and a `missing_scope` from the call is
  *not* a reconnect (`_call`). Many workspaces let only channel managers
  rename — `not_authorized`, worded.
- **Google Chat: not offered.** `spaces.patch` wants `chat.spaces`, which
  `chatScopes` leaves out on purpose (`chat.spaces.create` has no
  rename/delete power). Adding it would make every existing token fail
  `grantsChat` and re-consent every Workspace user, and consent cannot run
  from the chat window — a product decision, not done here.

A refusal shows under the field with the dialog left open.

## Rendering

Bodies are HTML on both providers, rendered by `ChatMessageBody` as styled
text — no webview per message. `<script>`/`<style>` content is dropped, and
only `http(s)`/`mailto` links are tappable.

### Images

An emoji `<img>` keeps its `alt` — Teams' `itemtype` says so, or an alt of
at most three characters with no letter or digit (a GIF's alt can be "GIF" or
"lol", and was drawn as that text). Any other `<img>` becomes a `ChatImage`
(a `WidgetSpan`, tap to open full size) whose bytes come through
`ChatRepository.image` → the datasource's `image(src)`; the renderer never
fetches anything itself, and without a loader an image reads "[image]".

- **Teams** keeps a pasted picture as hosted content and links it from the
  body on the account's own Graph root
  (`…/messages/{id}/hostedContents/{id}/$value`): fetched with the account's
  token (`Chat.ReadWrite`/`ChannelMessage.Read.All` cover it). Same
  scheme/host/port rule as nextLinks — the token goes nowhere else.
- **Elsewhere** (a Teams GIF or sticker on a public CDN): `https` only,
  through `publicImageClient` — no base URL, no interceptors, so never the
  token. Unlike mail, remote chat images load without asking: a chat already
  tells its sender you read it, so a tracking pixel learns nothing new.
- **Google** has no images in `text`; an uploaded picture is an `attachment`
  with `attachmentDataRef.resourceName`. `GoogleChatDatasource` writes it into
  the body as `<img src="gchat-media:{resourceName}">` (an opaque ref, like a
  nextLink cursor) and `image` downloads it from `media/{resourceName}
  ?alt=media` with the token. A Drive attachment stays a named attachment.
  The URL is built whole (`baseUrl/media/…`): a resource name is base64 and
  can hold `//`, which Dio folds to `/` in a relative path. A GIF from Chat's
  own GIF search is `attachedGifs[].uri`, public https, fetched without it.
- `fetchImageBytes` (`chat_images.dart`) asks with `Accept: image/*` (not
  the API client's JSON) and returns null for anything that is neither an
  `image/*` answer nor bytes that start like a picture (`looksLikeImage`:
  media download can serve a screenshot as a binary blob), or over 15 MB — chat images are decoration, never an
  error. Each miss logs `[ChatImage] host status "type"` to
  `diagnostics.log`. The repository remembers results (misses too) per
  `account|src`, 300 deep, so polling never re-fetches — a fix only shows
  after a restart.

### Who is talking

Each run of one sender's messages starts with a `ChatAvatar` and their name
in their colour; their messages sit in a pastel bubble of the same hue (a
channel post's card takes it too). Colours come from `ChatPersonStyle.hues`,
ten hues ordered for contrast. The first (blue) is always the user's own, in
every conversation (`ChatConversationState.ownUserId`: `/me` on Graph, the
user's `members/{email}` on Google); the other nine are dealt out per
conversation by `ChatPeopleColors` in an order fixed by each person's hash —
so the same people always get the same colours, nobody else is ever blue,
and a one-on-one is always blue (you) and orange. Hashing each person straight to a hue was tried: two of four people
landed in one colour, or 30° apart, which is the same colour in pastel.

Avatars are initials on the person's colour until `photo(userId)` answers:
Microsoft `/users/{id}/photos/64x64/$value` (`User.Read.All`, already
granted), a NightMail Server `/users/{id}/photo/$value`, Google
`people/{id}?personFields=photos` (a Chat user id is their People id;
`directory.readonly`) then the photo from `*.googleusercontent.com` with no
token — Google's generated letter avatar (`default: true`) is skipped. An
outside person has no photo in your directory and keeps their initials.

### Calling someone from their avatar

The avatar heading a run of messages (`ChatCallableAvatar`, not the mention
picker's, which sits inside its own tap target) opens a call menu, built from
`ChatRemoteDatasource.calling` (`ChatCalling`). NightMail never carries a
call: `callLink` returns a link, and `launchMeetingJoinUrl` hands it to the
system's app (Teams as `msteams:` on macOS/Windows) or browser. There is no
menu for the user's own avatar (`ownUserId`), an app, a system or deleted
message, or a sender with no id.

- **Microsoft 365: voice or video**, through Teams' documented deep link
  `teams.microsoft.com/l/call/0/0?users={upn}[&withVideo=true]`. Graph's
  `POST /communications/calls` needs an application permission (a bot), so
  it is not used. Teams asks the user to confirm before it rings.
  - `users=` is the UPN from `/users/{id}?$select=userPrincipalName,mail`,
    not the mail address. For someone outside the tenant (404/403), the
    address the conversation lists them with is used instead.
  - The UPN is lower-cased (calls to a capitalised UPN are reported to
    fail) and percent-encoded (a guest's `#EXT#` would otherwise cut the
    link short at the `#`).
  - It is cached per identity and id.
- **NightMail Server: voice or video**, through `POST /communications/calls`
  (nightware ADR 0009 D7, delegated there) with `requestedModalities`.
  - **Talk rings the person before the link comes back**, so the request
    is sent only when a menu item is chosen, never when the menu opens.
  - The user joins through `@nightware.joinWebUrl` (`{Talk}/call/{token}`).
    Nothing is owed afterwards: Talk ends a call nobody joined (phase 26).
  - A 501 (calls not configured) or a 404/405 (a server from before phase
    26) reads "Calls are not turned on for this NightMail Server".
  - A server account never gets a Teams link.
- **Slack: one "Start a huddle" item.** `callLink` returns
  `app.slack.com/huddle/{team}/{channel}` for the DM with the person. Video
  is turned on inside the huddle.
  - **On the desktop it opens in the Slack app only.** The https link went
    to the browser, whose page then handed off to Slack, so both opened.
    `launchMeetingJoinUrl` now turns it into
    `slack://join-huddle?team=…&id=…` (`slackAppHuddleUrl`), checks
    `canLaunch`, and falls back to the https link when Slack isn't
    installed. The same applies on macOS, Windows and Linux.
  - **Neither form is documented by Slack.** `join-huddle` comes from the
    `slack://` command switch in Slack's web client: `cmd`, `team`, `id`.
    It was read from the JS the Slack 4.53 desktop app caches under
    `~/Library/Application Support/Slack/Service Worker/CacheStorage`. It
    switches to the channel and then starts or joins its huddle
    (`entryPoint: "deeplink"`). `slack://huddle` only joins a huddle that
    is already running and throws otherwise.
    - The desktop shell itself only forwards `slack://` links to that
      client. Its `open-url` handler ignores https, so handing the https
      link to Slack.app does nothing.
    - If huddles stop opening, grep a fresh cache for
      `case"join-huddle"`.
    - Not exercised live: it would ring a colleague.
  - The DM is the open one-on-one, else one already listed (`_ims`), else
    one made with `conversations.open`. Making one is fine here because the
    user asked to call this person, unlike `findOneOnOne`, which never
    makes a DM. An empty DM shows the other person nothing.
- **Google Chat: "Start a Google Meet and send {name} the link".** No link
  starts a Chat call, so NightMail does what Chat's own call button does.
  It makes a meeting with the Meet REST API (`POST
  meet.googleapis.com/v2/spaces`, empty body), posts "Join me on Google
  Meet: {meetingUri}" into the DM, and opens the meeting. Meet has no
  voice-only meeting, so there is one item.
  - **Order matters.** The meeting is made first, so nothing is sent for one
    that failed. A link that cannot be posted fails the call, rather than
    opening a meeting nobody was told about.
  - The DM is the open one-on-one, else `findDirectMessage(users/{id})`,
    else `spaces:setup`.
  - The posted link goes straight through the datasource, not the
    repository, so the open DM shows it at the next poll.
  - **Consent.** `meetings.space.created` (`GmailAuthService.meetScope`,
    sensitive) creates meetings and reads only the ones NightMail made.
    - It is asked for on the first call, after a dialog saying the browser
      will open (`ChatCallableAvatar`). `ChatRepository.callNeedsConsent` /
      `requestCallConsent` route this to `AccountManager.callNeedsConsent` /
      `requestCallAccess`.
    - From the chat window it goes through `ChatConsentChannel.requestCalls`
      to the main window, for the same token-replacement reason as chat
      consent.
    - It is **not** one of `chatScopes`: `grantsChat` wants all of those,
      so adding it there would send every chatting account back through
      consent.
    - The cubit checks `_generation` across the consent wait. A user who has
      moved to another chat by the time they approve gets no meeting and
      sends no link.
  - **Setup.** The Cloud project needs `meet.googleapis.com` enabled
    (`tool/setup_google_chat.sh`), and the scope listed under Data Access.
    A 403 "has not been used / is disabled" reads "Google Meet is not set
    up for NightMail yet"; any other 403 reads "not allowed".
  - `config.accessType` is left to the user's admin default. On the usual
    Workspace default (TRUSTED), someone outside the organisation knocks
    to get in.

## Google Chat (Workspace accounts)

`GoogleChatDatasource` speaks `chat.googleapis.com/v1` as the user.
`@gmail.com` accounts get nothing: the Chat API does not serve them, and
`AccountManager.chatGrants` answers null for them (`isConsumerGoogleAddress`).

- **Setup:** the Cloud project owning the OAuth client needs the Chat API
  enabled *and* a Chat app configured, or every call fails "Google Chat app
  not found" (mapped to a readable message). `tool/setup_google_chat.sh` does
  the first and opens the page for the second, which has no API.
- **Consent:** `GmailAuthService.chatScopes` — `chat.spaces.readonly`,
  `chat.spaces.create` (a DM, without rename/delete power over spaces),
  `chat.messages`, `chat.memberships.readonly`, `chat.users.readstate`
  (the unread dot and marking read) — one incremental request, no
  separate channel step: spaces come with it. Google echoes granted scopes on
  refresh, so nothing is added to a refresh request.
- **Mapping:** `DIRECT_MESSAGE` → one-on-one, `GROUP_CHAT` → group, `SPACE` →
  `ChatKind.space` (the window's Spaces section), `threaded` when its
  `spaceThreadingState` is `THREADED_MESSAGES` or `GROUPED_MESSAGES`. A
  threaded space's page lists posts and replies together; replies on the page
  are attached to their post by `thread.name`, and a thread is re-read with
  `filter=thread.name = "…"`. Replies are sent with the thread's name and
  `REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD`. `ChatMessage.threadId` carries the
  thread, since Google names threads apart from messages.
- **Finding and starting a DM** is direct: `spaces:findDirectMessage` with
  `users/{email}` (404 = none yet), and `spaces:setup`, which returns the
  existing DM rather than a second one.
- **Titles:** a DM or unnamed group chat has no `displayName`; it is titled
  from `members` less the user (found once as `members/{ownEmail}`), for the
  60 most recent per listing, cached by space.
- **Bodies** are Chat's plain `text`, turned into the renderer's HTML by
  `chatTextToHtml` (escaped first; `*bold*`, `_italic_`, `~strike~`,
  `` `code` ``, bare links).
- **Search:** Google has none a user can call (`spaces.search` is admin-only),
  so it is the same recent-history scan as Nightware.

## Slack

`SlackChatDatasource` speaks Slack's Web API as the user (a user token, never
a bot) of one workspace. A workspace is a chat system of its own, not tied to
any email account, so every `ChatRepository` call that takes an `accountId`
also takes `slack:{teamId}` (`ChatSource.isSlackId`); `ChatRepositoryImpl._ds`
routes it. Each `_accounts.*` path in the repository branches on it
explicitly — access, consent, own address, colleagues, reachable — rather
than falling into an account lookup that answers null.

- **One internal app per workspace.** Slack cuts `conversations.history` and
  `conversations.replies` to one call a minute (15 messages) for a
  distributed app outside the Marketplace; an internal app — installed only
  in the workspace that created it — keeps Tier 3 (50+ a minute). So
  `tool/setup_slack_app.sh` creates the app in the user's workspace from
  `tool/slack_app_manifest.json`, and the Client ID is **stored with the
  workspace** (`SlackWorkspace.clientId`): a refresh must name the app that
  issued the token, and two workspaces are two apps. `SLACK_CLIENT_ID` is
  only the Settings dialog's default. Shipping one distributed or
  Marketplace app instead would be a product decision, and the history
  limits are what it would cost.
- **Sign-in is OAuth v2 with PKCE** (`SlackWorkspaces.connect`): a public
  client, no secret in the app, `user_scope` only (Slack refuses bot scopes
  on a desktop redirect). Desktop uses `LoopbackAuthFlow` on
  `http://localhost:34573/slack` (its own port, so it never takes Gmail's
  34572 over; `localhost` because that is what Slack's PKCE guide treats as a
  desktop redirect — the server binds IPv4, which browsers fall back to);
  iOS/Android use `nightmail://slack-callback` through `flutter_web_auth_2`.
  Both are in the manifest. The `state` check is the same as the other
  providers'.
- **Tokens live in the Keychain, read on every call** (`slack_workspaces`
  key). The main window and the chat window are separate isolates and both
  call Slack. A non-rotating `xoxp-` token (desktop, rotation off in the
  manifest) never expires. A rotating one (always, for the custom scheme) is
  refreshed five minutes before expiry; its refresh token is single-use, so
  a refusal first re-reads the Keychain — if the other window already
  refreshed, its pair is used; only otherwise is the workspace flagged.
  PKCE refresh tokens also expire after 30 days unused.
- **A locked Mac's Keychain refuses reads** (-25308, "User interaction is
  not allowed" — the overnight `[Slack] workspaces unreadable` lines).
  `all()` then answers none, but every write of the list (`_put`, `remove`)
  reads through `_read()`, which throws: a write built on that empty list
  would keep only the workspace being written. A refresh that cannot be
  stored still returns its new token for the call in hand.
- **Slack's failures never touch the email accounts.** A refused token
  (`invalid_auth`, `token_revoked`, `missing_scope`, a dead refresh token…)
  sets `SlackWorkspace.needsReconnect` and throws `SlackReconnectException`
  — a `ServerException`, deliberately not an `AuthException`, which means
  "re-auth this email account" everywhere else. The workspace then reports
  `ChatAccess.needsConsent`, so the pane and window show the consent prompt
  as "Reconnect Slack"; Settings and the pane's system dropdown show "Reconnect" too.
- **Scopes** (`SlackWorkspaces.userScopes`, mirrored in the manifest), one
  per method: `*:read` for `users.conversations`/`conversations.info`,
  `*:history`, `users:read`, `users:read.email` (`users.lookupByEmail`),
  `chat:write`, `im:write`/`mpim:write` (`conversations.open`, and
  `conversations.mark` on DMs), `channels:write`/`groups:write`
  (`conversations.mark` on channels, `conversations.rename`), `files:read`
  (images), `search:read`, `reactions:write` (`reactions.add`),
  `files:write` (pasted pictures).
  A scope added later surfaces as `missing_scope` → reconnect, which grants
  it — except where noted below.
- **Mapping:** `im` → one-on-one (titled by the other person), `mpim` →
  group (titled from its `mpdm-a--b-1` name less the user's handle), public
  and private channels → `ChatKind.space`, threaded, titled `#name`, under
  "Channels" in the window. `conversations.history` leaves thread replies
  out, so a post carries `reply_count` and the thread panel reads
  `conversations.replies`. A message's id is its `ts`; a reply's
  `replyToId` its `thread_ts`.
- **No listing carries activity**, so `channelActivity` (one
  `conversations.history` of 1) fills it in for every Slack conversation;
  the window asks once per load, four at a time, DMs and group DMs first and
  at most 40 (`ChatListCubit._slackActivityPerLoad` — a user in 150
  channels would otherwise spend minutes of Tier 3 before the open
  conversation could poll), and the repository keeps what it learned across
  refreshes. Teams channels are filled as before.
- **People:** a message names its sender by id; `users.info` (Tier 4) fills
  `_users` (session cache, 40 per call at most). Each window is its own
  isolate and starts knowing nobody, so a listing names only 40 DMs: the
  rest come back `untitled` ("Direct message"), and
  `ChatRepositoryImpl.conversations` keeps the name this session's list or
  the cache on disk already had (Google's unnamed DMs too); the provider's
  name wins once it has one. The pane offers the
  people on an email that `users.lookupByEmail` finds in the workspace
  (`directoryMembers`, 12 per email, misses remembered) — the mail
  account's domains mean nothing to Slack. `findOneOnOne` looks the DM up in
  the listed IMs and never calls `conversations.open`, which would create
  one; that waits for the first message (`createOneOnOne`).
- **Unread** covers DMs, group DMs *and channels* — Slack's sidebar bolds
  an unread channel, and a user reading both expects the same here. Unlike
  Teams, Slack keeps a per-user `last_read` on channels, so nothing stops
  it. One `users.conversations` of every type, then `conversations.info`
  for 15 DMs and 8 channels per poll (`_pick`): half the slots for the
  newest known activity, half going round the rest in Slack's listing
  order — stable between polls, so every channel is reached within
  `channels / 4` minutes (re-sorting the pool each poll skipped some). The
  main window and the chat window each poll, so that is ~46 of Tier 3's
  50+ a minute. A DM's info carries `unread_count_display`; at 0 it is
  read, with no history call. Above 0 it is checked like a group DM's and a
  channel's `last_read`, against the newest 5 messages — an AI app's DM
  (Atlassian Rovo) holds only an `assistant_app_thread` parent, read in
  Slack's side panel, which need not move the DM's marker, so its count
  can stay above 0 and it kept coming back unread. Those newest 5 are
  read without `oldest`, so a read channel's activity is learned too.
  People's, bots' (`bot_message`), file-share and broadcast messages
  count; joins, leaves and topic changes do not (`_unreadSubtypes`).
  Muted channels are bolded too: mute state is not in the Web API.
- **A reply in a thread lights its channel** (before 1.64.1+297 it never
  did — `conversations.history` leaves replies out, so nothing passed
  `last_read`). The poll reads the newest 15 posts (`_postsChecked`, same
  one request); a post whose `latest_reply` is past the channel's
  `last_read` is a candidate, and up to 2 per poll (`_threadsChecked`)
  are read with `conversations.replies` (`oldest` = the channel's
  `last_read`). Unread when a reply from someone else, of a counted
  subtype, is past the channel's `last_read` *and* the thread's own
  `last_read` — Slack keeps them apart, and a thread read in its side
  panel moves only its own (given to threads the user follows). Skipped
  with no call when `reply_users` is only the user. The reply is the
  conversation's activity (`_replyLatest`, kept apart from `_latest`,
  which other reads overwrite with the newest post), so a reply after a
  mark here passes `ChatRepositoryImpl._markedAt`. `markRead` marks the
  channel at the newest reply when that is newer than the newest post,
  falling back to the post if Slack refuses it — or the reply would light
  it again next poll. The pane marks such a channel even when its newest post
  is the user's own (see "Marking read"). Limits: a reply to a post older than the newest 15
  goes unseen; a thread the user never followed, read only in Slack,
  stays lit until the channel is opened here; a DM Slack counts read
  (`unread_count_display` 0) is not checked for replies.
- **A poll's answer is remembered** (`_wasUnread`, per isolate): a
  conversation not asked about this poll keeps its last answer, or an
  unread channel blinked out whenever the rotation passed it by — the
  dropdown said 2 while Slack said 5. Those last found unread take the
  "newest" half of the slots first, so one read in Slack clears within a
  poll; the rotating half is never given up to them.
- **Slack channels light the dot**, as they dot Slack's own dock icon (1.58.1
  left them out; the user expected the dot when the dropdown offered them).
  Muted channels count too — mute state is not in the Web API.
- **Marking a channel read** needs `channels:write` and `groups:write`
  (added 1.58.1). A workspace connected before lacks them: `markRead` skips
  the call when `SlackWorkspace.scopes` does not hold both, and a
  `missing_scope` from `conversations.mark` is *not* a reconnect (`_call`),
  like `emoji.list`. The repository still counts the channel read in that
  isolate until something newer arrives; it just stays unread in Slack
  until the user reconnects (Settings shows "Reconnect", via
  `missingScopes`).
- **Bodies** are mrkdwn (`mrkdwnToHtml`): Slack sends `&`, `<`, `>` escaped,
  so the only raw `<…>` are its controls — `<@U…>` (named from `_users`),
  `<#C…|name>`, `<!here>`, `<url|label>` (http(s)/mailto only).
  `:shortcodes:` become emoji from the full standard table
  (`lib/core/text/emoji_shortcodes.dart`, generated from iamcal/emoji-data —
  Slack's own names — by `tool/generate_emoji_shortcodes.py`; never edit by
  hand), skin tones joined (`:wave::skin-tone-3:`, a reaction's
  `thumbsup::skin-tone-2`). Not inside code, and not glued to a word or
  digit (`a:b:c`, `10:30:00`), which is what keeps one-letter names like
  `:a:`/`:b:` from eating text. One exception, because Slack shows it as
  the emoji and people type it: a name of 2+ characters straight after a
  letter (`devbox:laughing:`). Shortcodes are replaced *before* mrkdwn,
  while code still has its backticks; link targets never pass through it.
  Outgoing text escapes `&<>` and is otherwise mrkdwn as typed.
- **Custom emoji** (the workspace's own): `emoji.list` (`emoji:read`, Tier
  2), once an hour per workspace per isolate, aliases followed — to another
  picture, or to a standard emoji's characters (`resolveCustomEmoji`). In a
  body one becomes `<img data-emoji src alt=":name:">`, which
  `ChatMessageBody` draws as a `ChatEmojiImage` at 1.35× the text, not as a
  tappable picture; a reaction carries it as `ChatReaction.imageUrl`. The
  `<img>` waits behind a private-use placeholder while `_format` runs, or
  `_italics_` would eat the underscores in its URL. `emoji.slack-edge.com`
  is public https, so the images go without the token.
- **A scope added later** (`emoji:read`): a token without it answers
  `emoji.list` with `missing_scope`, which — for that method only — is
  *not* a reconnect (`_call`): chat keeps working, names stay `:name:`.
  Each workspace records the scopes it was granted (`authed_user.scope`,
  `SlackWorkspace.scopes`); one missing any of `userScopes` shows
  "Reconnect" in Settings (`ChatSource.missingScopes`). The Slack *app*
  must have the scope first, or Slack's sign-in page refuses the request:
  `tool/setup_slack_app.sh --update <app id>` brings an app made earlier up
  to the manifest. Adding a scope again means all three: manifest,
  `userScopes`, and this.
- **Images:** files on `files.slack.com` are fetched with the token (their
  `thumb_720`; a GIF's `thumb_480_gif`, since its `thumb_720` is a still
  frame); anything else, including avatars, over https without it. A
  `/giphy` post is an `image` block (`image_url` on giphy's CDN, sized by
  `image_width`/`image_height`) plus a context block whose logo icon is left
  out; a pasted GIF link unfurls as an attachment's `image_url`. Both used
  to be dropped, leaving only the fallback text.
- **Search:** `search.messages` (Tier 2, user tokens), so
  `searchesOnServer` is true — no recent-history scan.
- A 429 waits out a `Retry-After` of up to 20 s once, then fails readably.
- A workspace connected in Settings reaches an already-open chat window
  (another isolate) when that window is next opened.
