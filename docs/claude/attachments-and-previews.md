# Attachments & Inline Previews

How an attached `.eml`/`itemAttachment`/Markdown file is previewed in the reading pane, across `data/services`, `data/datasources/remote`, and `presentation/widgets`. See [../../CLAUDE.md](../../CLAUDE.md) for architecture-wide rules.

## An Attached Email Is Previewed In Place

A `message/rfc822` attachment — a forward, or a message somebody attached to
another — is drawn in the reading pane's own preview surface
(`_EmlPreview`/`_EmlBodyView` in `reading_pane.dart`), the same surface the PDF,
image and cloud-document previews use. `_AttachmentChip._previewKind` claims it
on `rfc822` in the content type or an `.eml` extension.

Four things here are load-bearing:

- **The parse goes through `compute()`, like every other message parser.**
  `EmlParser.parse` is `Uint8List` in, `Email` out — the same shape as
  `ImapDatasourceImpl.parseFullImapMessage` — and for the same reason: the MIME
  carries the body *and* every inline image as base64, so the decode is the
  expensive half and must not run on the UI isolate. Both callers
  (`_EmlPreviewState._load` and `EmailDetailBloc._onLoadedFromEml`) are already
  async, so this cost nothing at the call sites.
- **Inline images are collected by a direct tree walk, not `findContentInfo`.**
  That helper matches `Content-Disposition` *exactly*, so it answers neither the
  `inline` nor the `attachment` query for a part carrying a `Content-Id` and no
  disposition header at all — a very common shape. Disposition is the wrong
  signal twice over: Gmail tags pasted inline images `attachment` while still
  referencing them by `cid:`, and a forwarded Gmail message is the common case
  for an `.eml`. A Content-Id on a non-text part is what decides membership.
  Without this list every inline image drew as a broken glyph: `HtmlBodyView`
  resolves `cid:` tokens from `inlineAttachments` alone, and the reading pane's
  CSP is `img-src data: file:`, so an unresolved token is a reference the policy
  refuses as well as one nothing satisfies.
- **A nested `message/rfc822` is not descended into.** enough_mail hangs an
  encapsulated message's parts directly off the rfc822 part with no node in
  between, so the walk would pull a forward-inside-the-forward's images up into
  the list. They are referenced by *its* body, not the one being rendered, so
  that is megabytes of base64 spent on cid tokens nothing asks for.
- **The nested message's own attachments come through a bytes-provider seam.**
  A part inside a previewed `.eml` has no server-side id to download by, so
  `_AttachmentsSection`/`_AttachmentChip`/`_SaveAllButton` take an optional
  `bytesLoader` and use it in place of `sl<DownloadAttachment>()`. The choice is
  made on the loader being **non-null, never by inspecting the id** — a MIME
  path like `2` is a perfectly plausible provider id, and a heuristic there
  fails silently towards hitting the network with a garbage id.
- **Two attachments on one message routinely share a name**, so the scratch
  file each is written to is named from a directory keyed on the *attachment
  id* (`_scratchFile`), not from the name alone. Five `Undeliverable:` bounces
  off one send is the case that found this, and the second of the two bugs is
  the one that reads as nothing having happened: the preview is keyed
  `ValueKey(_previewPath)`, so an unchanged path reuses the existing State,
  `initState` never runs again, and picking a different attachment goes on
  showing the first. The discriminator is on the directory rather than the file
  so the name stays what the sender called it — the preview header shows it, and
  the mobile share sheet offers it as the name to save.

### A part inside a previewed `.eml` is addressed by its own MIME path

`EmlParser` numbers parts itself (`2`, `3.1`) rather than reading enough_mail's
`fetchId`, because that one **collapses**: `collectContentInfo` hands a child of
a `message/rfc822` part the *parent's* id instead of appending an index, so
every attachment inside a forwarded message ends up sharing one id. That is
`attachmentParseVersion` 2 in the cache — the chips look right and every one of
them fetches the same wrong bytes. `_collectAttachments` and
`extractEmlAttachmentBytes` run the *same* walk, so the path a chip carries and
the path its bytes are fetched by cannot drift.

Three more things here:

- **Ids are namespaced `<emlId>#<partId>`.** Two previewed messages both have a
  part `2`, and a bare path would collide in the reading pane's scratch
  directory (`_scratchFile` keys on the attachment id) and in the active-chip
  check. `emlPartIdOf` recovers the tail.
- **The walk does not descend into an encapsulated message.** That message is
  offered whole as its own `.eml`; descending would flatten its attachments into
  its parent's list, which is the shape the numbering exists to avoid. Nesting
  is not depth-limited — a bounce chain is a real thing, and each level is
  reached by previewing the level above.
- **Bytes are re-read and re-parsed on demand**, in an isolate, rather than held
  from the original parse. A previewed message is opened far more often than its
  attachments are, and keeping them resident would make every preview cost the
  size of the whole message.

`hasAttachments` is derived from the collected list rather than
`MimeMessage.hasAttachments()`, which matches on `Content-Disposition` and so
disagrees with the walk for a part named only by `Content-Type; name=` — a chip
on screen while the flag said there were none.

**`EmailDetailLoaded.emlSource` is the same seam for the other surface.** A
`.eml` opened from a task attachment renders through the *main* reading pane,
which has no file on disk to read parts back out of — so the raw bytes travel
with the state. Without it that path draws chips it cannot honour, which is
strictly worse than the empty list it used to draw. The bytes are kept out of
`props` (Equatable would deep-compare a whole message on every emit); the length
stands in.

**Save All de-duplicates names.** Five `Undeliverable:` bounces off one send all
have the same name, and every one of them used to be written to the same path —
four of the five silently lost behind a progress bar that counted all five.

### Outlook attaches an email as an `itemAttachment`, which is not a file

Graph answers "attach an email" with a `#microsoft.graph.itemAttachment`. It has
no `contentBytes` — that property is on the `fileAttachment` subtype — and its
`name` is the attached message's *subject*, so it arrives with no extension to
read a type off. Left alone it got no preview, no icon, and `downloadAttachment`
threw outright, so the chip could not be opened or saved either.

Two halves, and the split matters:

- `GraphApiDatasourceImpl.downloadAttachment` falls back to `/$value` when
  `contentBytes` is absent *or* empty, which serves the item as raw MIME.
  Reached **only where the old code threw**, so the fileAttachment path is
  untouched: an attachment that really has no content still fails, one round
  trip later.
- `EmailModel._isEmbeddedMessage` claims it on `@odata.type` containing
  `itemattachment` **or** a content type containing `rfc822`, and
  `_emlFileName` gives it a `<subject>.eml` name (capped at 120 characters,
  mirroring the IMAP path's `_forwardedMessageName`).

**`@odata.type` survives the `$select`, and `contentType` is `null`.** Verified
against a live tenant, on a message carrying five `Undeliverable:` bounces:

```json
{ "@odata.type": "#microsoft.graph.itemAttachment",
  "name": "Undeliverable: REQUEST FOR VOLUNTEERS",
  "contentType": null, "size": 35588, "isInline": false }
```

So the type annotation is the discriminator that works, and it arrives even
under `$expand=attachments($select=id,name,contentType,size,isInline)` — the
caveat about `$select` stripping it applies to `eventMessage` on a
single-resource GET, not to an expanded attachment collection.

**The match must not be widened to "no content type", even though every
itemAttachment shows one.** `null` there is not exclusive to attached mail, and
an attachment Graph merely declined to *type* would then be offered as an
email, parse to an empty one, and lose the open-externally behaviour that works
today. The annotation is exact; the absence of a content type is a guess.

Gmail and IMAP need none of this — Gmail names the part `<subject>.eml` with
`Content-Type: message/rfc822`, and IMAP's `_forwardedMessageName` already does
the same.

### The cache is why a fix here needs a stamp bump

The reading pane decides whether to offer a preview from the **cached**
`name`/`contentType`, and a full-bodied cached row short-circuits the network.
So the parse fix above changed nothing for any message already read: the chip
kept its pre-fix metadata and would never preview, however many times it was
reopened. `EmailLocalDatasourceImpl.attachmentParseVersion` is what forces the
one-time refetch — it went to **6** for this. Any future change to what
`_parseAttachments` produces needs the same, or it only ever applies to mail
that arrives afterwards.

## A Markdown Attachment Is Rendered, Not Shown As Source

A `.md` attachment is rendered to HTML by `MarkdownPreviewService`
(`data/services/`) and drawn on the reading pane's webview preview surface —
the same one the PDF and Office previews use. A drive link to one takes the
same route: `.md` used to be a `plainText` cloud document, which drew the raw
source, so `CloudDocumentFormat.markdown` exists to keep one file looking the
same in one pane however it arrived. What *counts* as markdown is
`isMarkdownFile` (`core/utils/markdown_file.dart`) — one rule, read by the
attachment chips and by `cloudDocumentFormatFor`, because two copies of that
list is how the same file comes to be two different things in one pane.

Four things here are load-bearing:

- **The render is Dart-side, and that is forced rather than merely cheaper.**
  The generated document carries `script-src 'none'`, so a vendored `marked.js`
  next to it — the shape `OfficePreviewService` uses for docx/xlsx — would be
  inert in the page it was meant to render. It also means this page has no
  sibling files at all, which keeps macOS's directory-scoped `loadFileURL` read
  access out of the picture and needs no asset extraction.
- **It cannot route through `_AttachmentChipState._previewKind`.** Returning
  `webFile` there is tempting, since `webFile` is where it ends up — but that
  path writes the attachment's own bytes to disk and hands the path to the
  webview, which renders the markdown *source* as text. It needs the build step
  first, so it branches beside `_previewOffice`. The output file is named
  `markdown_<micros>.html` for the reason `buildJsViewer`'s is: the preview is
  keyed `ValueKey(_previewPath)`, and an unchanged path goes on showing the
  last document.
- **The policy is this page's own, not `contentSecurityPolicy()`.** That one
  governs a document *the sender wrote*, where a stylesheet that will not load
  takes the message's layout with it and inline images arrive as `file:`
  alongside. This one governs a document the app generated, so it names a much
  shorter list and adds `form-action 'none'`. Remote images stay refused at
  every setting — there is no "Download once" on this surface, that belongs to
  the mail body's status bar, and a `.md` file carries a tracking pixel as
  readily as a message body does. A refused image falls back to its alt text.
- **Raw HTML is escaped by `_escapedRawTags`, not by GFM's tagfilter.** The
  renderer offers one (`enableTagfilter`), and it fires only when the tag name
  is immediately followed by `>` — so `<script>` is caught and
  `<script src="…">` is not, which is precisely the wrong half. The list here
  is every tag that fetches, executes or re-points the document; everything
  else a README writes raw (`<br>`, `<details>`, `<img align>`) is kept. The
  CSP is what makes them inert either way; escaping means the reader *sees*
  what the file asked for instead of an empty box.

Link destinations are filtered on the AST rather than the rendered string:
`http`, `https`, `mailto`, a `#heading` anchor and a `data:image/` all survive,
and everything else — `javascript:`, and a relative `./NOTES.md` that would
resolve against the scratch directory — loses the attribute and renders as the
text it was written as. The theme is passed in rather than left to
`prefers-color-scheme`, which follows the OS past the in-app toggle.

**A link in a previewed document now opens.** `_WebFilePreview` had no
`onLinkOpened` listener, and the native side cancels every http/https/mailto
navigation before reporting it — so a link in a previewed PDF or document was
silently dead. Invisible there; obvious in a README, which is mostly links.
It goes through `openBodyLink`, so a cloud-document link previews in place as
it does from a message body. The preview *header's* title is the one that
deliberately calls `launchUrl` directly instead (see `_PreviewHeader`).

Nothing here needs an `attachmentParseVersion` bump: this changes how an
attachment is *drawn*, not what `_parseAttachments` records about it.

