import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/cloud_document_format.dart';

/// The one rule both drive datasources and the reading pane read. The markdown
/// split is what keeps a `.md` file looking the same in the pane whether it
/// arrived as an attachment or as a link to somebody's drive.
void main() {
  test('markdown is its own format, not plain text', () {
    for (final name in ['NOTES.md', 'a.markdown', 'b.mkd']) {
      expect(cloudDocumentFormatFor(name: name),
          CloudDocumentFormat.markdown, reason: name);
    }
    expect(
      cloudDocumentFormatFor(name: 'notes', contentType: 'text/markdown'),
      CloudDocumentFormat.markdown,
    );
  });

  test('plain text is unchanged by the split', () {
    expect(cloudDocumentFormatFor(name: 'a.txt'), CloudDocumentFormat.plainText);
    expect(cloudDocumentFormatFor(name: 'a.log'), CloudDocumentFormat.plainText);
    expect(
      cloudDocumentFormatFor(name: 'notes', contentType: 'text/plain'),
      CloudDocumentFormat.plainText,
    );
  });

  test('the other routes still answer', () {
    expect(cloudDocumentFormatFor(name: 'a.pdf'), CloudDocumentFormat.pdf);
    expect(cloudDocumentFormatFor(name: 'a.png'), CloudDocumentFormat.image);
    expect(cloudDocumentFormatFor(name: 'a.docx'),
        CloudDocumentFormat.officeConvertible);
  });

  test('an unrecognised file belongs in the browser', () {
    expect(cloudDocumentFormatFor(name: 'a.zip'), isNull);
  });
}
