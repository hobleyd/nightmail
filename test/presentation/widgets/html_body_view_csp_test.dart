import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/widgets/html_body_view.dart';

/// A meta CSP only governs what is parsed after it, so where the reading pane's
/// policy lands in the document is the whole of whether it does anything: on
/// desktop the webview has script enabled, and a `<script>` the sender put in
/// their own head used to be parsed — and run — before the policy existed.
void main() {
  const policy = 'Content-Security-Policy';

  group('installContentSecurityPolicy', () {

    test('lands ahead of a script in the sender\'s own head', () {
      const html = '<html><head><script>steal()</script></head>'
          '<body>hi</body></html>';

      final out = installContentSecurityPolicy(html, allowExternal: false);

      expect(out.indexOf(policy), lessThan(out.indexOf('<script')));
    });

    test('lands ahead of a script the sender put before <head>', () {
      // Malformed, and the reason the policy cannot simply follow the literal
      // `<head>`: the parser hoists this script into an implicit head, where it
      // would run first.
      const html = '<html><script>steal()</script><head></head>'
          '<body>hi</body></html>';

      final out = installContentSecurityPolicy(html, allowExternal: false);

      expect(out.indexOf(policy), lessThan(out.indexOf('<script')));
    });

    test('stays behind a leading doctype', () {
      // A meta ahead of the doctype makes the parser ignore it and render in
      // quirks mode, which changes how a mail body's tables lay out.
      const html = '<!DOCTYPE html><html><head></head><body>hi</body></html>';

      final out = installContentSecurityPolicy(html, allowExternal: false);

      expect(out, startsWith('<!DOCTYPE html><meta http-equiv'));
      expect(out.indexOf(policy), lessThan(out.indexOf('<html')));
    });

    test('stays behind a doctype with a public identifier and leading space',
        () {
      const html = '\n<!doctype html PUBLIC "-//W3C//DTD XHTML 1.0//EN" '
          '"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">\n'
          '<html><head></head><body>hi</body></html>';

      final out = installContentSecurityPolicy(html, allowExternal: false);

      expect(out.indexOf(policy), greaterThan(out.indexOf('xhtml1')));
      expect(out.indexOf(policy), lessThan(out.indexOf('<html')));
    });

    test('goes first when there is no doctype', () {
      final out = installContentSecurityPolicy('<html><head></head></html>', allowExternal: false);

      expect(out, startsWith('<meta http-equiv'));
    });

    test('is not fooled by a doctype further down the document', () {
      // The only doctype that puts the document in standards mode is a leading
      // one; one quoted in the body is text, and skipping past it would leave
      // the policy behind the sender's head.
      const html = '<html><head></head><body>&lt;!DOCTYPE html&gt;</body>'
          '</html>';

      final out = installContentSecurityPolicy(html, allowExternal: false);

      expect(out, startsWith('<meta http-equiv'));
    });

    test('names the same directives the reading pane relies on', () {
      final out = installContentSecurityPolicy('<div>x</div>', allowExternal: false);

      expect(out, contains("script-src 'none'"));
      expect(out, contains("object-src 'none'"));
    });

    test('installs exactly one policy', () {
      final out = installContentSecurityPolicy('<html><head></head></html>', allowExternal: false);

      expect(policy.allMatches(out).length, 1);
    });
  });

  group('contentSecurityPolicy', () {
    test('refuses every remote subresource while images are blocked', () {
      final policy = contentSecurityPolicy(allowExternal: false);

      // A mail body reaches a tracker by more routes than <img src>: a CSS
      // background or @font-face (img-src / font-src), an @import or a
      // <link rel=stylesheet> (style-src), a <video poster> (media-src).
      expect(policy, contains('img-src data: file:;'));
      expect(policy, contains('font-src data: file:;'));
      expect(policy, contains('media-src data: file:;'));
      expect(policy, contains("style-src 'unsafe-inline';"));
      expect(policy, contains("default-src 'none'"));
      expect(policy, isNot(contains('http')));
    });

    test('reopens exactly the fetches the reader asked for', () {
      final policy = contentSecurityPolicy(allowExternal: true);

      expect(policy, contains('img-src data: file: https: http:;'));
      expect(policy, contains('font-src data: file: https: http:;'));
      expect(policy, contains('media-src data: file: https: http:;'));
      expect(policy, contains("style-src 'unsafe-inline' https: http:;"));
    });

    test('never lets a body execute, frame or re-base, at either setting', () {
      for (final allow in [false, true]) {
        final policy = contentSecurityPolicy(allowExternal: allow);

        expect(policy, contains("script-src 'none'"), reason: 'allow=$allow');
        expect(policy, contains("object-src 'none'"), reason: 'allow=$allow');
        // An iframe is a document this policy does not govern — it runs its own
        // script, and in WKWebView a subframe can reach the host bridge.
        expect(policy, contains("frame-src 'none'"), reason: 'allow=$allow');
        expect(policy, contains("child-src 'none'"), reason: 'allow=$allow');
        // <base href> re-points the relative URLs the inline images of a
        // file-delivered message are referenced by.
        expect(policy, contains("base-uri 'none'"), reason: 'allow=$allow');
      }
    });

    test('keeps the local schemes the message\'s own images arrive on', () {
      // `data:` is both the inline-attachment route and the held-back image's
      // substituted pixel; `file:` is the same attachments once the document is
      // written to disk. `'self'` would not do: a file: document's origin is
      // opaque, so it matches nothing.
      final policy = contentSecurityPolicy(allowExternal: false);

      expect(policy, contains('img-src data: file:'));
      expect(policy, isNot(contains("'self'")));
    });
  });

  // The function above is only worth anything if the document the webview is
  // handed goes through it. `_composeHtml` is private and builds a document out
  // of a live message, so what it does is pinned against the source instead.
  group('the composed document installs the policy', () {
    final source = File('lib/presentation/widgets/html_body_view.dart')
        .readAsStringSync();
    final composeHtml = source.substring(source.indexOf('(String, bool) _composeHtml('));

    test('_composeHtml runs the finished document through the installer', () {
      expect(composeHtml, contains('installContentSecurityPolicy(resolved'));
      // With the reader's decision carried through, not a fixed policy.
      expect(composeHtml, contains('allowExternal: allowExternal'));
    });

    test('the policy is not spliced in with the injected styles', () {
      // Back inside `injected` it would land before `</head>` again — behind the
      // sender's head, which is the bug — and it would drag the `!important`
      // styles to the front of the cascade if it were hoisted along with them.
      final injected = source.substring(
        source.indexOf("const injected = '''"),
        source.indexOf("''';", source.indexOf("const injected = '''")),
      );
      expect(injected, isNot(contains(policy)));
      expect(injected, contains('<style>'));
    });
  });
}
