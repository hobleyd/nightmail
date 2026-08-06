import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:html_view/html_view.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/platform/window_utils.dart';
import '../../core/settings/app_settings.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/linkify.dart';
import '../../data/services/inline_attachment_cache.dart';
import '../../domain/entities/inline_attachment.dart';
import '../../injection_container.dart';
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
      final uri = Uri.tryParse(url);
      if (uri != null) unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
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
          final uri = Uri.tryParse(request.url);
          final scheme = uri?.scheme ?? '';
          if (scheme == 'http' || scheme == 'https' || scheme == 'mailto') {
            launchUrl(uri!, mode: LaunchMode.externalApplication);
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
    final emailChanged = old.html != widget.html ||
        old.cacheKey != widget.cacheKey ||
        old.inlineAttachments != widget.inlineAttachments;
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
      resolved = resolved.replaceAllMapped(
        RegExp(r'<img\b([^>]*)>', caseSensitive: false),
        (imgMatch) {
          final attrs = imgMatch.group(1)!;
          final newAttrs = attrs.replaceFirstMapped(
            RegExp(
              r'''src=(["'])(https?://[^"']+)\1|src=(https?://[^\s>'"]+)''',
              caseSensitive: false,
            ),
            (sm) {
              hasBlockedImages = true;
              if (sm.group(1) != null) {
                return 'data-blocked-src=${sm.group(1)}${sm.group(2)}${sm.group(1)}';
              } else {
                return 'data-blocked-src=${sm.group(3)}';
              }
            },
          );
          return '<img$newAttrs>';
        },
      );
    }

    const injected = '''
<meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none';">
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
img[data-blocked-src] { display: none !important; }
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
