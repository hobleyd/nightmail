import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/linkify.dart';

void main() {
  group('linkifyPlainText', () {
    test('wraps a bare https URL and keeps the text around it', () {
      final runs = linkifyPlainText(
        'Timesheets are at https://intranet.example.com/app/timesheets thanks',
      );

      expect(runs.map((r) => r.text).join(),
          'Timesheets are at https://intranet.example.com/app/timesheets thanks');
      final links = runs.where((r) => r.isLink).toList();
      expect(links, hasLength(1));
      expect(links.single.text, 'https://intranet.example.com/app/timesheets');
      expect(links.single.url, 'https://intranet.example.com/app/timesheets');
    });

    test('gives a bare www. host a scheme to open, but not to display', () {
      final link =
          linkifyPlainText('see www.example.com/page for more').firstWhere(
        (r) => r.isLink,
      );

      expect(link.text, 'www.example.com/page');
      expect(link.url, 'https://www.example.com/page');
    });

    test('leaves text with no URL as a single run', () {
      final runs = linkifyPlainText('Nothing to see here.');
      expect(runs, hasLength(1));
      expect(runs.single.isLink, isFalse);
    });

    test('links a whole email address, never just the host inside it', () {
      final links = linkifyPlainText('mail someone@www.example.com today')
          .where((r) => r.isLink)
          .toList();

      expect(links, hasLength(1));
      expect(links.single.text, 'someone@www.example.com');
      expect(links.single.url, 'mailto:someone@www.example.com');
    });

    test('gives a bare address a mailto: to open, but not to display', () {
      final link = linkifyPlainText('Ask helpdesk@example.com about it')
          .firstWhere((r) => r.isLink);

      expect(link.text, 'helpdesk@example.com');
      expect(link.url, 'mailto:helpdesk@example.com');
    });

    test('keeps a mailto: URL the sender typed out in full', () {
      final link =
          linkifyPlainText('use mailto:sam@example.com?subject=Leave now')
              .firstWhere((r) => r.isLink);

      expect(link.text, 'mailto:sam@example.com?subject=Leave');
      expect(link.url, 'mailto:sam@example.com?subject=Leave');
    });

    test('a full stop after an address closed the sentence', () {
      final link = linkifyPlainText('Reply to sam@example.com.')
          .firstWhere((r) => r.isLink);

      expect(link.text, 'sam@example.com');
    });

    test('what only looks like an address is left alone', () {
      // A version suffix: the last label has to be alphabetic to be a host.
      expect(
          linkifyPlainText('pinned to package@1.2.3 today').where((r) => r.isLink),
          isEmpty);
      // A handle has no domain at all.
      expect(linkifyPlainText('ask @nightmail on the day').where((r) => r.isLink),
          isEmpty);
    });

    test('does not mistake the userinfo of a URL for an address', () {
      final link = linkifyPlainText('open https://user@example.com/a now')
          .firstWhere((r) => r.isLink);

      expect(link.url, 'https://user@example.com/a');
    });

    test('finds every URL in a multi-line body', () {
      final runs = linkifyPlainText(
        'First http://one.example.com\nSecond https://two.example.com\n',
      );
      expect(
        runs.where((r) => r.isLink).map((r) => r.url),
        ['http://one.example.com', 'https://two.example.com'],
      );
    });

    test('a domain without scheme or www is left alone', () {
      expect(linkifyPlainText('open report.example.com now').where((r) => r.isLink),
          isEmpty);
      expect(
          linkifyPlainText('upgraded to version 2.14.1 today')
              .where((r) => r.isLink),
          isEmpty);
    });
  });

  group('trimUrlTail', () {
    test('drops sentence punctuation', () {
      expect(trimUrlTail('https://x.example.com/a.'), 'https://x.example.com/a');
      expect(trimUrlTail('https://x.example.com/a,'), 'https://x.example.com/a');
      expect(
          trimUrlTail('https://x.example.com/a?b=1!'), 'https://x.example.com/a?b=1');
    });

    test('drops a paren that closed an aside but keeps a balanced pair', () {
      expect(trimUrlTail('https://x.example.com/a)'), 'https://x.example.com/a');
      expect(trimUrlTail('https://x.example.com/a_(b)'),
          'https://x.example.com/a_(b)');
    });

    test('drops a query separator with nothing after it', () {
      expect(trimUrlTail('https://x.example.com/a?b=1&amp;'),
          'https://x.example.com/a?b=1');
    });

    test('keeps a query string that legitimately ends in punctuation-free text',
        () {
      expect(trimUrlTail('https://x.example.com/a?b=1&amp;c=2'),
          'https://x.example.com/a?b=1&amp;c=2');
    });

    test('a plain text URL in brackets loses only the bracket', () {
      final link = linkifyPlainText('(see https://x.example.com/a) ok')
          .firstWhere((r) => r.isLink);
      expect(link.text, 'https://x.example.com/a');
    });
  });

  group('linkifyHtml', () {
    test('links a bare URL in body text', () {
      expect(
        linkifyHtml('<p>Go to https://intranet.example.com/app/timesheets now</p>'),
        '<p>Go to <a href="https://intranet.example.com/app/timesheets">'
        'https://intranet.example.com/app/timesheets</a> now</p>',
      );
    });

    test('leaves an existing anchor alone, text and href both', () {
      const html =
          '<p><a href="https://example.com/a">https://example.com/a</a></p>';
      expect(linkifyHtml(html), html);
    });

    test('does not touch attributes', () {
      const html = '<img src="https://example.com/pixel.gif" alt="x">';
      expect(linkifyHtml(html), html);
    });

    test('skips script and style contents', () {
      const html = '<style>a { background: url(https://example.com/x.png) }'
          '</style><script>var u = "https://example.com/y";</script>';
      expect(linkifyHtml(html), html);
    });

    test('resumes linking after an anchor closes', () {
      expect(
        linkifyHtml('<a href="https://a.example.com">click</a> '
            'or https://b.example.com'),
        '<a href="https://a.example.com">click</a> '
        'or <a href="https://b.example.com">https://b.example.com</a>',
      );
    });

    test('leaves a URL inside a comment alone', () {
      const html = '<!-- https://example.com/a --><p>hi</p>';
      expect(linkifyHtml(html), html);
    });

    test('an entity ends the URL wherever it appears in the text', () {
      expect(
        linkifyHtml('<p>https://example.com/a&nbsp;and more</p>'),
        '<p><a href="https://example.com/a">https://example.com/a</a>'
        '&nbsp;and more</p>',
      );
      // `<https://example.com/a>` as a sender typed it, escaped by their client.
      expect(
        linkifyHtml('<p>&lt;https://example.com/a&gt;</p>'),
        '<p>&lt;<a href="https://example.com/a">https://example.com/a</a>'
        '&gt;</p>',
      );
    });

    test('an escaped ampersand stays in the href', () {
      expect(
        linkifyHtml('<p>https://example.com/a?b=1&amp;c=2</p>'),
        '<p><a href="https://example.com/a?b=1&amp;c=2">'
        'https://example.com/a?b=1&amp;c=2</a></p>',
      );
    });

    test('a body with no URL comes back unchanged', () {
      const html = '<p>Nothing here.</p>';
      expect(linkifyHtml(html), same(html));
    });

    test('links a bare address in body text', () {
      expect(
        linkifyHtml('<p>Ask helpdesk@example.com first</p>'),
        '<p>Ask <a href="mailto:helpdesk@example.com">helpdesk@example.com</a>'
        ' first</p>',
      );
    });

    test('leaves an existing mailto anchor alone', () {
      const html = '<p><a href="mailto:sam@example.com">sam@example.com</a></p>';
      expect(linkifyHtml(html), html);
    });

    test('an address a sender wrapped in angle brackets keeps them out', () {
      expect(
        linkifyHtml('<p>Sam Chen &lt;sam@example.com&gt;</p>'),
        '<p>Sam Chen &lt;<a href="mailto:sam@example.com">sam@example.com</a>'
        '&gt;</p>',
      );
    });
  });
}
