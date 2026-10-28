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

## The Compose Editor Is a Platform View on a Phone

`html_view` draws its webview as a **native sibling view laid over the Flutter
surface**, placed by hand from `localToGlobal` on the frame it was built. That
is fine for a desktop window, where the editor is the window, and wrong on a
phone in three ways at once: the position is read during the page's slide-in
transition and never again, so the view lands off to the right; the view sits
above every dialog and sheet Flutter draws, which is what `setVisible` exists
to paper over; and the iOS half loaded `assets/…` from
`Bundle.main.resourcePath/flutter_assets`, which is not where an iOS app keeps
Flutter assets (`App.framework`). On an iPhone that was a reply with no
toolbar, nothing to tap into, and a blank white box where the body should be.

`HtmlEmailEditor` therefore has two backends behind one interface, split on
`Platform.is*` the same way `HtmlBodyView` splits: the `html_view` overlay on
desktop, and **`webview_flutter`'s `WebViewWidget` on Android and iOS**, a real
platform view composited into the Flutter tree — it moves with its route,
sits under dialogs, and needs no `hide()`/`show()` (those are no-ops there).
The page is shared unchanged: `editor.html` reports through
`window[name].postMessage`, and `addJavaScriptChannel(name)` defines exactly
that object, which is what the desktop bridges inject by hand. Two things a
mobile backend has to get right:

- **`runJavaScript`, not `runJavaScriptReturningResult`, for statements.**
  WKWebView reports a result of `undefined` as an error, and every editor
  call but `getContent()` returns nothing.
- **`getContent()` comes back bare from WKWebView and JSON-quoted from
  Android and the desktop bridges.** `HtmlEmailEditorState.getContent`
  decodes when that succeeds and takes the string as-is otherwise.

The page also carries a `viewport` meta (without it a phone lays it out 980px
wide and shrinks it, toolbar included, to a third of its size) and a
`pointer: coarse` rule that grows the toolbar buttons to 36px. The `ios/` and
`android/` halves of `packages/html_view` are now unused by the app; nothing
in `lib/` reaches `HtmlViewWidget` on a phone.

**On a phone the header folds, and the caret is followed by hand.** With the
keyboard up, From/To/Cc/Subject left the editor a sliver. So on a touch
platform they fold into a two-line summary (`_CollapsedFieldsSummary`: To
names, Cc/Bcc *counts* so a long To list can't ellipsize a Bcc out of sight,
then the subject), opened by a tap and closed by the chevron on the From row.
A message with recipients starts folded, a new one starts open, and it folds
when the body takes focus. The page posts `onEditorFocus` for that, because
the phone backend has no native `onClickFocus`. A send refused for want of a
recipient opens it again. Folded fields stay mounted
(`Visibility(maintainState)`): the recipient fields are driven through
GlobalKeys, and text typed but not yet a chip is `flush()`ed before folding
so the summary shows it. Folded, the summary sits *outside* the scroll view
and the editor fills exactly what is left above the keyboard, rather than
keeping the keyboard-less floor described below: with no tall fields to
scroll away, that floor only pushed the bottom of the webview under the
keyboard, where no in-page scroll can reach. Folding adds or removes siblings
before the `Expanded` only, so the editor is resized, never reparented.

Pressing Enter on the last visible line used to leave the caret under the
keyboard, because two viewports have to follow it and neither did.
`#editor-scroll` can't rely on the engine's caret reveal, since WKWebView's
scrolling is inert while the keyboard is up, so the page sets `scrollTop` on
`input` itself. With the header open, the webview box is floored against
the keyboard-less height and can be clipped by the Flutter scroll view, so the
page then posts `onCaretMoved` (top,bottom in page px = logical px) and
`_revealEditorCaret` scrolls that line into the outer viewport. A caret on
the empty line Enter just made measures as a zero rect, so `_caretRect` falls
back to the element at the caret. Both events only fire behind
`setScrollHandoffEnabled(true)`, so the signature editors are untouched.

**A snack bar in the compose form is under the editor on the desktop.** The
overlay covers the bottom of the window, which is exactly where a `SnackBar`
lands, so a failed send used to show a red bar with the message body painted
over it. Nothing in the form goes through `ScaffoldMessenger` now:
`ComposeFormState.showNotice` puts the message in a strip *inside the form's
layout*, above the footer, which shrinks the editor (its position and size are
re-reported on every layout) instead of competing with it. The window and
dialog hosts leave `ComposeError` to the form for the same reason. Anything
else Flutter needs to draw over the editor takes the other route: `hide()` it
first, `show()` it after, the way every dialog the form opens already does.

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

### Linux: GTK focus has to be taken back by hand

The opposite direction is the problem on Linux. A click in a `WebKitWebView`
takes GTK keyboard focus, and Flutter's `FlView` is focusable but never grabs
focus on a click (`fl_view.cc`, still true on 3.47.8). So after a click in the
compose body, clicking Subject or To moved Flutter's focus there but every
keystroke still went to the webview; the fields were dead until the window was
reopened (2026-10-28). `html_view_plugin.cc`'s `reclaim_focus_on_click` grabs
focus for the `FlView` on any press over it that it doesn't already hold. It
hooks the event box's generic `event` signal, because the `FlView`'s
`button-press-event` handler reports the press handled and stops any handler
connected after it.

## Formatting From the Keyboard

The compose editor binds the Gmail/Docs/Outlook-web set, because that is the
muscle memory a mail composer inherits: **B** bold, **I** italic, **U**
underline, **Shift+X** strikethrough, **Shift+8** bullets, **Shift+7** numbers,
**]** indent, **[** outdent, **K** insert link, **\** remove formatting — each
with the platform's own modifier. Tab and Shift+Tab nest and un-nest a list
item; outside a list Tab is still four spaces, and Shift+Tab, which used to
insert four *more* (`e.key === 'Tab'` matches both directions), now does
nothing.

Colour, font family, font size, the format painter and attach are deliberately
**left mouse-only**. No two mail clients agree on a key for any of them, so a
binding here would be one this app invented, and a wrong guess is worse than
reaching for the toolbar.

**Bold/italic/underline are intercepted rather than left to the engine**, even
though an engine may bind some of them natively inside a contenteditable. A
native toggle on a collapsed caret changes the typing style *without moving the
selection* — so no `selectionchange` follows and the toolbar's pressed state
only catches up on the `keyup` fallback, a frame late at exactly the moment the
user wants to know what typing will do. Taking the key ourselves is also what
stops the five engines diverging over which chords they happen to implement.
Every binding calls the same function the matching toolbar button calls
(`fmt(cmd)`, `requestLink()`), so a shortcut and a click cannot drift apart.
Only a recognised combination is `preventDefault`ed; Cmd+A/C/V/Z still reach
the engine, and the `keyup` listener stays for them — undoing a bold is the
case it now exists for.

**Measured in WKWebView on macOS only** (a bare harness over
`assets/editor/editor.html`, the same method the first-responder section below
used): every binding applies, Ctrl+B / Cmd+A / Cmd+Alt+B fall through
unprevented, and Cmd+K survives the selection being wiped. WebView2,
WebKitGTK and the Android WebView are *unverified* — the interception is what
makes them likely to agree, not evidence that they do. If a chord never
arrives, the thing to suspect is a layer above the page: on macOS the
`NSEvent.addLocalMonitorForEvents` in `WebKitView.swift`, which already
consumes Cmd+P for both webviews; on Windows, WebView2's
`AreBrowserAcceleratorKeysEnabled` (`]`, `[` and `\` are not among the chords
it reserves, but that is the switch to look at).

**Letters match on `e.key`, digits and punctuation on `e.code`.** With Shift
held, `e.key` for the 7 key is `&` on a US layout and something else again on a
UK or German one, so a `key === '7'` test never fires; `e.code` names the
physical key regardless of layout. Letters stay on `e.key` so a Dvorak or
AZERTY user gets the letter printed on the keycap they pressed.

**The modifier test is exclusive, and Alt is never part of one.** Ctrl+B on
macOS is the system's back-one-character text binding and has to keep working,
so the Apple branch requires `metaKey && !ctrlKey`; Cmd on Windows and Linux is
the Super key, which belongs to the desktop, so the other branch requires
`ctrlKey && !metaKey`. Alt disqualifies every binding: it makes a different
shortcut, and on macOS it rewrites `e.key` into the character it would type.

**Cmd+K had to fix the selection before it could work.** `_onLinkRequested`
**hides** the webview while the Insert-link dialog is up, and a WKWebView that
resigns first responder has WebKit clear the DOM selection outright (the
section below on first responder measures this) — so `insertLink`'s
`editor.focus()` was restoring a caret at offset 0, and `createLink` over a
collapsed caret links nothing. `requestLink` now snapshots the range on the way
out and `insertLink` puts it back. That was already true of the toolbar's link
button; the shortcut only made it impossible to ignore.

**Outdent walks out of a structure, not just an indent level.** Two cases are
worth knowing before either is filed as a bug, because both match Gmail and
both are newly easy to reach now that a chord does them. Cmd+[ with the caret
inside a `<blockquote>` strips a quote level — and this app's own quote wrapper
*is* a styled `<blockquote>` (see the sanitiser section below), so it unquotes
the reply. Shift+Tab on a top-level `<li>` takes the item out of the list
altogether rather than doing nothing; on a one-item list, the list goes with
it. Measured: `<ul><li>one</li><li>two</li></ul>` → `<ul><li>one</li></ul>two`.

`test/presentation/widgets/editor_keyboard_shortcuts_test.dart` pins the
binding table, since the behaviour itself only exists inside a real engine.

## Formatting As You Type

Two Markdown-shaped habits a mail composer inherits from Word, Outlook, Docs
and the chat clients, both under "Formatting as you type" in
`assets/editor/editor.html`:

- **A list marker and a space start a list.** `- ` has done this for a while;
  `1. ` and `1) ` start a numbered list the same way. The marker has to be the
  whole of the line so far, and only `1` counts: Word and Docs accept any
  number and turn `2026. ` at the start of a line into a list counting from
  2026, and once a list exists Enter continues it, so nobody types `2. ` by
  hand. The triggers are the `LIST_TRIGGERS` table; the handler names none.
- **A word wrapped in markers takes the style when the closing marker is
  typed.** `*bold*` or `**bold**`, `_italic_`, `~struck~`. Nesting works
  (`*a _b_ c*`), brackets and quotes around the span are fine, and the result
  is the same `<b>`/`<i>`/`<strike>` the toolbar's own command produces, so
  nothing downstream can tell the two apart.

**The inline conversion runs from the `input` event, after the engine has
inserted the closing marker — not from keydown.** The conversion is then its
own undo step: Cmd+Z hands back the literal `*bold*` the user typed, closing
marker included, where swallowing the keydown would have lost that keystroke;
and because the closer has to be the character just typed, the undone text
does not convert again. `input` also carries the character in `e.data`, where
an Android soft keyboard's keydown carries `Unidentified` — though a composing
keyboard is *unverified*: a word it commits as one `insertText` ending in the
marker converts, one committed with its trailing space does not. (The list triggers
stay on the space keydown: the marker is deleted and the block becomes an
item, so the space has nowhere to land and is swallowed.)

Measured in a bare WKWebView over the asset and in Chrome with real
keystrokes, and the two engines agree on all of it:

- **After `insertHTML('<b>bold</b>')` the caret is inside the new element at
  its end**, `queryCommandState('bold')` is true, and the next character
  typed is bold. Toggling the command on that collapsed caret — what the
  toolbar does to change what typing will do — fixes that for an
  `execCommand('insertText')` in both engines, and shipped that way; with a
  **real keystroke in WKWebView the toggle is gone before the next character
  arrives**, even in a bare contenteditable with no page script, so the text
  after `*bold*` stayed bold in the app. The conversion therefore ends with a
  zero-width space after the element, the anchor the ordinal-suffix path
  already uses, and the next character lands after it as plain text.
- **`insertHTML` fires its own `input` event with `inputType: 'insertText'`
  and `data: null`** in WebKit. The `data` check is therefore the re-entrancy
  guard; a change that matches on anything else needs its own.
- **Blink refuses `execCommand` while another `execCommand` is running** — it
  returns false and does nothing. Real typing never goes through
  `execCommand`, so a keystroke never hits this, but a harness that types with
  `execCommand('insertText')` does, and by then the span is selected: left
  that way, the next character deletes the user's text. A refusal puts the
  caret back and gives up, which is what makes the failure harmless.
- **Undo gives back the selection the replacement ran over** — `*bold*`
  selected, so the next keystroke would wipe it. `_settleUndoneMarker`
  recognises the undo of the last conversion (`inputType: 'historyUndo'` with
  that literal selected) and collapses the caret to its end.

What keeps ordinary text literal is all in `_findMarkerOpener`: a marker opens
a span only where a word starts (start of line, whitespace, or an opening
bracket or quote before it) and only with something other than whitespace or
another marker after it; it closes one only where a word ends; the opener
nearest the caret wins; and the span stays on one line — a `<br>`, an image
or a block boundary ends the search, and the span may hold only inline
formatting (`INLINE_MARKER_CONTENT`). That is what leaves `my_var_name`,
`5*3*2`, `*.txt and *.doc`, `a * b * c` and `rated ****` as typed. It is the
rule Word applies, and like Word it will still bold the stretch between a
footnote `*` after one word and another `*` after a later one; Cmd+Z is the
answer there.

**The anchor costs a keystroke unless something steps over it.** Measured
with real keystrokes: Backspace straight after a conversion removed only the
zero-width space, so nothing visible happened, and an arrow key needed two
presses to pass it. `_stepOverZws` runs first on every keydown: an arrow moves
the caret across the anchor and then the engine moves it as normal, Backspace
and Delete remove the anchor and then the engine deletes as normal. The
removal is an `execCommand('delete')`, never a direct DOM edit: the anchor
was inserted by the conversion's `ReplaceSelectionCommand`, which may have
merged it into a neighbouring text node, and undoing that command later would
delete one character at the recorded offset — the user's, if the anchor had
been taken out from under it. Adjacency stops at a `<br>` or a block
boundary, so Left at the start of a line still lands at the end of the one
above. The ordinal `<sup>` gets the same treatment for free.

`INLINE_MARKER_CONTENT` is also a security boundary. The span's markup is
serialised and handed to `insertHTML`, which is a re-parse, so the
namespace-switching trio (`svg`, `math`, `noscript`) that the sanitiser
section below drops for exactly that reason must never be let into it.

Left out on purpose: `* ` as a bullet trigger (Word and Markdown both do it;
one table entry if wanted), backtick for monospace (no toolbar command or
element of the editor's own to mirror), and list numbers other than `1`.

**Drive the harness with real key events, not `execCommand('insertText')`.**
The two differ in exactly the way that matters here — the typing-style
toggle above survived one and not the other — so a WKWebView harness has to
synthesise `NSEvent` key events and send them to the view's `keyDown`. It
also cannot measure undo: every editing command run from one
`evaluateJavaScript` lands in one NSUndoManager group, even across
`setTimeout` turns, so `execCommand('undo')` there reverts the page to its
load. Chrome with real keystrokes is where the undo story was checked.

`test/presentation/widgets/editor_auto_format_test.dart` pins the trigger
tables, the `input`-event routing and the guards.

## The Quote Wrapper Is Contained, Never `content-visibility: auto`

`ComposeBodyBuilder` wraps the quoted original in a `<blockquote>` (reply) or
`<div>` (forward) styled `contain:layout style`, so the editor's layout work
for a keystroke stops at the quote's boundary. For a while that was
`content-visibility:auto; contain-intrinsic-size:500px` instead — a superset
that also skips layout and paint for the part of the quote scrolled out of
view — and it made the reply look empty: the compose window opened onto a
blank 500px box where the original message should be, while the plain-text
editor showed the same message fine.

`content-visibility: auto` withholds rendering of the subtree until the
engine's intersection check declares it "relevant to the user", and that check
only runs in a rendering update. Measured in the compose window's WKWebView
with a DOM probe after `setContent` (the quote's `innerText.length` and
`offsetHeight`):

- **The quote was present in the DOM from the start** (`innerHTML` complete)
  but its `innerText` was empty and it stood 500px tall — the placeholder — at
  0s and 1s, and only filled in somewhere between 1s and 3s.
- **`document.visibilityState` later flipped to `hidden`** with the window
  still on screen. WebKit stops rendering updates for a page it judges hidden,
  and with them the relevance check, so a quote that had not yet been revealed
  stays a blank box for as long as that lasts.
- In a bare WKWebView over the same asset the reveal took under a second,
  which is why the perf commit looked fine and why this is recorded here: the
  Flutter-hosted view is the environment that matters, and the harness does
  not reproduce it.

With `contain:layout style` the same probe reports the quote rendered at 0s.
Containment isolates; it never withholds. `innerHTML` was unaffected either
way, so drafts, send and copy never lost the quote — only the reader did.

`test/presentation/widgets/compose_body_builder_test.dart` pins the wrapper's
style.

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

