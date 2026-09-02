import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/services/eml_parser.dart';
import 'package:nightmail/domain/entities/email.dart';

/// A 1x1 GIF — real bytes, so `decodeContentBinary` has something to decode.
const _gifB64 = 'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';

/// MIME is CRLF-delimited and `parseFromText` holds it to that, so the tests'
/// LF-delimited literals are converted rather than each carrying `\r\n`.
Uint8List _bytes(String mime) =>
    Uint8List.fromList(utf8.encode(mime.replaceAll('\n', '\r\n')));

/// A multipart/related message whose HTML references one image by `cid:`.
///
/// [disposition] is the part's `Content-Disposition` line, or the empty string
/// to omit the header entirely.
String _messageWithInlineImage({required String disposition}) => '''
From: Ada Lovelace <ada@example.com>
To: Grace Hopper <grace@example.com>
Cc: Alan Turing <alan@example.com>
Subject: Quarterly chart
Date: Tue, 2 Sep 2025 09:15:00 +1000
MIME-Version: 1.0
Content-Type: multipart/related; boundary="b1"

--b1
Content-Type: text/html; charset=utf-8

<html><body><p>See below.</p><img src="cid:chart@example.com"></body></html>
--b1
Content-Type: image/gif
Content-ID: <chart@example.com>
Content-Transfer-Encoding: base64
${disposition.isEmpty ? '' : '$disposition\n'}
$_gifB64
--b1--
''';

void main() {
  group('parseEmlBytes', () {
    test('reads the headers, body and recipients', () {
      final email = parseEmlBytes(EmlParseParams(
        bytes: _bytes(_messageWithInlineImage(disposition: '')),
        id: 'file.eml',
      ));

      expect(email.id, 'file.eml');
      expect(email.subject, 'Quarterly chart');
      expect(email.from.address, 'ada@example.com');
      expect(email.from.name, 'Ada Lovelace');
      expect(email.bodyType, EmailBodyType.html);
      expect(email.toRecipients.single.address, 'grace@example.com');
      expect(email.ccRecipients.single.address, 'alan@example.com');
    });

    // The bug this closes: the parser never populated `inlineAttachments`, and
    // `HtmlBodyView` resolves `cid:` tokens from that list alone — so every
    // inline image in a previewed .eml drew as a broken glyph.
    test('collects a cid image declared Content-Disposition: inline', () {
      final email = parseEmlBytes(EmlParseParams(
        bytes: _bytes(_messageWithInlineImage(
          disposition: 'Content-Disposition: inline',
        )),
        id: 'file.eml',
      ));

      final inline = email.inlineAttachments.single;
      expect(inline.contentId, contains('chart@example.com'));
      expect(inline.contentType, 'image/gif');
      expect(inline.contentBytes, isNotEmpty);
    });

    // Gmail tags pasted inline images `attachment` while still referencing them
    // by cid: in the HTML, so disposition is not what decides membership.
    test('collects a cid image declared Content-Disposition: attachment', () {
      final email = parseEmlBytes(EmlParseParams(
        bytes: _bytes(_messageWithInlineImage(
          disposition: 'Content-Disposition: attachment; filename="c.gif"',
        )),
        id: 'file.eml',
      ));

      expect(email.inlineAttachments.single.contentType, 'image/gif');
    });

    // `findContentInfo` matches disposition exactly, so it answers neither
    // query for a part carrying a Content-Id and no disposition header at all.
    test('collects a cid image with no Content-Disposition header', () {
      final email = parseEmlBytes(EmlParseParams(
        bytes: _bytes(_messageWithInlineImage(disposition: '')),
        id: 'file.eml',
      ));

      expect(email.inlineAttachments.single.contentType, 'image/gif');
    });

    test('does not treat a text part with a Content-Id as an image', () {
      const mime = '''
From: ada@example.com
Subject: Text only
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="b1"

--b1
Content-Type: text/plain

Hello.
--b1
Content-Type: text/plain
Content-ID: <note@example.com>

A note.
--b1--
''';
      final email = parseEmlBytes(
        EmlParseParams(bytes: _bytes(mime), id: 'file.eml'),
      );

      expect(email.inlineAttachments, isEmpty);
    });

    test('a plain-text message has no inline attachments', () {
      const mime = '''
From: ada@example.com
Subject: Plain
Content-Type: text/plain

Just text.
''';
      final email = parseEmlBytes(
        EmlParseParams(bytes: _bytes(mime), id: 'file.eml'),
      );

      expect(email.bodyType, EmailBodyType.text);
      expect(email.body.trim(), 'Just text.');
      expect(email.inlineAttachments, isEmpty);
    });

    test('malformed bytes yield an email rather than throwing', () {
      final email = parseEmlBytes(EmlParseParams(
        bytes: Uint8List.fromList([0xFF, 0xFE, 0x00, 0x01]),
        id: 'file.eml',
      ));

      expect(email.id, 'file.eml');
      expect(email.subject, isNotEmpty);
    });
  });

  group('EmlParser', () {
    test('parses off the isolate and returns the same result', () async {
      final email = await EmlParser().parse(
        _bytes(_messageWithInlineImage(disposition: '')),
        id: 'file.eml',
      );

      expect(email.subject, 'Quarterly chart');
      expect(email.inlineAttachments.single.contentType, 'image/gif');
    });
  });
}
