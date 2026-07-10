import 'dart:async';
import 'package:flutter/foundation.dart' show unawaited;
import 'package:flutter/services.dart';

const MethodChannel _pluginChannel = MethodChannel('html_view');

class HtmlViewController {
  int? _viewId;
  MethodChannel? _channel;
  StreamSubscription? _eventSub;

  // Buffered position/size from reports that arrived before the channel was ready.
  List<double>? _pendingPos;
  List<double>? _pendingSize;

  final _onContentChanged   = StreamController<String>.broadcast();
  final _onLinkRequest      = StreamController<void>.broadcast();
  final _onPageLoaded       = StreamController<void>.broadcast();
  final _onLinkOpened       = StreamController<String>.broadcast();
  final _onAttachRequested  = StreamController<void>.broadcast();

  Stream<String> get onContentChanged  => _onContentChanged.stream;
  Stream<void>   get onLinkRequest     => _onLinkRequest.stream;
  /// Fires once when the page DOM is ready (DOMContentLoaded).
  Stream<void>   get onPageLoaded      => _onPageLoaded.stream;
  /// Fires when the user clicks an http/https/mailto link; navigation is
  /// cancelled by the native side so the caller can open it externally.
  Stream<String> get onLinkOpened      => _onLinkOpened.stream;
  /// Fires when the user clicks the attachment button in the toolbar.
  Stream<void>   get onAttachRequested => _onAttachRequested.stream;

  bool get isInitialized => _viewId != null;

  Future<void> initialize() async {
    final id = await _pluginChannel.invokeMethod<int>('createView');
    _viewId = id;

    _channel = MethodChannel('html_view/$id');

    final events = EventChannel('html_view/${id}_events');
    _eventSub = events.receiveBroadcastStream().listen(_onEvent);

    // Flush position/size that arrived before the channel was ready.
    if (_pendingPos != null) {
      unawaited(_channel!.invokeMethod('setPosition', _pendingPos));
      _pendingPos = null;
    }
    if (_pendingSize != null) {
      unawaited(_channel!.invokeMethod('setSize', _pendingSize));
      _pendingSize = null;
    }
  }

  void _onEvent(dynamic event) {
    final map = event as Map;
    switch (map['type'] as String) {
      case 'onContentChanged':
        _onContentChanged.add(map['value'] as String? ?? '');
        break;
      case 'onLinkRequest':
        _onLinkRequest.add(null);
        break;
      case 'pageLoaded':
        _onPageLoaded.add(null);
        break;
      case 'onLinkOpened':
        _onLinkOpened.add(map['value'] as String? ?? '');
        break;
      case 'onAttachRequest':
        _onAttachRequested.add(null);
        break;
    }
  }

  Future<void> printCurrent() =>
      _channel!.invokeMethod('printCurrent');

  Future<void> loadAsset(String assetKey) =>
      _channel!.invokeMethod('loadAsset', assetKey);

  Future<void> loadHtml(String html) =>
      _channel!.invokeMethod('loadHtml', html);

  Future<void> loadUrl(String url) =>
      _channel!.invokeMethod('loadUrl', url);

  Future<String?> eval(String js) =>
      _channel!.invokeMethod<String>('eval', js);

  /// Gives the native WebView2 control OS-level keyboard focus. Calling
  /// `element.focus()` in JS alone only focuses within the web content —
  /// the host HWND still needs to be told to take focus for a caret to show
  /// or for keystrokes to route there instead of the Flutter window.
  Future<void> focus() async {
    try {
      await _channel!.invokeMethod('focus');
    } catch (_) {}
  }

  Future<void> setPosition(double x, double y, double dpr) {
    if (_channel == null) {
      _pendingPos = [x, y, dpr];
      return Future.value();
    }
    return _channel!.invokeMethod('setPosition', [x, y, dpr]);
  }

  Future<void> setSize(double w, double h, double dpr) {
    if (_channel == null) {
      _pendingSize = [w, h, dpr];
      return Future.value();
    }
    return _channel!.invokeMethod('setSize', [w, h, dpr]);
  }

  /// Show or hide the native WebView2 control.
  /// Call with [false] when a Flutter overlay (dialog, bottom sheet, etc.)
  /// appears on top so it isn't obscured by the native HWND.
  Future<void> setVisible(bool visible) async {
    if (_channel == null) return;
    try {
      await _channel!.invokeMethod('setVisible', visible);
    } catch (_) {}
  }

  Future<void> dispose() async {
    try { await _eventSub?.cancel(); } catch (_) {}
    _onContentChanged.close();
    _onLinkRequest.close();
    _onPageLoaded.close();
    _onLinkOpened.close();
    _onAttachRequested.close();
    if (_viewId != null) {
      final id = _viewId;
      _viewId = null;
      try {
        await _pluginChannel.invokeMethod('destroyView', id);
      } catch (_) {
        // Channel may be gone if the engine is shutting down; native side
        // cleans up via WM_DESTROY / plugin detach in that case.
      }
    }
  }
}
