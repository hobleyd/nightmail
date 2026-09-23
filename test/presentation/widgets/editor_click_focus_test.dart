import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Resigning first responder makes WebKit **clear** the DOM selection, and
/// regaining it makes a fresh one at offset 0 of whatever text node the caret
/// was in. Measured in a bare WKWebView over the compose asset: caret at
/// offset 5, first responder away to an NSTextField and back, caret at 0 —
/// while asking for first responder when the view already holds it leaves it
/// at 5, and a caret placed while the view holds nothing survives being given
/// it.
///
/// `mouseDown` fires for every click in the page and the compose toolbar is
/// inside it, so signalling unconditionally sent that round trip — and the
/// caret to the start of the line — on every press of Bold or Italic. None of
/// this is reachable from a Dart test, so what is pinned here is that the
/// signal is still guarded at all.
void main() {
  final webKitView = File(
    'packages/html_view/macos/html_view/Sources/html_view/WebKitView.swift',
  ).readAsStringSync();

  test('a click only signals for focus when the webview has none', () {
    expect(
      webKitView,
      contains('if !isFirstResponder { onClickFocus?() }'),
      reason:
          'there is nothing to steal focus from when we already hold it, '
          'and asking costs the caret',
    );
    expect(
      webKitView,
      contains('private var isFirstResponder: Bool'),
      reason:
          'the guard walks up from window.firstResponder, so a field '
          'editor or an internal content view still counts as ours',
    );
  });
}
