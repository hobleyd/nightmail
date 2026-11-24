# Chat — Teams chats and channels, and Google Chat

The Chat button (fifth in `ViewShortcutButtons`) opens a pane beside the
reading pane (`HomeView.chat`, `ChatPanel`) — a one-on-one with the selected
email's sender, or any other colleague on it from the dropdown. Double-clicking it
opens the chat window (`'chat'` sub-window, `ChatWindowApp`): every chat and
channel on the left, grouped (Chats; Teams › channels) and newest first; the
open one's history on the right, channel threads beside it; search on top.

## Only colleagues are offered

The dropdown lists the people on the email who are in the account's
organisation (`ChatRepository.colleagues`): an address on one of the
account's own domains (aliases included; never a personal domain like
`gmail.com`/`outlook.com`, the same rule as compose's internal-reply
signature), or one the daily address-book sync cached as
`ContactSource.directory` for that account — which covers a tenant with
several domains. Local only: SQL on the cache's primary key, never a lookup
per selected email. Neither Teams nor Google Chat starts a chat with an
outsider, so offering one only fails on send.

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
text — no webview per message. Images are never fetched (emoji keep their
`alt`, anything else reads "[image]"), `<script>`/`<style>` content is
dropped, and only `http(s)`/`mailto` links are tappable.

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
  `chat.messages`, `chat.memberships.readonly` — one incremental request, no
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
