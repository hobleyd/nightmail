import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/cloud_document_link.dart';
import 'package:nightmail/domain/entities/cloud_document.dart';

void main() {
  group('Microsoft 365 links', () {
    test('recognises a Word sharing link', () {
      final link = parseCloudDocumentLink(
          'https://contoso.sharepoint.com/:w:/g/personal/ann_contoso_com/Ee7abcdefghijklmnop?e=4TzQ1k');
      expect(link, isNotNull);
      expect(link!.provider, CloudDriveProvider.microsoft);
      // The whole URL travels: Graph resolves the sharing link itself.
      expect(link.url, contains('/:w:/g/personal/'));
      expect(link.fileId, isNull);
    });

    test('recognises an Excel redirect link', () {
      expect(
        parseCloudDocumentLink(
                'https://contoso.sharepoint.com/:x:/r/sites/Finance/Shared%20Documents/Budget.xlsx?d=w1234&csf=1')
            ?.provider,
        CloudDriveProvider.microsoft,
      );
    });

    test('recognises a plain document-library path', () {
      expect(
        parseCloudDocumentLink(
                'https://contoso.sharepoint.com/sites/Finance/Shared%20Documents/Budget.docx')
            ?.provider,
        CloudDriveProvider.microsoft,
      );
    });

    test('recognises OneDrive for Business on the -my host', () {
      expect(
        parseCloudDocumentLink(
                'https://contoso-my.sharepoint.com/:p:/g/personal/ann_contoso_com/EabcdefghijkLMNOP')
            ?.provider,
        CloudDriveProvider.microsoft,
      );
    });

    test('leaves a folder share link to the browser', () {
      expect(
        parseCloudDocumentLink(
            'https://contoso.sharepoint.com/:f:/g/personal/ann_contoso_com/Ee7abcdefghijklmnop'),
        isNull,
      );
    });

    test('leaves SharePoint application pages to the browser', () {
      expect(
        parseCloudDocumentLink(
            'https://contoso.sharepoint.com/sites/Finance/Shared%20Documents/Forms/AllItems.aspx'),
        isNull,
      );
      expect(
        parseCloudDocumentLink(
            'https://contoso.sharepoint.com/sites/Finance/_layouts/15/start.aspx'),
        isNull,
      );
      expect(
        parseCloudDocumentLink(
            'https://contoso.sharepoint.com/sites/Finance/Lists/Tasks/AllItems.aspx'),
        isNull,
      );
    });

    test('leaves a site root to the browser', () {
      expect(parseCloudDocumentLink('https://contoso.sharepoint.com'), isNull);
      expect(parseCloudDocumentLink('https://contoso.sharepoint.com/'), isNull);
      expect(
        parseCloudDocumentLink('https://contoso.sharepoint.com/sites/Finance'),
        isNull,
      );
      expect(
        parseCloudDocumentLink('https://contoso.sharepoint.com/teams/Group'),
        isNull,
      );
    });

    test('does not claim consumer OneDrive or its shortener', () {
      // Deliberately unsupported: a work account's token has no standing in a
      // personal OneDrive, and an anonymous share link needs no token at all —
      // so the browser does this better. See the note in the classifier.
      expect(parseCloudDocumentLink('https://1drv.ms/w/s!AabcdefG'), isNull);
      expect(
        parseCloudDocumentLink(
            'https://onedrive.live.com/edit.aspx?resid=ABC123&cid=abc'),
        isNull,
      );
    });
  });

  group('Google links', () {
    test('recognises a Drive file link', () {
      final link = parseCloudDocumentLink(
          'https://drive.google.com/file/d/1AbCdEfGhIjKlMnOpQrStUvWxYz/view?usp=sharing');
      expect(link?.provider, CloudDriveProvider.google);
      expect(link?.fileId, '1AbCdEfGhIjKlMnOpQrStUvWxYz');
    });

    test('recognises Docs, Sheets, Slides and Drawings', () {
      const ids = {
        'https://docs.google.com/document/d/1AbCdEfGhIjKlMnOp/edit':
            '1AbCdEfGhIjKlMnOp',
        'https://docs.google.com/spreadsheets/d/1QrStUvWxYz01234/edit#gid=0':
            '1QrStUvWxYz01234',
        'https://docs.google.com/presentation/d/1ZyXwVuTsRqPoNm/edit?usp=drive_link':
            '1ZyXwVuTsRqPoNm',
        'https://docs.google.com/drawings/d/1MnOpQrStUvWxYz/edit':
            '1MnOpQrStUvWxYz',
      };
      for (final entry in ids.entries) {
        final link = parseCloudDocumentLink(entry.key);
        expect(link?.fileId, entry.value, reason: entry.key);
      }
    });

    test('recognises the ?id= form', () {
      expect(
        parseCloudDocumentLink(
                'https://drive.google.com/open?id=1AbCdEfGhIjKlMnOpQ')
            ?.fileId,
        '1AbCdEfGhIjKlMnOpQ',
      );
      expect(
        parseCloudDocumentLink(
                'https://drive.google.com/uc?export=download&id=1AbCdEfGhIjKlMnOpQ')
            ?.fileId,
        '1AbCdEfGhIjKlMnOpQ',
      );
    });

    test('leaves folders and the Drive web UI to the browser', () {
      expect(
        parseCloudDocumentLink(
            'https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQ'),
        isNull,
      );
      expect(
        parseCloudDocumentLink('https://drive.google.com/drive/u/0/my-drive'),
        isNull,
      );
      expect(parseCloudDocumentLink('https://drive.google.com/'), isNull);
    });

    test('leaves forms and published documents to the browser', () {
      expect(
        parseCloudDocumentLink(
            'https://docs.google.com/forms/d/e/1FAIpQLSabcdefg/viewform'),
        isNull,
      );
      expect(
        parseCloudDocumentLink(
            'https://docs.google.com/document/d/e/2PACX-1vQabcdefghijk/pub'),
        isNull,
      );
    });

    test('rejects a URL with no plausible file id', () {
      expect(
        parseCloudDocumentLink('https://docs.google.com/document/d/edit'),
        isNull,
      );
      expect(
        parseCloudDocumentLink('https://drive.google.com/open?id=short'),
        isNull,
      );
    });
  });

  group('everything else goes to the browser', () {
    test('ordinary links, look-alike hosts and non-http schemes', () {
      const notDocuments = [
        'https://example.com/report.docx',
        'https://google.com/drive/file/d/1AbCdEfGhIjKlMn/view',
        // A look-alike host must not be treated as SharePoint.
        'https://sharepoint.com.evil.example/:w:/g/personal/x/Eabcdefghij',
        'https://notsharepoint.com/:w:/g/personal/x/Eabcdefghij',
        'mailto:ann@contoso.com',
        'javascript:void(0)',
        'not a url at all',
        '',
      ];
      for (final url in notDocuments) {
        expect(parseCloudDocumentLink(url), isNull, reason: url);
      }
    });
  });
}
