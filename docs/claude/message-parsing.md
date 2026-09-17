# Message Parsing

How fetched messages are parsed off the UI isolate, across `data/datasources/remote` (Gmail/Graph parsers), `data/services` (IMAP/.eml), and what a rebuild must preserve. See [../../CLAUDE.md](../../CLAUDE.md) for architecture-wide rules.

## Message Parsing Runs Off the UI Isolate

**Parsing a fetched message never happens on the UI isolate.** Each provider
hands the **undecoded** response body to `compute()`:

| Provider | Parser | Entry points |
|---|---|---|
| Gmail | `gmail_message_parser.dart` | `parseGmailFullMessage`, `parseGmailThreads`, `parseGmailMetadataMessages`, `parseGmailForwardSource`, `parseGmailHistoryPages` |
| Microsoft | `graph_message_parser.dart` | `parseGraphFullMessage`, `parseGraphMessageCollection(s)`, `parseGraphDeltaPages` |
| IMAP | `ImapDatasourceImpl.parseFullImapMessage` | raw MIME in, `EmailModel` out |
| `.eml` | `eml_parser.dart` | `parseEmlBytes` — an attached or forwarded message |

Three things here look incidental and are not:

- **`ResponseType.plain` is load-bearing.** `jsonDecode` is a large share of the
  cost — a `format=full` Gmail message and a Graph message both carry the body
  and every inline image as base64 inside the JSON. Letting Dio decode the
  response puts that half back on the UI isolate no matter what the parser does.
  This mirrors the contacts fetchers; same reason.
- **One `compute()` per batch, not per message.** Each call spawns an isolate, so
  a 25-thread page parsed one call at a time pays isolate setup 25 times and
  loses most of the gain. List paths fetch concurrently, then parse once.
- **A parser cannot make a network call, so it reports what it could not
  finish.** `GmailFullMessage` carries `icsAttachmentId` and `pendingInline`;
  `GraphFullMessage` carries `pendingInlineAttachmentIds`. The alternative —
  decoding the response again on the UI isolate just to find them — is the thing
  being avoided. Merge fetched extras by *rebuilding* the model, not re-parsing.

Deliberate exceptions:

- IMAP **list** rows (`ENVELOPE`/`BODYSTRUCTURE`, no `BODY[]`) parse inline.
  There is no raw source to reconstruct a `MimeMessage` from, and without a body
  there is nothing expensive to decode. Only `getEmail` (which fetches `BODY[]`)
  moves, via `renderMessage()`/`parseFromText` — a documented round-trip.
  `uid` and the `\Seen` flag come from the FETCH, not the MIME, so they travel
  beside the source text.
- Reply/forward MIME **building** stays on the calling isolate: `MessageBuilder`
  needs the original as a live `MimeMessage`, and these are user-initiated
  one-offs rather than the polling path.

Mockito cannot tell `get<Map>` from `get<String>` — a Dart `Invocation` does not
carry the type argument, so the stubs collide and the last one registered wins.
That is why the whole Gmail message path uses one response type (the thread and
search *indexes* are plain too, decoded locally since they are only ids), and why
these tests stub `get<String>` with `jsonEncode`d bodies.

### Rebuilding a Parsed Message Must Carry Every Field

The rule above — "merge fetched extras by *rebuilding* the model, not
re-parsing" — has a matching hazard: a rebuild that lists the fields by hand
silently drops whatever it forgets, and what it produces is written to the
cache.

`conversationId` is the field that bites, and Gmail's `getEmail` never carried
it — the rebuild was written without it. That path rebuilds to merge a
separately-fetched inline image or ICS, so it is taken by any message with a
`cid:` part Gmail did not inline — a signature logo is enough. It is the list's grouping key
(`groupIntoConversations`), and it reaches the cache twice over:
`EmailRepositoryImpl.getEmail` caches the fetched copy, and
`BodyPrefetchService` — which the poller queues for **newly-arrived delta
messages** — writes it over *every* folder's copy through
`upgradeCachedEmailBody`.

A Gmail thread id is routinely also the id of the thread's first message, so
losing it is invisible there (`conversationId ?? id` lands on the same string)
and splits every **reply** into a thread of its own. Two messages arriving in
one thread therefore drew two rows, and went on drawing two until a manual
refresh re-listed the folder and wrote the thread id back — which is also why
it healed rather than persisting, and why the cache holds no evidence of it
after a refresh.

Both cache writers now keep the row's own `conversationId` when the copy handed
to them names none — `upgradeCachedEmailBody`, and `cacheEmails` alongside its
attachment carry-over. Neither write may *subtract*: nothing about fetching a
message can make a known thread membership unknown. Every provider's listing
carries one, so the `cacheEmails` lookup is not on the folder-load path in
practice, and it reads the column rather than decrypting anything.

That is a backstop, not the fix — Graph's `_rebuild` is the shape to copy, since
it carries every field. Nothing forces a refetch, and nothing needs to: unlike
an attachment parse, `conversationId` rides the *list* row, which every
`replaceFolder` listing rewrites. A row nulled in a folder nobody opens stays
nulled until that folder is next listed.

## A Message Body Can Be Split Across Several Parts

`multipart/mixed` names **sequential** content, so a body split into several
`text/html` parts is the concatenation of them. Apple Mail splits one that way
as a matter of course — a fragment, an inline image, another fragment, an
attachment, a fragment — and iOS Mail replying to an Outlook message with a
signature produces five or six.

The Gmail parser used to assign `htmlBody = <part>` on each `text/html` it
walked past, so it kept the **last** fragment alone. A real message rendered
completely blank on that: its trailing fragment was

```html
<html class="apple-mail-supports-explicit-dark-mode"><head>…</head>
<body dir="auto"><div><blockquote type="cite"><div dir="ltr"></div>
</blockquote></div></body></html>
```

— an empty quote shell, with everything the sender wrote in the five fragments
before it. `_collectBodyParts` is therefore container-aware:

- **`multipart/alternative` chooses; everything else joins.** An alternative
  names one body in several forms, so joining its branches would show the
  message twice — plain rendering followed by HTML. Anything else (mixed,
  related, signed, report, unrecognised) is sequence, and every text part in it
  belongs to the one body. The last branch that yields anything wins an
  alternative, which for the usual `[text/plain, text/html]` pair is the HTML,
  exactly as before.
- **The fragments are joined as they stand, not sliced apart.** Each is a
  complete `<html>` document, and six of them concatenated is a shape the HTML
  parser is specified to merge: a second `<html>` or `<body>` start tag folds
  its attributes into the open element, a `<head>` in body content is ignored.
  Re-serialising them into one document would mean a second parse over
  somebody else's markup for no gain.
- **`message/rfc822` is still not descended into** — it is a message attached
  to this one, not part of its body, the same rule
  [`EmlParser`](lib/data/services/eml_parser.dart) follows.

**The cache is why this needed a stamp bump.** The broken body was ~230
characters, not empty, and a non-empty cached body short-circuits the network
for good (`EmailRepositoryImpl.getEmail`) — so every message already read kept
its blank shell forever, however many times it was reopened. The discarded
fragments also held the body's `cid:` references, so `_referencedCids` saw none
and the message's inline images were filed as ordinary attachments.
`attachmentParseVersion` went to **7** for both.

Graph is unaffected — it returns one rendered body. IMAP goes through
enough_mail's own `decodeTextHtmlPart()`, which has not been checked against
this shape.

## Graph Never Says Whether a Body Was Plain Text

`body.contentType` reports the format Graph *rendered*, not the one the sender
wrote, so it always echoes the request. `getEmail` therefore probes the
message's own `Content-Type` header alongside the main fetch
(`declaresPlainTextBody`); a plain-text message with an attachment is
`multipart/mixed` and still renders as HTML.

