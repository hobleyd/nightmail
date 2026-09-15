import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/services/markdown_preview_service.dart';

/// A markdown attachment is somebody else's file rendered into a document this
/// app generates and then loads into a webview that has script enabled, so the
/// two things pinned here are what it is allowed to reach (the policy, and the
/// link destinations that survive the render) and that it renders at all.
/// What counts as markdown in the first place is pinned in
/// `test/core/utils/markdown_file_test.dart`.
void main() {
  final service = MarkdownPreviewService();

  String render(String source) => service.buildHtml(source, dark: false);

  group('buildHtml renders', () {
    test('headings, emphasis, lists, code and tables', () {
      final html = render('''
# Title

Some **bold** text.

- one
- two

| a | b |
|---|---|
| 1 | 2 |

```dart
void main() {}
```
''');

      expect(html, contains('<h1'));
      expect(html, contains('<strong>bold</strong>'));
      expect(html, contains('<li>one</li>'));
      expect(html, contains('<table>'));
      expect(html, contains('<code class="language-dart">'));
    });

    test('a GitHub-flavoured task list', () {
      final html = render('- [x] done\n- [ ] todo\n');
      expect(html, contains('type="checkbox"'));
    });

    test('the document, not a fragment', () {
      final html = render('hi');
      expect(html, startsWith('<!DOCTYPE html>'));
      expect(html, contains('<meta charset="utf-8">'));
    });

    test('a light and a dark palette off the same source', () {
      expect(
        service.buildHtml('hi', dark: false),
        isNot(service.buildHtml('hi', dark: true)),
      );
    });
  });

  group('the policy', () {
    test('is the first thing in the document after the doctype', () {
      // Same rule as the reading pane's: a meta policy only governs what is
      // parsed after it, so anything ahead of it is ungoverned.
      final html = render('<script>steal()</script>\n\n# hi');
      final doctype = html.indexOf('<!DOCTYPE html>');
      final csp = html.indexOf('Content-Security-Policy');

      expect(doctype, 0);
      expect(csp, greaterThan(doctype));
      expect(csp, lessThan(html.indexOf('<style>')));
      expect(csp, lessThan(html.indexOf('steal()')));
    });

    test('refuses script, frames, form posts and a rebased document', () {
      for (final directive in [
        "script-src 'none'",
        "object-src 'none'",
        "frame-src 'none'",
        "connect-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
      ]) {
        expect(markdownPreviewCsp, contains(directive));
      }
    });

    test('refuses a remote image at every setting', () {
      // There is no "Download once" on this surface — that belongs to the mail
      // body's status bar — and a `.md` file carries a tracking pixel as
      // readily as a message body does.
      expect(markdownPreviewCsp, contains('img-src data:;'));
      expect(markdownPreviewCsp, isNot(contains('https:')));
      expect(markdownPreviewCsp, isNot(contains('http:')));
    });
  });

  group('link and image destinations', () {
    test('http, https and mailto survive', () {
      final html = render(
        '[a](https://example.com) [b](mailto:x@example.com) '
        '[c](http://example.com)',
      );
      expect(html, contains('href="https://example.com"'));
      expect(html, contains('href="mailto:x@example.com"'));
      expect(html, contains('href="http://example.com"'));
    });

    test('a javascript: href is dropped, keeping the text', () {
      final html = render('[click me](javascript:alert(1))');
      expect(html, isNot(contains('javascript:')));
      expect(html, contains('click me'));
    });

    test('a heading anchor survives, so a table of contents still works', () {
      final html = render('# A Heading\n\n[jump](#a-heading)');
      expect(html, contains('href="#a-heading"'));
      expect(html, contains('id="a-heading"'));
    });

    test(
      'a relative link is dropped — it would resolve to the scratch dir',
      () {
        final html = render('[notes](./NOTES.md)');
        expect(html, isNot(contains('NOTES.md"')));
        expect(html, contains('notes'));
      },
    );

    test('a data: image survives, but only image/', () {
      final ok = render('![x](data:image/png;base64,AAAA)');
      expect(ok, contains('src="data:image/png;base64,AAAA"'));

      final bad = render('![x](data:text/html;base64,AAAA)');
      expect(bad, isNot(contains('data:text/html')));
    });
  });

  group('raw HTML', () {
    test('a script tag is escaped rather than passed through', () {
      final html = render('<script>steal()</script>');
      expect(html, contains('&lt;script>'));
      expect(html, isNot(contains('<script>')));
    });

    test('a tag carrying attributes is escaped too', () {
      // The half GFM's own tagfilter misses: it only fires when the tag name
      // is immediately followed by `>`, so `<script src="…">` sails through it.
      expect(
        render('<script src="https://x/y.js"></script>'),
        isNot(contains('<script')),
      );
      expect(
        render('<iframe src="https://x"></iframe>'),
        contains('&lt;iframe'),
      );
      expect(
        render('<iframe src="https://x"></iframe>'),
        isNot(contains('<iframe')),
      );
    });

    test('a closing tag is escaped with its opener', () {
      expect(
        render('<object data="x"></object>'),
        isNot(contains('</object>')),
      );
    });

    test('a raw style, form, base and meta are escaped', () {
      expect(render('<style>body{}</style>'), contains('&lt;style'));
      expect(
        render('<form action="https://x"><input></form>'),
        isNot(contains('<form')),
      );
      expect(render('<base href="https://x">'), isNot(contains('<base')));
      expect(
        render('<meta http-equiv="refresh" content="0;url=https://x">'),
        isNot(contains('<meta http-equiv="refresh"')),
      );
    });

    test('ordinary README furniture is left alone', () {
      // Markdown carries raw HTML by design and most of it is worth keeping.
      expect(render('a<br>b'), contains('<br>'));
      expect(
        render('<details><summary>More</summary>text</details>'),
        contains('<details>'),
      );
    });
  });

  group('decodeSource', () {
    test('drops a UTF-8 BOM', () {
      final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode('# Title')];
      expect(service.decodeSource(bytes), '# Title');
    });

    test('replaces a malformed sequence rather than throwing', () {
      // A markdown file written in some other encoding should open with a few
      // odd glyphs, not fail to open.
      expect(() => service.decodeSource([0x68, 0x69, 0xFF]), returnsNormally);
      expect(service.decodeSource([0x68, 0x69, 0xFF]), startsWith('hi'));
    });
  });
}
