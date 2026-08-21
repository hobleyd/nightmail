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

      final out = installContentSecurityPolicy(html);

      expect(out.indexOf(policy), lessThan(out.indexOf('<script')));
    });

    test('lands ahead of a script the sender put before <head>', () {
      // Malformed, and the reason the policy cannot simply follow the literal
      // `<head>`: the parser hoists this script into an implicit head, where it
      // would run first.
      const html = '<html><script>steal()</script><head></head>'
          '<body>hi</body></html>';

      final out = installContentSecurityPolicy(html);

      expect(out.indexOf(policy), lessThan(out.indexOf('<script')));
    });

    test('stays behind a leading doctype', () {
      // A meta ahead of the doctype makes the parser ignore it and render in
      // quirks mode, which changes how a mail body's tables lay out.
      const html = '<!DOCTYPE html><html><head></head><body>hi</body></html>';

      final out = installContentSecurityPolicy(html);

      expect(out, startsWith('<!DOCTYPE html><meta http-equiv'));
      expect(out.indexOf(policy), lessThan(out.indexOf('<html')));
    });

    test('stays behind a doctype with a public identifier and leading space',
        () {
      const html = '\n<!doctype html PUBLIC "-//W3C//DTD XHTML 1.0//EN" '
          '"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">\n'
          '<html><head></head><body>hi</body></html>';

      final out = installContentSecurityPolicy(html);

      expect(out.indexOf(policy), greaterThan(out.indexOf('xhtml1')));
      expect(out.indexOf(policy), lessThan(out.indexOf('<html')));
    });

    test('goes first when there is no doctype', () {
      final out = installContentSecurityPolicy('<html><head></head></html>');

      expect(out, startsWith('<meta http-equiv'));
    });

    test('is not fooled by a doctype further down the document', () {
      // The only doctype that puts the document in standards mode is a leading
      // one; one quoted in the body is text, and skipping past it would leave
      // the policy behind the sender's head.
      const html = '<html><head></head><body>&lt;!DOCTYPE html&gt;</body>'
          '</html>';

      final out = installContentSecurityPolicy(html);

      expect(out, startsWith('<meta http-equiv'));
    });

    test('names the same directives the reading pane relies on', () {
      final out = installContentSecurityPolicy('<div>x</div>');

      expect(out, contains("script-src 'none'"));
      expect(out, contains("object-src 'none'"));
    });

    test('installs exactly one policy', () {
      final out = installContentSecurityPolicy('<html><head></head></html>');

      expect(policy.allMatches(out).length, 1);
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
      expect(composeHtml, contains('installContentSecurityPolicy(resolved)'));
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
