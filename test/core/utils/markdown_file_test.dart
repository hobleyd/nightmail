import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/markdown_file.dart';

/// One rule, read by the attachment chips and by `cloudDocumentFormatFor`, so
/// a `.md` file looks the same in the reading pane however it got there.
void main() {
  group('isMarkdownFile', () {
    test('claims the markdown extensions', () {
      for (final name in ['NOTES.md', 'read.markdown', 'a.mdown', 'b.mkd']) {
        expect(
          isMarkdownFile(name: name, contentType: 'text/plain'),
          isTrue,
          reason: name,
        );
      }
    });

    test('claims a markdown content type whatever the name', () {
      expect(
        isMarkdownFile(name: 'notes', contentType: 'text/markdown'),
        isTrue,
      );
      expect(
        isMarkdownFile(
          name: 'notes',
          contentType: 'text/x-markdown; charset=utf-8',
        ),
        isTrue,
      );
    });

    test('a bare text/plain is not a claim', () {
      // The common shape for a `.md` attachment is `text/plain`, so reading the
      // content type as a claim in its own right would make every `.txt`
      // attachment markdown.
      expect(
        isMarkdownFile(name: 'log.txt', contentType: 'text/plain'),
        isFalse,
      );
      expect(isMarkdownFile(name: 'report.pdf', contentType: null), isFalse);
    });

    test('is case-insensitive about the extension', () {
      expect(isMarkdownFile(name: 'README.MD', contentType: null), isTrue);
    });
  });
}
