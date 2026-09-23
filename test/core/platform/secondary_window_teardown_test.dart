import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// desktop_multi_window ends a secondary window's engine by letting the
/// NSWindow deallocate, and window_manager keeps that window alive from inside
/// the engine's own plugin registry — so, left to themselves, every closed
/// compose, email-view, event-edit and reminder window kept its engine, isolate
/// and WKWebView running. Observed as `[Compose] window ignored 3 close
/// requests` after every close and FlutterWindow's "Child window deinit" never
/// printing. None of this is reachable from a Dart test, so what is pinned here
/// is that the teardown still exists at all.
void main() {
  final mainWindow = File(
    'macos/Runner/MainFlutterWindow.swift',
  ).readAsStringSync();
  final webKitView = File(
    'packages/html_view/macos/html_view/Sources/html_view/WebKitView.swift',
  ).readAsStringSync();

  test('a secondary window shuts its engine down when it closes', () {
    expect(
      mainWindow,
      contains('NSWindow.willCloseNotification'),
      reason: 'the only signal desktop_multi_window itself acts on',
    );
    expect(
      mainWindow,
      contains('controller?.engine.shutDownEngine()'),
      reason:
          'the NSWindow never deallocates, so the engine must be ended '
          'explicitly',
    );
    expect(
      mainWindow,
      contains('window?.contentViewController = nil'),
      reason: 'detaching the controller is what lets the retain cycle unwind',
    );
    expect(
      mainWindow,
      contains('DispatchQueue.main.async'),
      reason:
          "the notification fires inside window_manager's close handler, "
          'which still has to answer the Dart call',
    );
  });

  test("the window's relay channels are forgotten with it", () {
    expect(mainWindow, contains('tearDownEngineWhenClosed('));
    expect(
      mainWindow,
      contains('self?.forgetChannels(channels)'),
      reason:
          'a broadcast to a dead engine logs "Invalid engine handle" '
          'for every relay it was still on',
    );
  });

  test('the webview releases its key monitor without a destroyView', () {
    expect(
      webKitView,
      contains('deinit { dispose() }'),
      reason: 'the Dart side cannot call destroyView once its engine is gone',
    );
  });

  test('a webview leaves with the window that hosted it', () {
    final plugin = File(
      'packages/html_view/macos/html_view/Sources/html_view/HtmlViewPlugin.swift',
    ).readAsStringSync();
    expect(
      webKitView,
      contains('NSWindow.willCloseNotification'),
      reason:
          'a shut-down engine keeps its plugins, so without this the '
          'WKWebView and its WebContent process outlive the window',
    );
    expect(
      plugin,
      contains('self?.views.removeValue(forKey: id)?.dispose()'),
      reason: 'the registry entry is the last strong reference',
    );
    expect(
      webKitView,
      contains('if disposed { return }'),
      reason: 'dispose runs from the window observer, destroyView and deinit',
    );
  });
}
