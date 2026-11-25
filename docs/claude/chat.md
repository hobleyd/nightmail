# Chat — Teams chats and channels, Google Chat, and Slack

The Chat button (third in `ViewShortcutButtons`, right of Tasks) opens a
pane beside the reading pane (`HomeView.chat`, `ChatPanel`) — a one-on-one
with the selected email's sender, or anyone else on it the account can chat
with, from the dropdown. Double-clicking it
opens the chat window (`'chat'` sub-window, `ChatWindowApp`): every chat and
channel on the left, grouped (Chats; Teams › channels) and newest first; the
open one's history on the right, channel threads beside it; search on top.

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

## No push; polling

Graph change notifications need a webhook and Nightware leaves chat
notifications out (ADR 0009 D1). The open conversation is re-read every 10 s
(`ChatConversationCubit.pollInterval`) and merged over what is shown; the
window's list every 60 s. Channel listings carry no activity, so each
channel's newest post is read once per window load, four at a time, and the
list re-sorts as they land. Every async result is checked against a
generation counter — a reply for a conversation or account the user has moved
off is dropped.

## Unread dot

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
- `fetchImageBytes` (`chat_images.dart`) returns null for anything that is
  not an `image/*` answer under 15 MB — chat images are decoration, never an
  error. The repository remembers results (misses too) per `account|src`,
  300 deep, so polling never re-fetches.

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
  `conversations.mark` on DMs — channels are never marked, so no
  `channels:write`), `files:read` (images), `search:read`. A scope added
  later surfaces as `missing_scope` → reconnect, which grants it.
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
- **Unread** is DMs and group DMs only, as Teams leaves channels out. One
  `users.conversations` of `im,mpim`, then `conversations.info` for 15 per
  poll — the ones with the newest known activity first, the rest going
  round in turn. A DM's info carries `unread_count_display`; a group DM's
  `last_read`, checked against the messages after it.
- **Bodies** are mrkdwn (`mrkdwnToHtml`): Slack sends `&`, `<`, `>` escaped,
  so the only raw `<…>` are its controls — `<@U…>` (named from `_users`),
  `<#C…|name>`, `<!here>`, `<url|label>` (http(s)/mailto only). Common
  `:shortcodes:` become emoji; others stay as text. Outgoing text escapes
  `&<>` and is otherwise mrkdwn as typed.
- **Images:** files on `files.slack.com` are fetched with the token (their
  `thumb_720`); anything else, including avatars, over https without it.
- **Search:** `search.messages` (Tier 2, user tokens), so
  `searchesOnServer` is true — no recent-history scan.
- A 429 waits out a `Retry-After` of up to 20 s once, then fails readably.
- A workspace connected in Settings reaches an already-open chat window
  (another isolate) when that window is next opened.
