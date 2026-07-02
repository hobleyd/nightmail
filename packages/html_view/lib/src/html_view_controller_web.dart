// Web-specific HtmlViewController.
// Uses dart:html IFrameElement + dart:js_util for same-origin eval.
// Conditionally exported by lib/html_view.dart when dart.library.html is present.

import 'dart:async';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
// ignore: avoid_web_libraries_in_flutter
import 'dart:js_util' as js_util;
import 'dart:ui_web' as ui_web;

class HtmlViewController {
  static int _nextId = 1;

  int? _viewId;
  html.IFrameElement? _iframe;
  StreamSubscription? _messageSub;

  final _onContentChanged = StreamController<String>.broadcast();
  final _onLinkRequest    = StreamController<void>.broadcast();
  final _onPageLoaded     = StreamController<void>.broadcast();
  final _onLinkOpened     = StreamController<String>.broadcast();

  Stream<String> get onContentChanged => _onContentChanged.stream;
  Stream<void>   get onLinkRequest    => _onLinkRequest.stream;
  Stream<void>   get onPageLoaded     => _onPageLoaded.stream;
  Stream<String> get onLinkOpened     => _onLinkOpened.stream;

  bool get isInitialized => _viewId != null;
  int? get viewId => _viewId;

  Future<void> initialize() async {
    final id = _nextId++;
    _viewId = id;

    final iframe = html.IFrameElement()
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

    // Listen for postMessage events from the iframe.
    _messageSub = html.window.onMessage.listen((event) {
      if (event.source != _iframe?.contentWindow) return;
      final data = event.data?.toString();
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
    _iframe?.setAttribute('srcdoc', html);
  }

  Future<void> loadUrl(String url) async {
    _iframe?.src = url;
  }

  Future<void> loadAsset(String assetKey) async {
    // Flutter web serves assets at assets/<key> relative to app root.
    _iframe?.src = 'assets/$assetKey';
    // Inject bridge after page loads so postMessage works.
    _iframe?.onLoad.first.then((_) => _injectBridge());
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
      js_util.callMethod(win, 'eval', [bridge]);
    } catch (_) {
      // Cross-origin or CSP restriction — bridge unavailable.
    }
  }

  Future<void> focus() async {
    _iframe?.focus();
  }

  Future<String?> eval(String js) async {
    final win = _iframe?.contentWindow;
    if (win == null) return null;
    try {
      final result = js_util.callMethod(win, 'eval', [js]);
      return result?.toString();
    } catch (_) {
      return null;
    }
  }

  // Position and size are handled by Flutter's layout engine on web
  // (the iframe fills the HtmlElementView widget).
  Future<void> setPosition(double x, double y, double dpr) async {}
  Future<void> setSize(double w, double h, double dpr) async {}

  Future<void> dispose() async {
    await _messageSub?.cancel();
    _onContentChanged.close();
    _onLinkRequest.close();
    _onPageLoaded.close();
    _onLinkOpened.close();
    _iframe = null;
    _viewId = null;
  }
}
