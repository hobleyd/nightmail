import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The compose editor's formatting shortcuts live in `assets/editor/editor.html`
/// and only exist inside a real engine, so what a test can reach is the shape
/// of the binding table — that every toolbar command a keyboard user needs
/// still has a key on it, that each one routes through the same `fmt()` the
/// button does, and that the modifier test is the platform's own rather than
/// "any of ctrl or meta".
void main() {
  final editor = File('assets/editor/editor.html').readAsStringSync();

  /// The asset with its `//` comment lines removed, so a rule quoted in a
  /// comment cannot satisfy — or trip — an assertion about the code.
  final code = editor
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  /// The body of the named top-level JS function, up to the closing brace in
  /// column 1.
  String functionBody(String name) {
    final start = editor.indexOf('\nfunction $name(');
    expect(start, isNot(-1), reason: '$name() is gone from the editor asset');
    final end = editor.indexOf('\n}', start);
    return editor.substring(start, end);
  }

  group('formatting is reachable from the keyboard', () {
    // Gmail, Google Docs and Outlook on the web all agree on these, which is
    // the muscle memory a mail composer inherits.
    const bindings = <String, String>{
      "!shift && key === 'b'": "fmt('bold')",
      "!shift && key === 'i'": "fmt('italic')",
      "!shift && key === 'u'": "fmt('underline')",
      "shift && key === 'x'": "fmt('strikeThrough')",
      "shift && code === 'Digit8'": "fmt('insertUnorderedList')",
      "shift && code === 'Digit7'": "fmt('insertOrderedList')",
      "!shift && code === 'BracketRight'": "fmt('indent')",
      "!shift && code === 'BracketLeft'": "fmt('outdent')",
      "!shift && key === 'k'": 'requestLink()',
      "!shift && code === 'Backslash'": "fmt('removeFormat')",
    };

    bindings.forEach((test_, action) {
      test('$test_ runs $action', () {
        expect(editor, contains('$test_) $action'),
            reason: 'the shortcut must call the same function the toolbar '
                'button does, or the two drift apart');
      });
    });

    test('every fmt() button on the toolbar has a binding', () {
      // Catches a formatting button added to the toolbar without a key. It
      // does not cover colour, font family, font size, the format painter or
      // attach — those go through their own functions rather than fmt(), and
      // are deliberately mouse-only: no two mail clients agree on a key for
      // any of them, so a binding here would be one this app invented.
      final toolbarCommands = RegExp(r"fmt\('(\w+)'\)")
          .allMatches(editor.substring(
              editor.indexOf('<div class="toolbar"'),
              editor.indexOf('</div>', editor.indexOf('<div class="toolbar"'))))
          .map((m) => m.group(1)!)
          .toSet();
      expect(toolbarCommands, isNotEmpty);
      final shortcutBlock = editor.substring(
          editor.indexOf('// --- Keyboard shortcuts'),
          editor.indexOf('// Update toolbar button active states'));
      for (final cmd in toolbarCommands) {
        expect(shortcutBlock, contains("fmt('$cmd')"),
            reason: '$cmd is on the toolbar but has no keyboard shortcut');
      }
    });

    test('each bound button names its chord in the tooltip', () {
      // A shortcut nobody can see is a shortcut nobody uses.
      for (final id in const [
        'btn-bold',
        'btn-italic',
        'btn-underline',
        'btn-strike',
        'btn-ul',
        'btn-ol',
        'btn-indent',
        'btn-outdent',
        'btn-link',
        'btn-removeformat',
      ]) {
        expect(editor, contains('id="$id"'),
            reason: 'the tooltip hints key off ids, not title text');
        expect(editor, contains("'$id':"),
            reason: '$id has a shortcut but does not advertise it');
      }
      // The symbols differ by platform, so they come from IS_APPLE.
      expect(code, contains('const MOD = IS_APPLE ?'));
      expect(code, contains('const SHIFT_MOD = IS_APPLE ?'));
    });
  });

  group('the modifier is the platform\'s own', () {
    test('Cmd on Apple, Ctrl elsewhere, and never both', () {
      final body = functionBody('_isShortcutModifier');
      expect(body, contains('IS_APPLE ? (e.metaKey && !e.ctrlKey)'),
          reason: 'Ctrl+B on macOS is the system back-one-character binding '
              'and must still reach the engine');
      expect(body, contains('(e.ctrlKey && !e.metaKey)'),
          reason: 'Cmd on Windows/Linux is the Super key, not ours');
      expect(body, contains('if (e.altKey) return false;'),
          reason: 'Alt makes a different shortcut, and on macOS it rewrites '
              'e.key into the character it would type');
    });

    test('digits and punctuation are matched on e.code, letters on e.key', () {
      // With Shift held, e.key for the 7 key is '&' on a US layout and
      // something else again on a UK or German one.
      expect(code, isNot(contains("key === '7'")));
      expect(code, isNot(contains("key === '8'")));
      expect(editor, contains("const key = (e.key || '').toLowerCase();"),
          reason: 'with Shift held e.key for the X key is uppercase');
    });

    test('an unrecognised combination is left to the engine', () {
      expect(editor, contains('if (handled) e.preventDefault();'),
          reason: 'swallowing every Cmd- chord would break Cmd+A/C/V/Z');
    });
  });

  group('Tab', () {
    test('nests and un-nests inside a list, indents elsewhere', () {
      expect(editor, contains("fmt(e.shiftKey ? 'outdent' : 'indent')"));
      expect(functionBody('_caretInListItem'), contains("closest('li')"));
    });

    test('a modified Tab belongs to the window manager', () {
      expect(editor, contains('if (e.metaKey || e.ctrlKey || e.altKey) return;'),
          reason: 'Cmd+Tab must not insert four spaces');
    });
  });

  test('the link dialog does not lose the selection it is meant to wrap', () {
    // The host hides the webview while the dialog is up, and WebKit clears the
    // DOM selection when the view resigns first responder.
    expect(functionBody('requestLink'), contains('pendingLinkRange = r.cloneRange()'));
    final insert = functionBody('insertLink');
    expect(insert, contains('sel.addRange(pendingLinkRange)'),
        reason: 'editor.focus() restores a caret at offset 0, not the range — '
            'createLink over a collapsed caret links nothing');
  });
}
