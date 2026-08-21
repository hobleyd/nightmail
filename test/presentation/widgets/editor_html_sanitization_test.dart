import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The compose editor is a webview with script enabled and a method channel to
/// the host, and every reply, forward and draft loads somebody else's markup
/// into it. The defence lives in the asset and in the Android plugin, so it is
/// out of reach of a normal widget test — these pin the shape of it instead, so
/// that removing a piece fails here rather than in somebody's mailbox.
///
/// Behaviour (does `<img onerror>` actually get stripped?) can only be checked
/// in a real engine; what is pinned here is that each inbound path still goes
/// through the sanitiser at all.
void main() {
  final editor = File('assets/editor/editor.html').readAsStringSync();
  final androidPlugin = File(
    'packages/html_view/android/src/main/kotlin/com/nightmail/html_view/'
    'HtmlViewPlugin.kt',
  ).readAsStringSync();

  /// The body of the named top-level JS function, up to the closing brace in
  /// column 1.
  String functionBody(String name) {
    final start = editor.indexOf('\nfunction $name(');
    expect(start, isNot(-1), reason: '$name() is gone from the editor asset');
    final end = editor.indexOf('\n}', start);
    return editor.substring(start, end);
  }

  group('inbound HTML reaches the editor sanitised', () {
    test('setContent parses inert and adopts nodes', () {
      final body = functionBody('setContent');
      expect(body, contains('_parseSanitizedBody('),
          reason: 'setContent must sanitise: it is the one route every quoted '
              'reply, forward and draft takes into the document');
      // `editor.innerHTML = html` is the original bug; assigning the *cleaned*
      // markup back would be a second parse, which is the mutation-XSS class.
      expect(body, isNot(contains('editor.innerHTML = html')));
      expect(body, isNot(contains('innerHTML = _')));
      expect(body, contains('importNode('),
          reason: 'the cleaned nodes are adopted, never re-parsed');
    });

    test('the paste path shares the same sanitiser', () {
      expect(functionBody('_sanitizeHtmlFragment'),
          contains('_parseSanitizedBody('));
      expect(editor, contains("execCommand('insertHTML', false, "
          '_sanitizeHtmlFragment(html))'));
    });

    test('the sanitiser parses in an inert document', () {
      final body = functionBody('_parseSanitizedBody');
      expect(body, contains('new DOMParser().parseFromString('),
          reason: 'a detached element assigned innerHTML starts the image load '
              'before the handlers come off — DOMParser does not');
      expect(body, isNot(contains('createElement')));
      expect(body, contains('_kRemovedTags'));
      expect(body, contains("name.indexOf('on') === 0"),
          reason: 'every event handler, not an allowlist of known ones');
      expect(body, contains("name === 'srcdoc'"));
      expect(body, contains("name.indexOf('xlink:') === 0"));
    });

    test('executable elements are dropped, formatting is not', () {
      for (final tag in const [
        'script', 'style', 'iframe', 'object', 'embed', 'svg', 'math',
        'noscript', 'template', 'form', 'base',
      ]) {
        expect(editor, contains(RegExp('_kRemovedTags[\\s\\S]{0,400}?$tag[,\']')),
            reason: '$tag can execute or change the parser namespace');
      }
      // Quoted bodies are mostly inline styles, and this app's own quote
      // wrapper is a styled <blockquote>.
      expect(functionBody('_parseSanitizedBody'), isNot(contains("'style'")));
    });

    test('javascript: and non-image data: URLs are refused', () {
      final body = functionBody('_isSafeUrlAttr');
      expect(body, contains('javascript|vbscript'));
      // A `data:` URL for an inline image is built from the attachment's own
      // Content-Type, which the sender chose, so `data:text/html` is reachable.
      expect(body, contains('_kDataImageRe'));
      final dataImageRe = RegExp(r'_kDataImageRe =\s*(/\^data:image[^\n]+)')
          .firstMatch(editor);
      expect(dataImageRe, isNotNull);
      expect(dataImageRe!.group(1), isNot(contains('svg')),
          reason: 'an SVG is a document, and a missing logo in a quote is '
              'the cheaper mistake');
      // Control characters are ignored by the URL parser, so they have to
      // be taken out before the scheme is tested.
      expect(body, contains(r'[\u0000-\u0020]'));
    });
  });

  group('blast radius of a bypass', () {
    test('the editor page ships a CSP', () {
      final csp = RegExp(
        r'<meta http-equiv="Content-Security-Policy" content="([^"]+)"',
      ).firstMatch(editor);
      expect(csp, isNotNull, reason: 'the editor page has no CSP');
      final policy = csp!.group(1)!;
      // Script that did run must have no way to send anything off the machine.
      expect(policy, contains("connect-src 'none'"));
      expect(policy, contains("object-src 'none'"));
      expect(policy, contains("frame-src 'none'"));
      expect(policy, contains("base-uri 'none'"));
      expect(policy, contains("form-action 'none'"));
      // With `default-src 'none'` the page's own inline script needs naming or
      // the editor does not load at all.
      expect(policy, contains("default-src 'none'"));
      expect(policy, contains("script-src 'unsafe-inline'"));
      // Quoted bodies carry inline images and remote ones.
      expect(policy, contains('img-src data:'));
    });

    test('the Android WebView grants script no access to file URLs', () {
      expect(androidPlugin, contains('allowFileAccessFromFileURLs = false'));
      expect(androidPlugin, contains('allowUniversalAccessFromFileURLs = false'));
      // Still needed: the reading pane loads its document from a real file
      // when a message has inline images.
      expect(androidPlugin, contains('allowFileAccess = true'));
    });
  });
}
