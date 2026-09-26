import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:html_view/html_view.dart';
import 'package:webview_flutter/webview_flutter.dart';

class HtmlEmailEditor extends StatefulWidget {
  const HtmlEmailEditor({
    super.key,
    required this.initialHtml,
    required this.onContentChanged,
    required this.onLinkRequested,
    required this.onAttachRequested,
    this.onImagePasted,
    this.onClickFocus,
    this.onOverscroll,
    this.enableScrollHandoff = false,
    this.autofocus = false,
  });

  final String initialHtml;
  final ValueChanged<String> onContentChanged;
  /// Called when the user taps the link button in the editor toolbar.
  /// The caller should prompt for a URL and call [insertLink].
  final VoidCallback onLinkRequested;
  /// Called when the user taps the paperclip button in the editor toolbar.
  /// The caller should open a file picker and attach the selected files.
  final VoidCallback onAttachRequested;
  /// Called when the user pastes an image into the editor. The argument is a
  /// `data:` URL of the pasted image; the caller should register it as an
  /// inline attachment and insert it via [insertImage].
  final ValueChanged<String>? onImagePasted;
  /// Called when a raw click forces native OS focus onto the editor. The
  /// caller should drop focus from whatever Flutter field currently has it
  /// (e.g. `FocusManager.instance.primaryFocus?.unfocus()`), since a native
  /// focus steal doesn't otherwise reach Flutter's own FocusNode tree.
  final VoidCallback? onClickFocus;
  /// Raised while a finger drag inside the editor's own scrollable content
  /// hits the top or bottom of it and keeps moving the same way — the editor
  /// has nowhere further to scroll, so the value is the drag's pixel delta
  /// (positive: finger moved down) for the caller to apply to whatever
  /// scroll view hosts this editor instead. Mobile-only; the desktop backend
  /// never raises it. Only fires when [enableScrollHandoff] is true.
  final ValueChanged<double>? onOverscroll;
  /// Lets the page's own touchmove handler take over a drag once it reaches
  /// either end of the editor's content, rather than letting the drag simply
  /// stop there. Only the caller that embeds this editor inside another
  /// scroll view (the mobile compose layout) knows there is somewhere for
  /// that drag to go — the signature editors in Settings and Out of Office
  /// don't, and default to leaving the boundary alone.
  final bool enableScrollHandoff;
  /// Focuses the editor as soon as its content finishes loading. The webview
  /// loads asynchronously, so this can't be done with a synchronous
  /// `requestFocus()` call from the parent the way the plain-text body works.
  final bool autofocus;

  @override
  State<HtmlEmailEditor> createState() => HtmlEmailEditorState();
}

class HtmlEmailEditorState extends State<HtmlEmailEditor> with WidgetsBindingObserver {
  late final _EditorHost _host;

  String _pendingHtml = '';
  bool   _disposed    = false;
  bool   _keyboardVisible = false;

  /// The desktop editor is `html_view`'s native webview, a sibling view laid
  /// over the Flutter surface and positioned by hand; a phone gets
  /// `webview_flutter`'s platform view instead, which is composited into the
  /// Flutter tree like any other widget — the same split as `HtmlBodyView`.
  /// The overlay cannot work on mobile: it is placed once, from a position
  /// read mid page-transition, and sits above every dialog and sheet.
  static bool get _isDesktop =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  @override
  void initState() {
    super.initState();
    _pendingHtml = widget.initialHtml;
    _host = _isDesktop
        ? _NativeOverlayHost(onEvent: _onHostEvent)
        : _PlatformViewHost(onEvent: _onHostEvent);
    _host.load('assets/editor/editor.html');
    WidgetsBinding.instance.addObserver(this);
  }

  // WKWebView freezes `#editor-scroll`'s own touch-driven scrolling for as
  // long as the on-screen keyboard is up and this page holds the caret —
  // measured directly: dragging inside the editor with the keyboard open
  // never moves its `scrollTop` off 0, no matter how far the drag goes, while
  // the identical drag scrolls normally the moment the keyboard is dismissed.
  // `editor.html`'s touchmove handler drives the scroll itself via JS while
  // the keyboard is visible rather than relying on the browser's own (here,
  // inert) touch-scroll physics for that state.
  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final visible = View.of(context).viewInsets.bottom > 0;
    if (visible == _keyboardVisible) return;
    _keyboardVisible = visible;
    unawaited(_host.run('setKeyboardVisible($visible)'));
  }

  /// Every event either backend can raise, named as the page raises them —
  /// `editor.html`'s `_flutterNotify(name, value)` posts to `window[name]`.
  void _onHostEvent(String type, String value) {
    if (_disposed || !mounted) return;
    switch (type) {
      case 'onContentChanged':
        widget.onContentChanged(value);
      case 'onLinkRequest':
        widget.onLinkRequested();
      case 'onAttachRequest':
        widget.onAttachRequested();
      case 'onImagePasted':
        widget.onImagePasted?.call(value);
      case 'onOverscroll':
        widget.onOverscroll?.call(double.tryParse(value) ?? 0);
      case 'onClickFocus':
        // Unfocus the Flutter side first — calling focus() (native
        // makeFirstResponder) before this can otherwise be undone when
        // Flutter's text input plugin reasserts itself as firstResponder
        // while resigning the old field.
        widget.onClickFocus?.call();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) focus();
        });
      case 'pageLoaded':
        unawaited(_onPageLoaded());
    }
  }

  Future<void> _onPageLoaded() async {
    if (_pendingHtml.isNotEmpty) {
      await _host.run('setContent(${jsonEncode(_pendingHtml)})');
    }
    if (widget.enableScrollHandoff) {
      await _host.run('setScrollHandoffEnabled(true)');
    }
    // `didChangeMetrics` only reports a *transition*, so if the keyboard is
    // already up when this page finishes loading — the user was in the
    // Subject field and tapped straight into the body — no transition ever
    // fires and the page never learns the keyboard is visible. Read the
    // current state directly instead of waiting for one.
    if (mounted) {
      _keyboardVisible = View.of(context).viewInsets.bottom > 0;
      if (_keyboardVisible) {
        await _host.run('setKeyboardVisible(true)');
      }
    }
    if (widget.autofocus && !_disposed) {
      await focus();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _host.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Public API (called by compose_dialog.dart)
  // -------------------------------------------------------------------------

  Future<void> hide() => _host.setVisible(false);
  Future<void> show() => _host.setVisible(true);

  Future<void> setContent(String html) async {
    _pendingHtml = html;
    await _host.run('setContent(${jsonEncode(html)})');
  }

  Future<String> getContent() async {
    final raw = await _host.evalString('getContent()');
    if (raw == null || raw == 'null') return _pendingHtml;
    // The desktop bridge and Android hand a string back JSON-encoded
    // ("\"<div>…\"") and WKWebView hands it back bare, so decode when that
    // works and take it as it is when it doesn't.
    try {
      final decoded = jsonDecode(raw);
      return decoded is String ? decoded : raw;
    } catch (_) {
      return raw;
    }
  }

  Future<void> insertImage(String dataUri, String contentId) async {
    await _host.run(
        'insertImage(${jsonEncode(dataUri)}, ${jsonEncode(contentId)})');
  }

  Future<void> insertLink(String url) async {
    await _host.run('insertLink(${jsonEncode(url)})');
  }

  Future<void> saveSelection() async {
    await _host.run('saveSelection()');
  }

  Future<void> insertAtCursor(String text) async {
    await _host.run('insertAtSaved(${jsonEncode(text)})');
  }

  Future<void> focus() async {
    // OS focus first (so the WebView2 HWND actually receives keystrokes),
    // then the DOM-level focus that places the caret in the editor.
    await _host.focus();
    await _host.run('focusEditor()');
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) => _host.build(context);
}

// ---------------------------------------------------------------------------
// Backends
// ---------------------------------------------------------------------------

typedef _HostEvent = void Function(String type, String value);

/// What the editor needs from whichever webview is drawing it.
abstract class _EditorHost {
  /// Loads the editor page. Events, including `pageLoaded`, arrive through
  /// the callback the host was built with.
  void load(String assetKey);

  /// Runs [js] for its effect.
  Future<void> run(String js);

  /// Runs [js] and returns what it evaluated to, as the backend spells it.
  Future<String?> evalString(String js);

  /// Gives the webview OS-level keyboard focus, where that is a separate step
  /// from focusing an element in the page.
  Future<void> focus();

  /// Hides the webview while something Flutter draws has to appear above it.
  /// A no-op where the webview is composited into the Flutter tree.
  Future<void> setVisible(bool visible);

  Widget build(BuildContext context);
  void dispose();
}

/// Desktop: `html_view`'s native webview, laid over the Flutter surface.
class _NativeOverlayHost implements _EditorHost {
  _NativeOverlayHost({required this.onEvent});

  final _HostEvent onEvent;
  final HtmlViewController _controller = HtmlViewController();
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _disposed = false;

  @override
  void load(String assetKey) {
    _controller.initialize().then((_) {
      if (_disposed) return;
      _subs.addAll([
        _controller.onContentChanged
            .listen((html) => onEvent('onContentChanged', html)),
        _controller.onLinkRequest.listen((_) => onEvent('onLinkRequest', '')),
        _controller.onAttachRequested
            .listen((_) => onEvent('onAttachRequest', '')),
        _controller.onImagePasted
            .listen((uri) => onEvent('onImagePasted', uri)),
        _controller.onClickFocus.listen((_) => onEvent('onClickFocus', '')),
        _controller.onPageLoaded.listen((_) => onEvent('pageLoaded', '')),
      ]);
      _controller.loadAsset(assetKey);
    });
  }

  @override
  Future<void> run(String js) async {
    await _controller.eval(js);
  }

  @override
  Future<String?> evalString(String js) => _controller.eval(js);

  @override
  Future<void> focus() => _controller.focus();

  @override
  Future<void> setVisible(bool visible) => _controller.setVisible(visible);

  @override
  Widget build(BuildContext context) =>
      HtmlViewWidget(controller: _controller);

  @override
  void dispose() {
    _disposed = true;
    for (final sub in _subs) {
      sub.cancel();
    }
    _controller.dispose();
  }
}

/// Android and iOS: `webview_flutter`'s platform view.
///
/// The page is unchanged between backends because `addJavaScriptChannel`
/// defines exactly the `window[name].postMessage` objects the desktop bridge
/// injects by hand.
class _PlatformViewHost implements _EditorHost {
  _PlatformViewHost({required this.onEvent}) {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) => onEvent('pageLoaded', ''),
        // A link tapped inside the message being written must not navigate
        // the editor away from itself.
        onNavigationRequest: (request) {
          final scheme =
              Uri.tryParse(request.url)?.scheme.toLowerCase() ?? '';
          return scheme == 'http' || scheme == 'https' || scheme == 'mailto'
              ? NavigationDecision.prevent
              : NavigationDecision.navigate;
        },
      ));
    for (final name in const [
      'onContentChanged',
      'onLinkRequest',
      'onAttachRequest',
      'onImagePasted',
      'onOverscroll',
    ]) {
      _controller.addJavaScriptChannel(
        name,
        onMessageReceived: (message) => onEvent(name, message.message),
      );
    }
  }

  final _HostEvent onEvent;
  late final WebViewController _controller;
  final ValueNotifier<bool> _visible = ValueNotifier<bool>(true);

  @override
  void load(String assetKey) {
    unawaited(_controller.loadFlutterAsset(assetKey));
  }

  @override
  Future<void> run(String js) async {
    // Not `runJavaScriptReturningResult`: WKWebView reports a statement that
    // evaluates to `undefined` as an error there.
    try {
      await _controller.runJavaScript(js);
    } catch (_) {}
  }

  @override
  Future<String?> evalString(String js) async {
    try {
      final result = await _controller.runJavaScriptReturningResult(js);
      return result.toString();
    } catch (_) {
      return null;
    }
  }

  /// A tap in the page is what raises the keyboard on a phone; there is no
  /// separate OS focus to take, and iOS will not show the keyboard for a
  /// programmatic focus anyway.
  @override
  Future<void> focus() async {}

  /// The platform view is part of the Flutter tree, so an *ordinary* dialog
  /// or sheet pushed above it simply draws on top — true for anything Flutter
  /// paints itself. It is not true for a `BackdropFilter`-blurred surface
  /// (the native-style iOS alert, `AdaptiveAlertDialog`'s Cupertino branch):
  /// the blur samples the *composited* scene, and a hybrid-composition
  /// platform view is composited by the OS outside Flutter's own layer, so
  /// the filter cannot reliably read it — visible on a phone as a patch of
  /// wrong colour behind the alert exactly where the webview sits, but only
  /// while the keyboard has it scrolled into that area. `Offstage` drops the
  /// native view's layer for the frame without disposing the `WebViewController`,
  /// so the alert blurs whatever is *behind* the editor instead (the compose
  /// page, or — inside a modal — the opaque backdrop `AdaptiveAlertDialog`
  /// paints behind the Cupertino surface) and the edited HTML survives the
  /// round trip untouched.
  @override
  Future<void> setVisible(bool visible) async {
    _visible.value = visible;
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: _visible,
        builder: (context, visible, child) =>
            Offstage(offstage: !visible, child: child),
        // `WebViewWidget`'s default `gestureRecognizers` (empty) only lets the
        // platform view handle pointer events the Flutter side hasn't already
        // claimed — and on the mobile compose layout this view sits inside a
        // `SingleChildScrollView`, whose own vertical drag recognizer can win
        // that arena partway through a drag. Measured directly: a drag over
        // the editor only delivered its first handful of `touchmove`s to the
        // page before falling silent for hundreds of ms, independent of any
        // work this page's own handler did — the rest of the gesture had gone
        // to the ancestor scrollable instead, which is what read as "the
        // editor and the page scrolling are interacting". `EagerGestureRecognizer`
        // claims the arena immediately so every drag starting on the editor
        // stays with it for the whole gesture; the editor's own touchmove
        // handler is what forwards a drag to the outer scroll view once it
        // has nowhere further to go (`onOverscroll`), so the outer view isn't
        // losing a way to be scrolled from here — it gains a well-defined one.
        child: WebViewWidget(
          controller: _controller,
          gestureRecognizers: {
            Factory<EagerGestureRecognizer>(() => EagerGestureRecognizer()),
          },
        ),
      );

  @override
  void dispose() {
    _visible.dispose();
  }
}
