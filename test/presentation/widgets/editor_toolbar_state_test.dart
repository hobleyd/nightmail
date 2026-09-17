import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A style button has to show the state it has just put the caret into, or the
/// reader cannot tell what typing will do. Applying a command to a *collapsed*
/// caret moves nothing, so no `selectionchange` follows it — verified in
/// WKWebView, which is the macOS engine: `queryCommandState` reports the new
/// state immediately, and the listener that would have drawn it never runs.
/// The button therefore stayed stale until the next keystroke.
///
/// Whether the engine really reports a pending state can only be checked in a
/// real engine; what is pinned here is that every path that changes it still
/// asks the toolbar to redraw, and that redrawing is still coalesced — the
/// unthrottled version froze the UI while typing into a large quoted reply.
void main() {
  final editor = File('assets/editor/editor.html').readAsStringSync();

  /// The body of the named top-level JS function, up to the closing brace in
  /// column 1.
  String functionBody(String name) {
    final start = editor.indexOf('\nfunction $name(');
    expect(start, isNot(-1), reason: '$name() is gone from the editor asset');
    final end = editor.indexOf('\n}', start);
    return editor.substring(start, end);
  }

  group('the toolbar shows what typing will do', () {
    test('a toolbar command redraws the toolbar itself', () {
      expect(functionBody('fmt'), contains('scheduleToolbarUpdate()'),
          reason: 'a collapsed caret fires no selectionchange, so nothing else '
              'will draw the state the button has just set');
    });

    test('the format painter redraws too', () {
      expect(
          functionBody('applyPaintedFormat'), contains('scheduleToolbarUpdate()'),
          reason: 'it applies bold/italic/underline/strike in one go');
    });

    test('the engine shortcuts are covered as well', () {
      expect(editor, contains("editor.addEventListener('keyup', "
          'scheduleToolbarUpdate)'),
          reason: 'Cmd/Ctrl+B is handled by the engine and moves no caret, so '
              'it fires no selectionchange either');
      expect(editor, contains("document.addEventListener('selectionchange', "
          'scheduleToolbarUpdate)'));
    });

    test('redrawing is still coalesced to one frame', () {
      final body = functionBody('scheduleToolbarUpdate');
      expect(body, contains('if (toolbarUpdateScheduled) return;'));
      expect(body, contains('requestAnimationFrame(updateToolbarState)'),
          reason: 'queryCommandState is a synchronous style computation that '
              'scales with the document — unthrottled it froze typing');
    });
  });
}
