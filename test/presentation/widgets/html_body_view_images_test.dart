import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/widgets/html_body_view.dart';

void main() {
  group('blockExternalImages', () {
    test('holds the remote src back under data-blocked-src', () {
      final (out, blocked) = blockExternalImages(
        '<img src="https://example.com/a.png" alt="a">',
      );

      expect(blocked, isTrue);
      expect(out, contains('data-blocked-src="https://example.com/a.png"'));
      // No fetchable src is left — the only `src="https` in there is the tail
      // of the held-back attribute's own name.
      expect(out, isNot(contains(' src="https://')));
    });

    test('substitutes a loadable pixel rather than leaving src off', () {
      // An <img> with no source at all is a *broken* image: the engine draws
      // its own glyph and the sender's alt text over the placeholder.
      final (out, _) = blockExternalImages('<img src="https://x/a.png">');

      expect(out, contains('src="data:image/gif;base64,'));
    });

    test('leaves inline and data images alone', () {
      const html = '<img src="cid:logo"><img src="data:image/png;base64,AA">';

      final (out, blocked) = blockExternalImages(html);

      expect(blocked, isFalse);
      expect(out, html);
    });

    test('handles single-quoted and unquoted src', () {
      final (single, _) = blockExternalImages("<img src='https://x/a.png'>");
      final (bare, _) = blockExternalImages('<img src=https://x/a.png>');

      expect(single, contains("data-blocked-src='https://x/a.png'"));
      expect(bare, contains('data-blocked-src=https://x/a.png'));
    });

    test('marks a tracking pixel as a spacer so it gets no placeholder', () {
      final (out, blocked) = blockExternalImages(
        '<img border="0" width="1" height="1" src="https://x/open?id=1">',
      );

      expect(blocked, isTrue);
      expect(out, contains('data-blocked-spacer'));
    });

    test('marks the spacer before the attributes, not after a self-closing /',
        () {
      // `<img ... />` would otherwise take the marker after the slash, where
      // it is not an attribute at all.
      final (out, _) = blockExternalImages(
        '<img width="1" height="1" src="https://x/o" alt=""/>',
      );

      expect(out, startsWith('<img data-blocked-spacer '));
      expect(out, endsWith('/>'));
    });

    test('a content image is not a spacer', () {
      final (out, _) = blockExternalImages(
        '<img width="600" height="200" src="https://x/hero.png">',
      );

      expect(out, isNot(contains('data-blocked-spacer')));
    });

    test('an undeclared size is not a spacer', () {
      final (out, _) = blockExternalImages('<img src="https://x/hero.png">');

      expect(out, isNot(contains('data-blocked-spacer')));
    });

    test('a max-width in a style attribute is not a declared dimension', () {
      final (out, _) = blockExternalImages(
        '<img src="https://x/hero.png" style="max-width: 1px; width: 2px">',
      );

      expect(out, isNot(contains('data-blocked-spacer')));
    });

    test('reports false when there is nothing to hold back', () {
      final (out, blocked) = blockExternalImages('<p>no images here</p>');

      expect(blocked, isFalse);
      expect(out, '<p>no images here</p>');
    });

    test('holds back every image in the message', () {
      final (out, blocked) = blockExternalImages(
        '<img src="https://x/1.png"><img src="https://x/2.png">',
      );

      expect(blocked, isTrue);
      expect('data-blocked-src'.allMatches(out).length, 2);
    });
  });

    group('what the policy refuses but no chip can be left for', () {
      test('holds back a remote srcset, which would outrank the pixel', () {
        // The candidate list wins over `src`, so leaving it would mean a
        // request the policy refuses and then the broken-image glyph the
        // substituted pixel exists to avoid.
        final (out, blocked) = blockExternalImages(
          '<img src="https://x/a.png" srcset="https://x/a2.png 2x">',
        );

        expect(blocked, isTrue);
        expect(out, contains('data-blocked-srcset="https://x/a2.png 2x"'));
        expect(out, isNot(contains(' srcset=')));
        expect(out, contains('src="data:image/gif;base64,'));
      });

      test('gives an image that had only a srcset the pixel too', () {
        final (out, blocked) =
            blockExternalImages('<img srcset="https://x/a.png 1x" alt="a">');

        expect(blocked, isTrue);
        expect(out, contains('src="data:image/gif;base64,'));
        expect(out, contains('data-blocked-srcset='));
      });

      test('does not rewrite the data-blocked-src it just wrote', () {
        final (out, _) = blockExternalImages('<img src="https://x/a.png">');

        expect(out, contains('data-blocked-src="https://x/a.png"'));
        expect(out, isNot(contains('data-blocked-data-blocked')));
      });

      test('holds back a <picture>\'s remote source', () {
        // A <source> is chosen ahead of the <img> inside the <picture>, so a
        // remote candidate there decides the whole element.
        final (out, blocked) = blockExternalImages(
          '<picture><source srcset="https://x/a.webp" type="image/webp">'
          '<img src="https://x/a.png"></picture>',
        );

        expect(blocked, isTrue);
        expect(out, contains('data-blocked-srcset="https://x/a.webp"'));
        expect(out, isNot(contains('<source srcset=')));
      });

      test('leaves a local srcset alone', () {
        const html = '<img srcset="cid:logo 1x, data:image/png;base64,AA 2x">';

        final (out, blocked) = blockExternalImages(html);

        expect(out, html);
        expect(blocked, isFalse);
      });

      test('reports a CSS background as blocked so the bar can offer it', () {
        // Nothing is rewritten here — the policy is what refuses the fetch —
        // but a message whose only remote content is a background image still
        // has to be able to say so, or "Download once" is never offered.
        final (out, blocked) = blockExternalImages(
          '<div style="background:url(https://tracker/pixel.gif)">hi</div>',
        );

        expect(blocked, isTrue);
        expect(out, contains('url(https://tracker/pixel.gif)'));
      });

      test('reports a remote stylesheet, @import and video poster', () {
        for (final html in [
          '<link rel="stylesheet" href="https://x/a.css">',
          '<style>@import url("https://x/a.css");</style>',
          '<video poster="https://x/p.jpg"></video>',
        ]) {
          final (_, blocked) = blockExternalImages(html);
          expect(blocked, isTrue, reason: html);
        }
      });

      test('a body with nothing remote in it is still reported clean', () {
        final (_, blocked) = blockExternalImages(
          '<div style="background:url(cid:bg)"><img src="data:image/png;base64,AA">'
          '</div>',
        );

        expect(blocked, isFalse);
      });
    });
}
