import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/widgets/html_body_view.dart';

void main() {
  group('forceUtf8Charset', () {
    test('replaces an Outlook Content-Type declaration with utf-8', () {
      // Verbatim head from a message that rendered "haven’t" as "havenâ€™t":
      // Outlook declares Windows-1252 in the body it then sent as UTF-8.
      const html = '<html>\n'
          '<head>\n'
          '<meta http-equiv="Content-Type" content="text/html; charset=Windows-1252">\n'
          '</head>\n'
          '<body><div>haven’t</div></body>\n'
          '</html>';

      final out = forceUtf8Charset(html);

      expect(out, contains('<meta charset="utf-8">'));
      expect(out.toLowerCase(), isNot(contains('windows-1252')));
      // The body itself is untouched — only the declaration was wrong.
      expect(out, contains('haven’t'));
    });

    test('replaces the HTML5 charset spelling too', () {
      const html = '<html><head><meta charset=windows-1252></head>'
          '<body>x</body></html>';

      final out = forceUtf8Charset(html);

      expect(out, contains('<meta charset="utf-8">'));
      expect(out.toLowerCase(), isNot(contains('windows-1252')));
    });

    test('declares utf-8 for a document that never declared anything', () {
      const html = '<html><head><title>Hi</title></head><body>x</body></html>';

      expect(forceUtf8Charset(html), contains('<meta charset="utf-8">'));
    });

    test('keeps the declaration inside the 1024-byte prescan window', () {
      // A mail-sized <style> block: anything appended at the end of the head
      // would sit past the window the prescan reads, and be ignored.
      final style = '<style>${'.a { color: red; }' * 200}</style>';
      final html = '<html><head>$style</head><body>x</body></html>';

      final out = forceUtf8Charset(html);

      expect(out.indexOf('<meta charset="utf-8">'), lessThan(1024));
    });

    test('declares utf-8 once, not once per stripped declaration', () {
      const html = '<html><head>'
          '<meta charset="iso-8859-1">'
          '<meta http-equiv="Content-Type" content="text/html; charset=Windows-1252">'
          '</head><body>x</body></html>';

      final out = forceUtf8Charset(html);

      expect('<meta charset="utf-8">'.allMatches(out).length, 1);
    });

    test('handles an implicit head', () {
      const html = '<meta charset="Windows-1252"></head><body>x</body>';

      final out = forceUtf8Charset(html);

      expect(out, startsWith('<meta charset="utf-8">'));
      expect(out.toLowerCase(), isNot(contains('windows-1252')));
    });

    test('strips a stray declaration from a bare fragment', () {
      // No head of its own: the caller supplies one, so this only has to make
      // sure the fragment cannot override it.
      const html = '<meta charset="Windows-1252"><div>x</div>';

      final out = forceUtf8Charset(html);

      expect(out, '<div>x</div>');
    });

    test('leaves a fragment with no declaration alone', () {
      expect(forceUtf8Charset('<div>x</div>'), '<div>x</div>');
    });

    test('leaves other meta tags in place', () {
      const html = '<html><head><meta name="viewport" content="width=100">'
          '</head><body>x</body></html>';

      expect(forceUtf8Charset(html), contains('<meta name="viewport"'));
    });
  });
}
