# Chat — Teams chats and channels, Google Chat, and Slack

The Chat button (third in `ViewShortcutButtons`, right of Tasks) opens a
pane beside the reading pane (`HomeView.chat`, `ChatPanel`) — a one-on-one
with the selected email's sender, or anyone else on it the account can chat
with, from the dropdown. Double-clicking it
opens the chat window (`'chat'` sub-window, `ChatWindowApp`): every chat and
channel on the left, grouped (Chats; Teams › channels) and newest first; the
open one's history on the right, channel threads beside it; search on top.

A conversation with nothing new in a week (`ChatListState.quietAfter`,
`isQuiet`) waits under a "Show N older" row at the foot of its section —
quiet Teams channels are regrouped by team below that row. Unread ones, the
open one, and a channel whose activity is not known yet always show. A
deleted message is a single "Deleted message" line with no sender: the
providers send none, so it used to read "Unknown".

## More than one chat system: the Chat button's menu

The account's own chat (Teams, NightMail Server, Google Chat — "platform
chat") and any Slack workspace connected in Settings > General are the
**chat systems** (`ChatRepository.sources`, `ChatSource`): platform first,
when the account has one, then each workspace. Nothing changes until a
second system exists.

- **One system** — the account's own, or Slack alone for an IMAP or
  `@gmail.com` account — and the button toggles the pane as before.
- **Two or more** and a click opens a menu of them (`_ChatButton` in
  `view_shortcut_buttons.dart`), each with its own red dot and count, a tick
  on the one the pane shows, "Reconnect" on a refused workspace. The icon's
  dot is any system's unread; the tooltip names which ("Chat — 3 unread in
  Slack · Acme"). Picking one sets `ChatUnreadCubit.choose` and the pane
  follows `ChatUnreadState.chosen`. Picking the one already open closes the
  pane (the toggle); picking another while it is open switches it. Whether a
  pick switched is decided when it is made (`ChatUnreadCubit.takeSwitched`),
  not by remembering what the pane was opened on — that broke the plain
  toggle after an account switch and for a pane restored open at launch.
- **The double-click** still opens the chat window, which starts on the
  active account's platform chat; Slack workspaces are further entries in
  its picker (and where it starts when the account has no chat).

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
- **The pane's dropdown** offers, under the email's people, the chosen
  system's unread chats (`ChatUnreadState.unreadChats`), less any
  one-on-one with someone already listed. Picking one opens it in place
  until something else is picked; a new email (or another system) goes back
  to the email's people.

## Finding anyone from the pane

The pane's dropdown is a menu (`ChatPanePicker`) with a field on top: typing
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
- A person or chat picked here, like an unread chat, holds the pane until
  another email or system is selected (`_picked`, `_chat`). Enter takes the
  first match.
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
  message arriving while the user is away would turn read in Teams too.
  Microsoft wants `user {id, tenantId}` (tenant from `/organization`);
  Nightware takes the id alone. `ChatRepository.reads` clears the dot at
  once in the same isolate — the repository also counts a chat it marked as
  read until something newer arrives, since Microsoft's read state can trail
  the mark. A chat read in the chat window (its own isolate) or in Teams
  clears on the next poll. A mark that fails (offline) is not retried for
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

## Rendering

Bodies are HTML on both providers, rendered by `ChatMessageBody` as styled
text — no webview per message. `<script>`/`<style>` content is dropped, and
only `http(s)`/`mailto` links are tappable.

### Images

An emoji `<img>` keeps its `alt`. Any other `<img>` becomes a `ChatImage`
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
  can hold `//`, which Dio folds to `/` in a relative path.
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
- **Slack's failures never touch the email accounts.** A refused token
  (`invalid_auth`, `token_revoked`, `missing_scope`, a dead refresh token…)
  sets `SlackWorkspace.needsReconnect` and throws `SlackReconnectException`
  — a `ServerException`, deliberately not an `AuthException`, which means
  "re-auth this email account" everywhere else. The workspace then reports
  `ChatAccess.needsConsent`, so the pane and window show the consent prompt
  as "Reconnect Slack"; Settings and the menu show "Reconnect" too.
- **Scopes** (`SlackWorkspaces.userScopes`, mirrored in the manifest), one
  per method: `*:read` for `users.conversations`/`conversations.info`,
  `*:history`, `users:read`, `users:read.email` (`users.lookupByEmail`),
  `chat:write`, `im:write`/`mpim:write` (`conversations.open`, and
  `conversations.mark` on DMs), `channels:write`/`groups:write`
  (`conversations.mark` on channels), `files:read` (images), `search:read`.
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
  `_users` (session cache, 40 per call at most). The pane offers the
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
  50+ a minute. A DM's info carries `unread_count_display`; a group DM's
  and a channel's `last_read`, checked against the newest 5 messages —
  read without `oldest`, so a read channel's activity is learned too.
  People's, bots' (`bot_message`), file-share and broadcast messages
  count; joins, leaves and topic changes do not (`_unreadSubtypes`).
  Muted channels are bolded too: mute state is not in the Web API.
- **The dot leaves Slack channels out** (`ChatUnreadCubit._counts`), as
  Slack's badge does — a channel message is not waiting on the user. They
  are bolded in the window and offered in the pane's dropdown.
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
  `:a:`/`:b:` from eating text. Shortcodes are replaced *before* mrkdwn,
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
  `thumb_720`); anything else, including avatars, over https without it.
- **Search:** `search.messages` (Tier 2, user tokens), so
  `searchesOnServer` is true — no recent-history scan.
- A 429 waits out a `Retry-After` of up to 20 s once, then fails readably.
- A workspace connected in Settings reaches an already-open chat window
  (another isolate) when that window is next opened.
