import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// On macOS the compose editor's WKWebView is a plain subview of the
/// FlutterView, and FlutterView paints through a CALayer it adds to its own
/// layer on the first frame it commits. Both are sibling sublayers at
/// zPosition 0, so whichever is added later is drawn on top. A reply mounts
/// the editor in the window's first build, so its webview can be added before
/// Flutter's surface layer arrives — and then Flutter's opaque surface covers
/// it. The page loads, lays out and reports itself visible; the user sees the
/// window background where the toolbar and body should be.
///
/// Measured in the compose sub-window: `FlutterView.layer.sublayers` was
/// `[CALayer z=0, WEBVIEW z=0]`, order decided by timing. A zPosition above
/// Flutter's surfaces (zIndex 0, small integers with platform views) makes
/// the order deterministic. None of this is reachable from a Dart test, so
/// what is pinned here is that the webview is still lifted at all.
void main() {
  final webKitView = File(
    'packages/html_view/macos/html_view/Sources/html_view/WebKitView.swift',
  ).readAsStringSync();

  test('the webview layer is ordered above Flutter surface layers', () {
    expect(
      webKitView,
      contains('webView.layer?.zPosition = 1000'),
      reason:
          'at equal zPosition the later-added sibling layer wins, and '
          "in a reply Flutter's first surface can arrive after the webview",
    );
    expect(
      webKitView,
      contains('webView.wantsLayer = true'),
      reason: 'zPosition only exists on a layer-backed view',
    );
    final addSubview = webKitView.indexOf('parentView.addSubview(webView)');
    final zPosition = webKitView.indexOf('webView.layer?.zPosition');
    expect(addSubview, greaterThanOrEqualTo(0));
    expect(
      zPosition,
      greaterThan(addSubview),
      reason: 'set once the view is in the hierarchy it is ordered within',
    );
  });
}
