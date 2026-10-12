import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The compose editor's format-as-you-type triggers live in
/// `assets/editor/editor.html` and only do anything inside a real engine
/// (measured in WKWebView and in Chrome — see docs/claude/webviews.md). What
/// a test can reach is the shape: which markers are recognised and what each
/// turns into, that the inline conversion runs from the `input` event rather
/// than keydown, and that the guards which keep it from eating the user's
/// text are still there.
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

  /// The literal of a `const NAME = {...}` or `new Set([...])` table.
  String table(String name) {
    final start = editor.indexOf('const $name = ');
    expect(start, isNot(-1), reason: '$name is gone from the editor asset');
    final end = editor.indexOf(RegExp(r'\};|\]\);'), start);
    return editor.substring(start, end);
  }

  group('a list marker and a space start a list', () {
    const triggers = <String, String>{
      "'-'": 'insertUnorderedList',
      "'1.'": 'insertOrderedList',
      "'1)'": 'insertOrderedList',
    };

    triggers.forEach((marker, cmd) {
      test('$marker runs $cmd', () {
        expect(table('LIST_TRIGGERS'), contains("$marker: '$cmd'"));
      });
    });

    test('the space handler looks the typed text up in the table', () {
      // Whatever is in the table is what triggers; the handler itself names
      // no marker, so adding one is a table entry and nothing else.
      expect(editor, contains('const listCmd = LIST_TRIGGERS[typed];'));
      expect(editor, contains('delRange.setEnd(node, typed.length);'));
      expect(editor, contains('document.execCommand(listCmd, false, null);'));
    });
  });

  group('a word wrapped in markers takes the style', () {
    const markers = <String, String>{
      "'*'": 'bold',
      "'_'": 'italic',
      "'~'": 'strikeThrough',
    };

    markers.forEach((marker, cmd) {
      test('$marker applies $cmd', () {
        expect(table('INLINE_MARKERS'), contains("$marker: '$cmd'"));
      });
    });

    test('each command wraps in the element the engine itself produces', () {
      final tags = table('INLINE_MARKER_TAGS');
      expect(tags, contains("bold: 'b'"));
      expect(tags, contains("italic: 'i'"));
      expect(tags, contains("strikeThrough: 'strike'"));
    });

    test('the conversion runs from the input event, not keydown', () {
      // Converting after the engine has inserted the closing marker is what
      // makes Cmd+Z hand back the literal `*bold*` — closing marker included —
      // and what lets a soft keyboard, whose keydown carries no character,
      // trigger it at all.
      expect(editor, contains('_checkInlineMarker(e);'));
      final body = functionBody('_checkInlineMarker');
      expect(body, contains("e.inputType !== 'insertText'"));
      expect(body, contains('e.isComposing'));
      expect(editor, isNot(contains('INLINE_MARKERS[e.key]')),
          reason: "the markers are matched on the input event's data, "
              'never on a keydown');
    });

    test('a refused insertHTML puts the caret back', () {
      // Blink refuses execCommand while another one is running. The span is
      // selected by then, and left that way the next keystroke deletes it.
      final body = functionBody('_checkInlineMarker');
      const refusal = "if (!document.execCommand('insertHTML', false, html)) {";
      expect(body, contains(refusal));
      expect(body.substring(body.indexOf(refusal)),
          contains('sel.addRange(range);'));
    });

    test('the style is switched off again after the span', () {
      // The caret lands inside the new element, so without this the next
      // word typed would carry the style too.
      final body = functionBody('_checkInlineMarker');
      expect(
          body,
          contains('if (document.queryCommandState(cmd)) '
              'document.execCommand(cmd, false, null);'));
    });

    test('a marker only opens a span where a word starts', () {
      // `my_var_name`, `5*3*2` and `*.txt or *.doc` stay literal.
      final body = functionBody('_findMarkerOpener');
      expect(
          body,
          contains('const startsWord = before === \'\' || '
              '/[\\s(\\[{"\'\\u200B]/.test(before);'));
      expect(
          body,
          contains('const opensSpan = after !== undefined && '
              '!/\\s/.test(after) && after !== marker;'));
      expect(body, contains("text.indexOf('\\n', i) === -1"),
          reason: 'a span stays on one line');
    });

    test('a span may hold inline formatting and nothing that re-parses badly',
        () {
      // The span is serialised and handed to insertHTML — a re-parse — so the
      // namespace-switching trio the sanitiser drops must never be let in.
      final allowed = RegExp(r"'([A-Z0-9]+)'")
          .allMatches(table('INLINE_MARKER_CONTENT'))
          .map((m) => m.group(1)!)
          .toSet();
      expect(allowed, containsAll(['B', 'I', 'STRIKE', 'A', 'SPAN']));
      for (final tag in const [
        'SVG',
        'MATH',
        'NOSCRIPT',
        'SCRIPT',
        'IFRAME',
        'IMG',
        'BR',
        'DIV',
        'P',
      ]) {
        expect(allowed, isNot(contains(tag)),
            reason: '$tag must end a span, not be carried into it');
      }
    });

    test('undoing a conversion leaves the caret after the literal text', () {
      // Both engines give the undone text back selected, so the next
      // keystroke would wipe it.
      expect(editor, contains('_settleUndoneMarker(e);'));
      final body = functionBody('_settleUndoneMarker');
      expect(body, contains("e.inputType !== 'historyUndo'"));
      expect(body, contains('sel.collapseToEnd();'));
    });
  });
}
