import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:html_view/html_view.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/platform/window_utils.dart';
import '../../core/settings/app_settings.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/linkify.dart';
import '../../data/services/inline_attachment_cache.dart';
import '../../domain/entities/inline_attachment.dart';
import '../../injection_container.dart';
import 'body_link_opener.dart';
import 'body_status_bar.dart';

/// A prepared document, ready to hand to the webview. Exactly one of
/// [filePath] and [inlineHtml] is set: large or image-bearing bodies are
/// written to disk and loaded by URL, everything else is loaded as a string.
class _Prepared {
  const _Prepared.file(String this.filePath, {required this.blockedImages})
      : inlineHtml = null;
  const _Prepared.inline(String this.inlineHtml, {required this.blockedImages})
      : filePath = null;

  final String? filePath;
  final String? inlineHtml;
  final bool blockedImages;
}

const _utf8Meta = '<meta charset="utf-8">';

/// Any `<meta>` that declares an encoding, in either spelling: the HTML5
/// `<meta charset=...>` and the older `<meta http-equiv="Content-Type"
/// content="text/html; charset=...">`. Both put `charset=` inside the tag, so
/// one pattern covers them.
final _charsetMeta =
    RegExp(r'<meta\b[^>]*charset\s*=[^>]*>', caseSensitive: false);

final _headOpen = RegExp(r'<head\b[^>]*>', caseSensitive: false);

/// Makes [html] declare the encoding it is actually in.
///
/// Whatever charset a part arrived in, what reaches the webview is UTF-8: the
/// body is a Dart string long before it gets here, and both delivery routes
/// encode it as UTF-8 ([InlineAttachmentCache.writeDocument] and WebView2's
/// `NavigateToString`). Neither route carries a `Content-Type` header — a
/// `file:` URL has none — so the engine believes the document's own
/// declaration, and Outlook routinely leaves a stale `charset=Windows-1252`
/// meta in a body it then sent as UTF-8. Every multi-byte character is then
/// rendered as its individual UTF-8 bytes: `haven’t` becomes `havenâ€™t`.
///
/// So the sender's declaration has to be removed rather than overridden — the
/// encoding prescan takes the *first* declaration it finds, and ours would
/// lose. Note the prescan also only reads the first 1024 bytes, which is why
/// ours goes at the top of the head and not alongside the injected styles: a
/// mail-sized `<style>` block is more than enough to push it out of range, and
/// a declaration the prescan misses falls back to the OS locale default —
/// Windows-1252 on a Western Windows install, i.e. the same mojibake.
@visibleForTesting
String forceUtf8Charset(String html) {
  final stripped = html.replaceAll(_charsetMeta, '');
  final headOpen = _headOpen.firstMatch(stripped);
  if (headOpen != null) {
    return stripped.replaceRange(headOpen.end, headOpen.end, _utf8Meta);
  }
  // Implicit head. A meta ahead of `<html>` is still hoisted into the head by
  // the parser, and the prescan reads bytes rather than the tree, so this
  // works the same. A body with no head at all is handled by the caller, which
  // builds the head it wraps the fragment in.
  return stripped.contains('</head>') ? '$_utf8Meta$stripped' : stripped;
}

/// The reading pane's Content-Security-Policy.
///
/// **This is what actually holds a remote request back**, and it has to be,
/// because [blockExternalImages] can only rewrite what it can recognise as an
/// image element. A mail body reaches a remote host by at least seven other
/// routes — `style="background:url(…)"`, a `<style>` block's `@import`, an
/// `@font-face`, a `srcset`, a `<video poster>`, a `<link rel=stylesheet>`, an
/// `<iframe>` — and every one of them is an open-tracking pixel and an IP
/// disclosure with the reader's blocking switched on. Rewriting each in turn
/// would be a parser written in regular expressions; naming the *schemes* a
/// subresource may come from is one line and cannot be got round.
///
/// So the element rewriting is now only about what the reader *sees*: a held
/// back `<img>` leaves a chip instead of a broken-image glyph, and the status
/// bar can offer to fetch it. A CSS background that never loads leaves nothing
/// to draw, so the policy alone is the whole of it.
///
/// [allowExternal] is the reader's "Download once"/"Always download" decision.
/// It reopens `img-src`, and with it fonts, media and stylesheets: those are
/// the same trade the reader just made, and a stylesheet that cannot load
/// takes the message's layout with it. Four directives are *not* negotiable:
///
/// * `script-src`/`object-src` — a mail body has no business executing, at any
///   setting.
/// * `frame-src` — an `<iframe>` is a document this policy does not govern. It
///   runs its own script under its own origin, and in WKWebView a subframe can
///   reach the host's `messageHandlers` bridge. Both webmail providers strip
///   iframes outright; this refuses to fetch them, which is the same answer
///   with the frame left visible as an empty box.
/// * `base-uri` — a `<base href="https://…">` re-points every *relative* URL
///   in the document, and the inline images of a message delivered as a file
///   are referenced relatively. That turns the sender's own attachments into a
///   call home.
@visibleForTesting
String contentSecurityPolicy({required bool allowExternal}) {
  // `data:` for the inline attachments and the held-back image's pixel, `file:`
  // for the same images when the document is delivered as a file on disk. Not
  // `'self'`: a `file:` document's origin is opaque, so `'self'` matches
  // nothing there — which would hold back the message's own inline images.
  const local = 'data: file:';
  final remote = allowExternal ? ' https: http:' : '';
  return "default-src 'none'; "
      "script-src 'none'; "
      "object-src 'none'; "
      "frame-src 'none'; "
      "child-src 'none'; "
      "connect-src 'none'; "
      "base-uri 'none'; "
      "style-src 'unsafe-inline'$remote; "
      'img-src $local$remote; '
      'font-src $local$remote; '
      'media-src $local$remote;';
}

final _leadingDoctype =
    RegExp(r'^\s*<!doctype\b[^>]*>', caseSensitive: false);

/// Puts the reading pane's Content-Security-Policy ahead of anything the
/// sender wrote.
///
/// **A meta policy only governs what is parsed after it.** Spliced in before
/// `</head>` — alongside the injected styles, where it used to be — it arrives
/// after the sender's own head, so a `<script>` in there had already run: on
/// desktop, where the webview has script enabled, with the page's bridge to
/// the host in reach. So it goes at the very start of the document instead,
/// which is the only position that covers a script the sender put *before*
/// `<head>` as well: that is malformed, the parser hoists it into an implicit
/// head, and a policy sitting after the literal `<head>` would lose to it.
///
/// Two things about the position:
///
/// * **Behind a leading doctype, never in front of it.** Anything before the
///   doctype makes the parser ignore it and render the document in quirks
///   mode, which changes how a mail body's tables lay out — a rendering
///   regression across most of the mail people read, in exchange for nothing.
/// * **Ahead of `<html>` is fine.** The parser hoists a leading meta into an
///   implicit head, and the sender's own `<head>` start tag is then ignored
///   while its contents still land there. Same property [forceUtf8Charset]
///   relies on.
///
/// The injected *styles* deliberately stay at the end of the head. They are
/// `!important` throughout, and at equal specificity the later `!important`
/// declaration wins — hoisting them in front of the sender's stylesheet would
/// hand a sender's `img { width: 600px !important }` the argument over the
/// `max-width` clamp — and over the held-back image's own chip styling.
@visibleForTesting
String installContentSecurityPolicy(String html,
    {required bool allowExternal}) {
  final at = _leadingDoctype.firstMatch(html)?.end ?? 0;
  return html.replaceRange(
    at,
    at,
    '<meta http-equiv="Content-Security-Policy" '
    'content="${contentSecurityPolicy(allowExternal: allowExternal)}">',
  );
}

/// An image this small in either declared dimension is an open-tracking pixel
/// or a layout spacer rather than content, so it is held back without leaving
/// a placeholder — a mailing-list message carries several and each one would
/// otherwise become a stray box in the middle of the text.
const _spacerImagePx = 3;

final _imgTag = RegExp(r'<img\b([^>]*)>', caseSensitive: false);

final _imgHttpSrc = RegExp(
  r'''src=(["'])(https?://[^"']+)\1|src=(https?://[^\s>'"]+)''',
  caseSensitive: false,
);

final _sourceTag = RegExp(r'<source\b([^>]*)>', caseSensitive: false);

/// A `srcset` (or a `<source>`'s `src`) naming at least one remote candidate.
/// The lookbehind keeps the pattern off the `data-blocked-src` a moment-earlier
/// rewrite just wrote, which still holds the remote URL.
/// The whole attribute goes: a candidate list is a set of alternatives for one
/// image, so keeping the local ones and dropping the rest would change which
/// picture the message shows.
final _remoteCandidateAttr = RegExp(
  r'''(?<![\w-])(srcset|imagesrcset|src)=(?:(["'])([^"']*https?://[^"']*)\2'''
  r'''|(https?://[^\s>'"]+))''',
  caseSensitive: false,
);

/// A remote subresource that is *not* an image element: a CSS background or
/// `@font-face`, an `@import`, a `<link rel=stylesheet>`, a `<video poster>`.
/// Each is a tracking pixel by another name, and the policy is what refuses
/// them — this only decides whether the status bar admits to it, so that
/// "Download once" is offered for a message whose only remote content is a
/// background image.
final _remoteSubresource = RegExp(
  r'''url\(\s*['"]?\s*https?://'''
  r'''|<link\b[^>]*\bhref\s*=\s*['"]?\s*https?://'''
  r'''|\bposter\s*=\s*['"]?\s*https?://''',
  caseSensitive: false,
);

/// A numeric `width=`/`height=` attribute. The lookbehind keeps it off
/// `data-width=`, and requiring `=` keeps it off the `max-width:` inside a
/// `style` attribute.
final _imgDimension = RegExp(
  r'''(?<![\w-])(?:width|height)\s*=\s*(?:"(\d+)"|'(\d+)'|(\d+))''',
  caseSensitive: false,
);

bool _isSpacerImage(String attrs) {
  for (final m in _imgDimension.allMatches(attrs)) {
    final px = int.tryParse(m[1] ?? m[2] ?? m[3]!);
    if (px != null && px <= _spacerImagePx) return true;
  }
  return false;
}

/// A 1x1 transparent GIF, substituted for the `src` that was held back.
///
/// Leaving the element with no `src` at all is what it looks like it should do,
/// and it is wrong: the engine then treats the image as broken and draws its
/// own glyph plus the sender's `alt` text over our placeholder, spilling out of
/// a small box. An image that *loads* draws neither, so the placeholder is
/// whatever the stylesheet says it is.
const _blockedImagePixel =
    'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';

/// Renames the `src` of every remote image to `data-blocked-src` so the webview
/// never requests it, and reports whether anything was held back.
///
/// The attribute is renamed rather than removed because "Download once" has to
/// be able to put it back, and because the injected stylesheet keys the
/// placeholder off it. The marker for a spacer goes in *front* of the
/// attributes: a self-closing `<img ... />` would otherwise get it after the
/// slash, which is not an attribute at all.
@visibleForTesting
(String, bool) blockExternalImages(String html) {
  var blockedAny = false;

  var out = html.replaceAllMapped(_imgTag, (imgMatch) {
    final attrs = imgMatch.group(1)!;
    var blockedHere = false;
    var rewritten = attrs.replaceFirstMapped(_imgHttpSrc, (sm) {
      blockedHere = true;
      final quote = sm.group(1);
      final held = quote != null
          ? 'data-blocked-src=$quote${sm.group(2)}$quote'
          : 'data-blocked-src=${sm.group(3)}';
      return 'src="$_blockedImagePixel" $held';
    });
    // A candidate list outranks `src`, so leaving it would put a request the
    // policy then refuses in front of the substituted pixel — and the reader
    // would get the broken-image glyph the pixel exists to avoid. An image
    // that carried *only* a srcset needs the pixel adding.
    final srcsetHeld = _holdBackCandidates(rewritten);
    if (srcsetHeld != null) {
      rewritten = blockedHere ? srcsetHeld : ' src="$_blockedImagePixel"$srcsetHeld';
      blockedHere = true;
    }
    if (!blockedHere) return imgMatch.group(0)!;
    blockedAny = true;
    return _isSpacerImage(attrs)
        ? '<img data-blocked-spacer$rewritten>'
        : '<img$rewritten>';
  });

  // A `<picture>`'s `<source>` is chosen ahead of the `<img>` inside it, so a
  // remote candidate there decides the whole element. Held back, the `<img>`
  // fallback applies — which is the one already carrying the chip.
  out = out.replaceAllMapped(_sourceTag, (m) {
    final held = _holdBackCandidates(m.group(1)!);
    if (held == null) return m.group(0)!;
    blockedAny = true;
    return '<source$held>';
  });

  // Everything the policy refuses that no rewriting can leave a chip for.
  return (out, blockedAny || _remoteSubresource.hasMatch(out));
}

/// Renames every remote candidate attribute in [attrs] out of the way,
/// returning the rewritten attributes — or null if there was nothing remote.
String? _holdBackCandidates(String attrs) {
  var held = false;
  final out = attrs.replaceAllMapped(_remoteCandidateAttr, (m) {
    held = true;
    final name = m.group(1)!;
    final quote = m.group(2);
    return quote != null
        ? 'data-blocked-$name=$quote${m.group(3)}$quote'
        : 'data-blocked-$name=${m.group(4)}';
  });
  return held ? out : null;
}

class HtmlBodyView extends StatefulWidget {
  const HtmlBodyView({
    super.key,
    required this.html,
    required this.inlineAttachments,
    required this.senderDomain,
    required this.cacheKey,
    this.onControllerReady,
  });
  final String html;
  final List<InlineAttachment> inlineAttachments;
  final String senderDomain;

  /// Identifies this body in [InlineAttachmentCache] — the email id. Cached
  /// files are dropped when the email leaves the local cache.
  final String cacheKey;
  final void Function(HtmlViewController)? onControllerReady;

  @override
  State<HtmlBodyView> createState() => _HtmlBodyViewState();
}

class _HtmlBodyViewState extends State<HtmlBodyView> {
  // Desktop (Windows / macOS / Linux): html_view overlay WebView.
  HtmlViewController? _htmlController;
  StreamSubscription<String>? _linkSub;
  StreamSubscription<String>? _linkHoverSub;
  StreamSubscription<String>? _imageSub;
  StreamSubscription<void>? _clickFocusSub;
  // Tracks the latest prepared document so _initHtmlView can apply an update
  // that arrived while the controller was still initialising.
  _Prepared? _pending;

  // Mobile (Android / iOS): webview_flutter.
  WebViewController? _flutterController;

  bool _allowExternalImages = false;
  bool _hasBlockedImages = false;
  bool _disposed = false;
  String? _loadError;

  /// URL of the link the pointer is over, shown in the [BodyStatusBar] with a
  /// copy button. Deliberately kept once the pointer leaves the link: the copy
  /// button is below the body, so clearing on mouse-out would take the URL away
  /// while the reader is on their way to it — and it would also mean resizing
  /// the webview (and reflowing the message) on every link crossed rather than
  /// once per message. Cleared when a different message loads.
  String? _hoveredLink;

  /// Guards against an out-of-order `_prepare` — preparing is async now, so a
  /// fast "Download once" tap can otherwise land behind the initial build.
  int _loadSeq = 0;

  static bool get _isDesktop =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  @override
  void initState() {
    super.initState();
    if (_isDesktop) {
      _initHtmlView();
    } else {
      _initFlutter();
    }
    _reloadWith(allowExternal: false);
    _loadAlwaysAllowSetting();
  }

  Future<void> _initHtmlView() async {
    final ctrl = HtmlViewController();
    await ctrl.initialize();
    if (_disposed) { unawaited(ctrl.dispose()); return; }
    _linkSub = ctrl.onLinkOpened.listen((url) {
      if (mounted) unawaited(openBodyLink(context, url));
    });
    // An empty URL means the pointer left a link — see [_hoveredLink].
    _linkHoverSub = ctrl.onLinkHovered.listen((url) {
      if (url.isEmpty || url == _hoveredLink || !mounted) return;
      setState(() => _hoveredLink = url);
    });
    _imageSub = ctrl.onImageDoubleClicked.listen(_openImageWindow);
    // A click inside the WKWebView/WebView2 overlay is a native OS focus
    // steal that never reaches Flutter's own FocusNode tree, so without this
    // native cmd/ctrl+C never routes to the webview: the reading pane's own
    // widgets (or nothing) stay firstResponder/focused and the Edit-menu
    // Copy item has no selection to act on. Drop Flutter's focus first, then
    // grant native focus — same order html_email_editor.dart uses, since
    // granting native focus before Flutter unfocuses can be undone by
    // Flutter's text input plugin reasserting itself.
    _clickFocusSub = ctrl.onClickFocus.listen((_) {
      if (!mounted) return;
      FocusManager.instance.primaryFocus?.unfocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(ctrl.focus());
      });
    });
    setState(() => _htmlController = ctrl);
    widget.onControllerReady?.call(ctrl);
    final pending = _pending;
    if (pending != null) _dispatch(pending);
  }

  void _initFlutter() {
    _flutterController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          final scheme = Uri.tryParse(request.url)?.scheme.toLowerCase() ?? '';
          if (scheme == 'http' || scheme == 'https' || scheme == 'mailto') {
            if (mounted) unawaited(openBodyLink(context, request.url));
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ));
  }

  Future<void> _loadAlwaysAllowSetting() async {
    final domains = await sl<AppSettings>().loadExternalImageDomains();
    if (!mounted || !domains.contains(widget.senderDomain)) return;
    _reloadWith(allowExternal: true);
  }

  @override
  void didUpdateWidget(HtmlBodyView old) {
    super.didUpdateWidget(old);
    // listEquals, not `!=`: a Dart List compares by identity, so a repaint
    // holding a re-read copy of the same message counted as a new email —
    // which re-blocks the images the reader has just chosen to download, and
    // reloads the webview under them, losing their scroll position.
    final emailChanged = old.html != widget.html ||
        old.cacheKey != widget.cacheKey ||
        !listEquals(old.inlineAttachments, widget.inlineAttachments);
    final senderChanged = old.senderDomain != widget.senderDomain;
    // A hovered link belongs to the message it was in. Reloading the *same*
    // message (an image download) keeps it.
    if (emailChanged) _hoveredLink = null;
    if (emailChanged || senderChanged) {
      _reloadWith(allowExternal: false);
      _loadAlwaysAllowSetting();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _linkSub?.cancel();
    _linkHoverSub?.cancel();
    _clickFocusSub?.cancel();
    _imageSub?.cancel();
    unawaited(_htmlController?.dispose());
    super.dispose();
  }

  /// Pops the double-clicked image out into its own resizable window.
  void _openImageWindow(String src) {
    if (src.isEmpty) return;
    unawaited(createSubWindow(
      WindowConfiguration(
        arguments: jsonEncode({'type': 'imageView', 'src': src}),
      ),
    ));
  }

  void _reloadWith({required bool allowExternal}) {
    if (_disposed) return;
    final seq = ++_loadSeq;
    unawaited(() async {
      final prepared = await _prepare(allowExternal: allowExternal);
      // A newer reload started while we were writing files — drop this one.
      if (_disposed || seq != _loadSeq) return;
      _pending = prepared;
      if (mounted) {
        setState(() {
          _allowExternalImages = allowExternal;
          _hasBlockedImages = prepared.blockedImages;
          _loadError = null;
        });
      }
      _dispatch(prepared);
    }());
  }

  /// Hands [prepared] to whichever webview backs this platform. Failures are
  /// surfaced rather than swallowed: an unawaited `loadHtml` that rejects
  /// leaves the overlay blank with nothing to explain it.
  void _dispatch(_Prepared prepared) {
    if (_isDesktop) {
      final ctrl = _htmlController;
      // Not initialised yet — _initHtmlView loads _pending when it finishes.
      if (ctrl == null) return;
      final path = prepared.filePath;
      final future = path != null
          ? ctrl.loadUrl(Uri.file(path).toString())
          : ctrl.loadHtml(prepared.inlineHtml!);
      unawaited(future.catchError((Object e) => _onLoadFailed(e)));
    } else {
      final ctrl = _flutterController;
      if (ctrl == null) return;
      final path = prepared.filePath;
      final future = path != null
          ? ctrl.loadFile(path)
          : ctrl.loadHtmlString(prepared.inlineHtml!);
      unawaited(future.catchError((Object e) => _onLoadFailed(e)));
    }
  }

  void _onLoadFailed(Object error) {
    debugPrint('HtmlBodyView: load failed: $error');
    if (!mounted) return;
    setState(() => _loadError = 'This message could not be displayed.');
  }

  void _downloadOnce() => _reloadWith(allowExternal: true);

  Future<void> _alwaysDownload() async {
    await sl<AppSettings>().saveExternalImageDomain(widget.senderDomain);
    if (mounted) _reloadWith(allowExternal: true);
  }

  /// Resolves `cid:` references, blocks external images and injects our own
  /// styles, then decides how the result should reach the webview.
  ///
  /// Preferred route on desktop is a file on disk: the inline images are
  /// written once by [InlineAttachmentCache] and referenced by relative name,
  /// which keeps the document tiny. Loading a multi-megabyte string instead
  /// fails outright on Windows — WebView2's `NavigateToString` caps at 2 MB —
  /// and costs a 33% base64 penalty everywhere else. Falls back to inlining as
  /// `data:` URLs if the cache is unusable (read-only temp dir, disk full).
  Future<_Prepared> _prepare({required bool allowExternal}) async {
    final attachments = widget.inlineAttachments;

    Map<String, String>? fileNames;
    if (_isDesktop && attachments.isNotEmpty) {
      fileNames = await sl<InlineAttachmentCache>().materialize(
        cacheKey: widget.cacheKey,
        attachments: attachments,
      );
    }

    final (body, blocked) = _composeHtml(
      allowExternal: allowExternal,
      // `file:` URLs into the cache directory, or — when the cache is
      // unavailable, or on mobile — the bytes inlined as before.
      cidReplacements: fileNames ?? _dataUrlReplacements(attachments),
    );

    // Images on disk only resolve from a document loaded off disk, and any
    // document too large for NavigateToString has to go to disk regardless.
    final needsFile = fileNames != null ||
        (_isDesktop &&
            utf8.encode(body).length >=
                InlineAttachmentCache.maxInlineDocumentBytes);
    if (needsFile) {
      final path = await sl<InlineAttachmentCache>()
          .writeDocument(cacheKey: widget.cacheKey, html: body);
      if (path != null) return _Prepared.file(path, blockedImages: blocked);
      if (fileNames != null) {
        // The images were written but the document was not. Retry inline so
        // the message still renders, size permitting.
        final (inline, inlineBlocked) = _composeHtml(
          allowExternal: allowExternal,
          cidReplacements: _dataUrlReplacements(attachments),
        );
        return _Prepared.inline(inline, blockedImages: inlineBlocked);
      }
    }
    return _Prepared.inline(body, blockedImages: blocked);
  }

  /// `cid` token -> base64 `data:` URL, the pre-cache behaviour, kept as the
  /// mobile path and as the desktop fallback.
  static Map<String, String> _dataUrlReplacements(
    List<InlineAttachment> attachments,
  ) {
    final map = <String, String>{};
    for (final attachment in attachments) {
      final cid = attachment.contentId;
      final bare = cid.startsWith('<') && cid.endsWith('>')
          ? cid.substring(1, cid.length - 1)
          : cid;
      final dataUrl = 'data:${attachment.contentType};base64,'
          '${base64Encode(attachment.contentBytes)}';
      map[bare] = dataUrl;
      // Gmail may set Content-ID to `<ii_x@mail.gmail.com>` while the body
      // references only `cid:ii_x`; map the local part too.
      final at = bare.indexOf('@');
      if (at != -1) map[bare.substring(0, at)] = dataUrl;
    }
    return map;
  }

  (String, bool) _composeHtml({
    required bool allowExternal,
    required Map<String, String> cidReplacements,
  }) {
    // Ahead of the cid substitution, so the scan is over the sender's body
    // rather than over the same body with every inline image expanded into it.
    final body = linkifyHtml(widget.html);

    // One pass over the body. Substituting per attachment instead rescans the
    // whole (already-expanded) document once per image — quadratic, and
    // painful once the document is megabytes of base64.
    var resolved = cidReplacements.isEmpty
        ? body
        : body.replaceAllMapped(
            RegExp('''cid:([^"'\\s>)]+)''', caseSensitive: false),
            (m) => cidReplacements[m.group(1)!] ?? m.group(0)!,
          );

    bool hasBlockedImages = false;
    if (!allowExternal) {
      (resolved, hasBlockedImages) = blockExternalImages(resolved);
    }

    const injected = '''
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0">
<style>
* { box-sizing: border-box !important; }
body {
  margin: 0;
  padding: 20px 28px 40px;
  overflow-wrap: anywhere;
  word-wrap: break-word;
}
img { max-width: 100% !important; height: auto !important; }
/* A held-back image leaves a placeholder rather than vanishing. Hiding it
   outright loses the message: a body whose content *is* its images — a rating
   widget, a receipt, a newsletter — renders as an empty box with nothing to
   say anything is missing, and the only hint is a 29px strip below the body
   that the reader has no reason to look at.
   One fixed chip per image, not the sender's declared box: the substituted
   pixel is square, so honouring a declared width would give a 600px banner a
   600px-tall hole. */
img[data-blocked-src] {
  width: 24px !important;
  height: 24px !important;
  border: 1px dashed #c4c7cc !important;
  border-radius: 3px !important;
  background: #f3f4f6 url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23a0a4ab' stroke-width='1.7' stroke-linecap='round' stroke-linejoin='round'%3E%3Crect x='3' y='4' width='18' height='16' rx='2'/%3E%3Ccircle cx='8.7' cy='9.6' r='1.4'/%3E%3Cpath d='m20.5 15.5-4.7-4.7L5 21.5'/%3E%3C/svg%3E") center / 15px 15px no-repeat !important;
}
img[data-blocked-spacer] { display: none !important; }
pre {
  white-space: pre-wrap !important;
  word-wrap: break-word !important;
  overflow-wrap: anywhere !important;
}
table { max-width: 100% !important; }
@media only screen and (max-width: 650px) {
  table { width: 100% !important; }
  td, th { width: auto !important; min-width: 0 !important; }
}
</style>
''';
    resolved = forceUtf8Charset(resolved);

    final headEnd = resolved.indexOf('</head>');
    if (headEnd != -1) {
      resolved = resolved.substring(0, headEnd) +
          injected +
          resolved.substring(headEnd);
    } else {
      // A bare fragment — no head of its own to have declared anything.
      resolved =
          '<html><head>$_utf8Meta$injected</head><body>$resolved</body></html>';
    }

    // Last, so it covers both branches — and, in the fragment branch, so it
    // lands ahead of the `<html>` the fragment was wrapped in rather than
    // inside the head that was built for it.
    resolved =
        installContentSecurityPolicy(resolved, allowExternal: allowExternal);

    return (resolved, hasBlockedImages);
  }

  @override
  Widget build(BuildContext context) {
    final error = _loadError;
    if (error != null) return _LoadErrorPanel(message: error);

    final Widget webviewWidget;
    if (_isDesktop) {
      final ctrl = _htmlController;
      webviewWidget = ctrl != null
          ? HtmlViewWidget(controller: ctrl)
          : const SizedBox.shrink();
    } else {
      final ctrl = _flutterController;
      webviewWidget = ctrl != null
          ? WebViewWidget(controller: ctrl)
          : const SizedBox.shrink();
    }

    return Column(
      children: [
        Expanded(child: webviewWidget),
        BodyStatusBar(
          hoveredLink: _hoveredLink,
          imagesBlocked: _hasBlockedImages && !_allowExternalImages,
          onDownloadOnce: _downloadOnce,
          onAlwaysDownload: _alwaysDownload,
        ),
      ],
    );
  }
}

class _LoadErrorPanel extends StatelessWidget {
  const _LoadErrorPanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 28, color: c.textMuted),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textMuted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
