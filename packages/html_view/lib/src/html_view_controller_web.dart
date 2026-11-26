// Web-specific HtmlViewController.
// Uses a package:web HTMLIFrameElement + dart:js_interop for same-origin eval.
// Conditionally exported by lib/html_view.dart when dart.library.js_interop is
// present.

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;

class HtmlViewController {
  static int _nextId = 1;

  int? _viewId;
  web.HTMLIFrameElement? _iframe;
  StreamSubscription<web.MessageEvent>? _messageSub;
  StreamSubscription<web.Event>? _loadSub;

  /// Whether the loaded document is a page shown for reading ([loadHtml],
  /// [loadUrl]) rather than the editor ([loadAsset]). Only a reading page gets
  /// the link and image listeners, as only the native reading views report
  /// those events.
  bool _watchPage = false;

  final _onContentChanged = StreamController<String>.broadcast();
  final _onLinkRequest    = StreamController<void>.broadcast();
  final _onPageLoaded     = StreamController<void>.broadcast();
  final _onLinkOpened     = StreamController<String>.broadcast();
  final _onLinkHovered    = StreamController<String>.broadcast();
  final _onAttachRequested    = StreamController<String>.broadcast();
  final _onClickFocus         = StreamController<void>.broadcast();
  final _onImageDoubleClicked = StreamController<String>.broadcast();
  final _onImagePasted        = StreamController<String>.broadcast();

  Stream<String> get onContentChanged => _onContentChanged.stream;
  Stream<void>   get onLinkRequest    => _onLinkRequest.stream;
  Stream<void>   get onPageLoaded     => _onPageLoaded.stream;
  /// A click on an http/https/mailto link in a reading page, whose own
  /// navigation is cancelled, as on the native views.
  Stream<String> get onLinkOpened     => _onLinkOpened.stream;
  /// The hovered link's resolved URL in a reading page, or an empty string
  /// when the pointer moves off one, as on the native views.
  Stream<String> get onLinkHovered    => _onLinkHovered.stream;
  /// The `src` of an image double-clicked in a reading page.
  Stream<String> get onImageDoubleClicked => _onImageDoubleClicked.stream;
  /// Never fire on web: the bridge forwards only onContentChanged and
  /// onLinkRequest, and an iframe takes focus without help. Declared so
  /// callers compile against either implementation.
  Stream<String> get onAttachRequested    => _onAttachRequested.stream;
  Stream<void>   get onClickFocus         => _onClickFocus.stream;
  Stream<String> get onImagePasted        => _onImagePasted.stream;

  bool get isInitialized => _viewId != null;
  int? get viewId => _viewId;

  Future<void> initialize() async {
    final id = _nextId++;
    _viewId = id;

    final iframe = web.HTMLIFrameElement()
      ..style.border = 'none'
      ..style.width  = '100%'
      ..style.height = '100%'
      ..allow = 'clipboard-write';
    _iframe = iframe;

    // Register the factory so HtmlElementView can embed this iframe.
    ui_web.platformViewRegistry.registerViewFactory(
      'html_view_$id',
      (int viewId) => iframe,
    );

    // Every load replaces the document, and the listeners with it.
    _loadSub = iframe.onLoad.listen((_) {
      if (_watchPage) _attachPageListeners();
    });

    // Listen for postMessage events from the iframe.
    _messageSub = web.window.onMessage.listen((event) {
      if (event.source != _iframe?.contentWindow) return;
      final data = event.data.dartify()?.toString();
      if (data == null) return;
      final sep = data.indexOf('\x00');
      if (sep < 0) return;
      final channel = data.substring(0, sep);
      final value   = data.substring(sep + 1);
      switch (channel) {
        case 'onContentChanged':
          _onContentChanged.add(value);
          break;
        case 'onLinkRequest':
          _onLinkRequest.add(null);
          break;
        case 'pageLoaded':
          _onPageLoaded.add(null);
          break;
      }
    });
  }

  Future<void> loadHtml(String html) async {
    _watchPage = true;
    _iframe?.setAttribute('srcdoc', html);
  }

  Future<void> loadUrl(String url) async {
    _watchPage = true;
    _iframe?.src = url;
  }

  Future<void> loadAsset(String assetKey) async {
    _watchPage = false;
    // Flutter web serves assets at assets/<key> relative to app root.
    _iframe?.src = 'assets/$assetKey';
    // Inject bridge after page loads so postMessage works.
    _iframe?.onLoad.first.then((_) => _injectBridge());
  }

  /// Reports link hovers and clicks and image double-clicks in a reading page.
  ///
  /// The listeners are attached from out here rather than injected as script:
  /// a message body's Content-Security-Policy forbids script, and a `srcdoc`
  /// document shares this page's origin, so its DOM is in reach anyway. The
  /// listeners run as this page's code, which that policy doesn't govern.
  /// A `src` document from another origin is out of reach, and reports
  /// nothing.
  void _attachPageListeners() {
    final web.Document? doc;
    try {
      doc = _iframe?.contentDocument;
    } catch (_) {
      return;
    }
    if (doc == null) return;

    var hovered = '';
    doc.addEventListener(
      'mouseover',
      ((web.Event e) {
        final href = _linkAt(e.target)?.href ?? '';
        if (href == hovered) return;
        hovered = href;
        _onLinkHovered.add(href);
      }).toJS,
    );
    doc.addEventListener(
      'click',
      ((web.Event e) {
        final href = _linkAt(e.target)?.href;
        if (href == null) return;
        final scheme = Uri.tryParse(href)?.scheme.toLowerCase();
        if (scheme != 'http' && scheme != 'https' && scheme != 'mailto') {
          return;
        }
        e.preventDefault();
        _onLinkOpened.add(href);
      }).toJS,
    );
    doc.addEventListener(
      'dblclick',
      ((web.Event e) {
        final target = _elementAt(e.target);
        if (target == null || target.tagName.toUpperCase() != 'IMG') return;
        final img = target as web.HTMLImageElement;
        final src = img.currentSrc.isNotEmpty ? img.currentSrc : img.src;
        if (src.isNotEmpty) _onImageDoubleClicked.add(src);
      }).toJS,
    );
  }

  /// [target] as an element, if it is one. Checked by shape, not `isA`: the
  /// iframe's nodes belong to its own realm, so they are not instances of
  /// this page's `Element`.
  static web.Element? _elementAt(web.EventTarget? target) {
    if (target == null) return null;
    final obj = target as JSObject;
    if (!obj.has('closest') || !obj.has('tagName')) return null;
    return target as web.Element;
  }

  static web.HTMLAnchorElement? _linkAt(web.EventTarget? target) {
    final link = _elementAt(target)?.closest('a[href]');
    return link == null ? null : link as web.HTMLAnchorElement;
  }

  void _injectBridge() {
    final win = _iframe?.contentWindow;
    if (win == null) return;
    const bridge = r"""
(function() {
  function makeChannel(name) {
    return { postMessage: function(v) {
      window.parent.postMessage(name + '\x00' + (v !== undefined ? String(v) : ''), '*');
    }};
  }
  window['onContentChanged'] = makeChannel('onContentChanged');
  window['onLinkRequest']    = makeChannel('onLinkRequest');
  if (document.readyState !== 'loading') {
    window.parent.postMessage('pageLoaded\x00', '*');
  } else {
    document.addEventListener('DOMContentLoaded', function() {
      window.parent.postMessage('pageLoaded\x00', '*');
    });
  }
})();
""";
    try {
      win.callMethod<JSAny?>('eval'.toJS, bridge.toJS);
    } catch (_) {
      // Cross-origin or CSP restriction — bridge unavailable.
    }
  }

  /// Prints the iframe's own document, not the whole Flutter page.
  Future<void> printCurrent() async {
    _iframe?.contentWindow?.print();
  }

  Future<void> focus() async {
    _iframe?.focus();
  }

  Future<String?> eval(String js) async {
    final win = _iframe?.contentWindow;
    if (win == null) return null;
    try {
      final result = win.callMethod<JSAny?>('eval'.toJS, js.toJS);
      return result?.dartify()?.toString();
    } catch (_) {
      return null;
    }
  }

  // Position and size are handled by Flutter's layout engine on web
  // (the iframe fills the HtmlElementView widget).
  Future<void> setPosition(double x, double y, double dpr) async {}
  Future<void> setSize(double w, double h, double dpr) async {}

  /// Shows or hides the iframe, as the native controller does its webview.
  Future<void> setVisible(bool visible) async {
    _iframe?.style.visibility = visible ? 'visible' : 'hidden';
  }

  Future<void> dispose() async {
    await _messageSub?.cancel();
    await _loadSub?.cancel();
    _onContentChanged.close();
    _onLinkRequest.close();
    _onPageLoaded.close();
    _onLinkOpened.close();
    _onLinkHovered.close();
    _onAttachRequested.close();
    _onClickFocus.close();
    _onImageDoubleClicked.close();
    _onImagePasted.close();
    _iframe = null;
    _viewId = null;
  }
}
