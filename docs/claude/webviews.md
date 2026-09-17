# Native Webviews (Reading Pane & Compose Editor)

CSP, remote-image blocking, linkification, focus handling and HTML sanitisation for the two embedded webviews. See [../../CLAUDE.md](../../CLAUDE.md) for architecture-wide rules.

## The Reading Pane's CSP Goes First, or It Governs Nothing

`script-src 'none'` is the whole reason a mail body can be handed to a webview
that has script enabled (which the desktop ones do — mobile disables it
outright). **A `<meta>` policy only governs what is parsed after it**, so it was
spliced in before `</head>`, behind whatever the sender wrote — and a `<script>`
in the sender's own head had already run by then, with the page's bridge to the
host in reach.

`installContentSecurityPolicy` puts it at the very start of the document
instead. Three things about that position:

- **It cannot simply follow the literal `<head>`.** A `<script>` written
  *before* `<head>` is malformed and the parser hoists it into an implicit head,
  ahead of a policy placed inside the sender's head tag. Starting the document
  is the only position that covers both.
- **Behind a leading doctype, never in front of it.** Anything before the
  doctype makes the parser ignore it and lay the document out in quirks mode,
  which moves the tables in most of the mail people read.
- **Ahead of `<html>` is fine** — the parser hoists a leading meta into the
  implicit head, the same property `forceUtf8Charset` already relies on, and the
  charset prescan reads bytes rather than the tree.

**The injected styles stay at the end of the head.** They are `!important`
throughout, and at equal specificity the later `!important` wins, so hoisting
them with the policy would hand a sender's `img { width: 600px !important }` the
argument over the `max-width` clamp and the blocked-image chip. That is why the
policy is a separate splice rather than the first line of `injected`.

Host `evaluateJavaScript` is not subject to the page's policy, in either desktop
engine — which is how this is testable at all, and worth knowing before treating
a CSP as a limit on what the app itself can do to the document.

What is *in* the policy is the section above; `script-src 'none'` is only the
part of it that made a mail body inert.

## What Holds a Remote Image Back Is the Policy, Not the Rewrite

**`contentSecurityPolicy(allowExternal: …)` is the enforcement.**
`blockExternalImages` only decides what the reader *sees*. That division is the
point: an `<img src>` is one of at least eight ways a mail body reaches a
tracker, and element rewriting used to be the whole of the defence — so
`style="background:url(https://…)"`, a `<style>`'s `@import`, an `@font-face`, a
`srcset`, a `<picture><source>`, a `<video poster>`, a `<link rel=stylesheet>`,
an `<input type=image>`, a `<table background>` and an `<iframe>` all still
phoned home with blocking switched on. Measured, before the policy carried it:
**14 requests** from one body, in both desktop engines. Naming the schemes a
subresource may come from is one line and cannot be got round; rewriting each
route in turn is a parser written in regular expressions.

So `img-src`/`font-src`/`media-src` are `data: file:` while blocking, and gain
`https: http:` when the reader presses Download once / Always. `data:` is the
inline-attachment route and the substituted pixel, `file:` is the same
attachments once the document is written to disk. **Not `'self'`** — a `file:`
document's origin is opaque, so `'self'` matches nothing and would hold back the
message's own images.

Three directives never open, at either setting:

- `script-src`/`object-src` — a mail body has no business executing.
- `frame-src` — an `<iframe>` is a document this policy does not govern: it runs
  its own script under its own origin, and in WKWebView a subframe can reach the
  host's `messageHandlers` bridge. Both webmail providers strip iframes; this
  refuses to fetch them, which is the same answer with an empty box left behind.
  It stays refused after Download once, which is deliberate — the reader asked
  for the pictures, not for a third party's document.
- `base-uri` — a `<base href="https://…">` re-points every *relative* URL, and
  a file-delivered message's inline images are referenced relatively. That turns
  the sender's own attachments into a call home. Verified: it fires under the old
  policy and is refused under this one.

What `blockExternalImages` is still for:

- **A held-back `<img>` gets the pixel, not an empty `src`** — no `src` at all
  makes the engine draw its own broken glyph and the sender's `alt` over the
  placeholder. The `src` is *renamed* to `data-blocked-src` because the injected
  stylesheet keys the chip off it. Images declaring ≤3px either way are trackers
  and stay hidden (`data-blocked-spacer`).
- **`srcset` has to go with it.** A candidate list outranks `src`, so leaving one
  would mean a request the policy refuses and then the broken glyph the pixel
  exists to avoid. Same for a `<picture>`'s `<source>`, which is chosen ahead of
  the `<img>` inside it — held back, the fallback `<img>` applies, and that is
  the one already carrying the chip.
- **Reporting.** The status bar's "Download once" is offered off the returned
  flag, so a message whose only remote content is a CSS background has to count
  as blocked even though nothing was rewritten (`_remoteSubresource`). A
  background that never loads leaves nothing to draw, which is why the policy
  alone is enough for the rest.

## Bare URLs in a Message Body

A URL a sender typed as text is turned into a real link at render time
(`core/utils/linkify.dart`). Both body renderers use it and each needs its own
half, because they have nothing else in common:

- **HTML** — `linkifyHtml` writes `<a href>` into the document `HtmlBodyView`
  hands the webview. That is the whole reason it happens there rather than at
  parse time: link hover reporting, click-to-open-externally and copy-link are
  already wired to anchors in the page, so a linkified URL picks up all three
  for free. It is a *scanner*, not a parse — the body is about to be handed over
  as text, so re-serialising a DOM would risk changing far more than the links —
  and it runs before the `cid:` substitution so it scans the sender's body
  rather than the same body with every inline image expanded into it. Text
  inside `<a>`, `<script>`, `<style>`, `<title>` and comments is left alone;
  nesting an anchor loses the outer link.
- **Plain text** — `PlainTextBodyView` builds spans, and uses `SelectionArea` +
  `Text.rich` rather than `SelectableText.rich`: `SelectableText` renders through
  `RenderEditable`, which never dispatches to a span's `recognizer`, so the links
  would look right and do nothing. It carries its own `BodyStatusBar` so hover
  offers copy-link in the same place the webview path does.

The fiddly part is not matching `https://` but deciding where the URL *ends* —
the full stop after `.../timesheets.` closed the sentence, the `)` closed the aside
(unless the URL's own brackets are unbalanced), and in HTML an escaped `&nbsp;`
or `&gt;` is made of URL-legal characters, so it ends the URL wherever it
appears rather than only at the tail. `&amp;` is deliberately not a boundary —
that is how a query string's own separators arrive.

Only `http`/`https` and `www.`-prefixed hosts are linked. Guessing at bare
`example.com/x` turns file names and version numbers into links. Email
addresses and `mailto:` URLs are linked too, but the last label must be
alphabetic, or `package@1.2.3` becomes a way to mail somebody.

## Resigning First Responder Costs the Caret

On macOS the editor and reading-pane webviews are plain sibling `NSView`s, so
nothing in Flutter's focus system ever gives them first responder — hence
`FocusableWebView.mouseDown` signalling `onClickFocus`, and the Dart side
unfocusing its own field before calling `focus()` (`WebKitView.swift` explains
the ordering).

**That round trip is not free: resigning first responder makes WebKit clear
the DOM selection outright, and regaining it makes a fresh one at offset 0 of
the text node the caret was in.** Measured in a bare WKWebView over
`assets/editor/editor.html` — caret at offset 5, away to an `NSTextField` and
back, caret at 0.

`mouseDown` fires for every click in the page, and the compose **toolbar is
inside the webview**, so every press of Bold or Italic sent the caret to the
start of the line. Invisible until the caret has moved off the start, which is
why it read as "Italic does it, Bold doesn't" — Bold is just the one pressed
while the document is still empty.

Two measurements decide the fix, and both are needed:

- **Asking for first responder while already holding it changes nothing** —
  no resign, caret untouched. So the signal is sent only when the view does
  *not* hold it (`isFirstResponder`, walking up from `window.firstResponder`
  so a field editor or a future internal content view still counts as ours).
  There is nothing to steal focus from otherwise.
- **A caret placed while the view holds nothing survives being given it.** So
  the genuine steal — focus in the To: field, user clicks into the body — is
  unaffected, and needs no selection to be saved and restored around it.

The reading pane takes the same signal for the same reason (native Cmd+C) and
gets the same guard, which does nothing there until the view already holds
focus.

**One thing the guard does take away.** When the webview holds first responder
and Flutter's `primaryFocus` is on something that does *not* make the text
input plugin claim it — a button, a chip — clicking the editor no longer runs
`unfocus()`, so that widget keeps its focus ring. Keystrokes still go to the
webview, so it is cosmetic; it is named here because it is the one case where
the guard suppresses work that used to happen.

## A Quoted Reply Is Somebody Else's Markup

The compose editor is a webview with **script enabled** and a method channel to
the host, and `ComposeBodyBuilder.buildInitialHtmlBody` loads the original
sender's HTML into it — `extractHtmlBodyContent` only slices out the `<body>`.
So the reading pane's answer (`script-src 'none'`) is not available here, and
`editor.innerHTML = html` was giving a sender a script context: `<script>` does
not run from an `innerHTML` assignment, but `<img src=x onerror=…>` and
`<svg onload=…>` do, which is enough to rewrite the message about to be sent
(`onContentChanged`), attach bytes of the sender's choosing (`onImagePasted`),
and on Android read app-private files.

`setContent` therefore sanitises, and it is the **one** route inbound HTML
takes into the document — a quoted reply or forward, a draft fetched from the
provider, a signature change all arrive there — which is why the sanitiser
belongs at that end rather than in `ComposeBodyBuilder`. Paste goes through the
same rules (`_sanitizeHtmlFragment`), which is where they used to live and all
they used to cover.

Four things in `assets/editor/editor.html` are load-bearing:

- **The parse is inert.** `DOMParser.parseFromString` builds a document that
  fetches nothing and fires nothing. Assigning to a *detached* element's
  `innerHTML` — the shape the paste-only sanitiser used — is not inert: the
  image load starts there, and only the attribute stripping happening in the
  same task keeps `onerror` from firing.
- **Nothing is re-parsed after being cleaned.** `setContent` adopts the cleaned
  nodes (`importNode`) instead of serialising them back to a string, because
  that second parse is the mutation-XSS class: `svg`, `math` and `noscript`
  switch the parser's namespace, so a payload can survive
  serialise-then-reparse as something else. The paste path cannot avoid the
  string — `execCommand('insertHTML')` takes one — which is why those elements
  are dropped outright rather than stripped of handlers.
- **`data:` is refused outside an image.** Inline images in a quote arrive as
  `data:` URLs that `resolveCidImages` builds out of the attachment's own
  `Content-Type` — the sender's choice — so `data:text/html` is reachable from
  a crafted message.
- **The CSP caps a bypass; it cannot stop script.** The page needs its own
  inline `<script>`, so `script-src` has to allow inline and the policy's real
  work is `connect-src 'none'` (script that did run cannot send anything off
  the machine) plus `object-src`/`frame-src`/`base-uri`/`form-action`. Dropping
  `default-src 'none'`'s companion `script-src 'unsafe-inline'` stops the
  editor loading at all. `img-src` must keep `data:` and `http(s):`, or quoted
  images vanish.

`style` attributes are deliberately kept — they are most of a quoted body's
formatting, and this app's own quote wrapper is a styled `<blockquote>`.

**The Android WebView's `allowFileAccessFromFileURLs` /
`allowUniversalAccessFromFileURLs` must stay off** (`HtmlViewPlugin.kt`). Both
default to false and both were on, which gave the editor — loaded from
`file:///android_asset`, the one document here that runs script — the run of
app-private storage and a same-origin channel to every other origin.
`allowFileAccess` stays **on**: the reading pane loads its document from a real
file when a message has inline images.

`test/presentation/widgets/editor_html_sanitization_test.dart` pins the shape of
all of this, since the behaviour itself only exists inside a real engine.

