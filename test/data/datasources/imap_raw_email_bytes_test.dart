import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/imap_datasource_impl.dart';

import 'imap_test_harness.dart';

/// `getRawEmailBytes` is the `.eml` a forward-as-attachment or an
/// attach-to-task sends on, so it has to be the message exactly as the server
/// holds it — every 8-bit byte included, whatever charset the body declares.
/// See [ImapTestHarness] for what the server keeps of the protocol.
void main() {
  late ImapTestHarness harness;

  setUp(() async {
    harness = await ImapTestHarness.start();
    addTearDown(harness.close);
  });

  List<int> message({required String charset, required List<int> body}) => [
        ...ascii.encode('From: Ana <ana@example.com>\r\n'
            'To: me@example.com\r\n'
            'Subject: Notes\r\n'
            'MIME-Version: 1.0\r\n'
            'Content-Type: text/plain; charset=$charset\r\n'
            'Content-Transfer-Encoding: 8bit\r\n'
            '\r\n'),
        ...body,
        13, 10,
      ];

  test('keeps an 8-bit UTF-8 body byte for byte', () async {
    final raw = message(
      charset: 'utf-8',
      body: utf8.encode('Teší ma — €5, 日本語'),
    );
    harness.imap.seedBytes('INBOX', uid: 7, raw: raw);

    final bytes = await harness.datasource.getRawEmailBytes('INBOX:7');

    expect(bytes, raw);
  });

  test('keeps a windows-1252 body byte for byte', () async {
    // "Café — 5€" in windows-1252: é is 0xE9, the dash 0x97, € 0x80. None of
    // it is valid UTF-8, so any decode-and-re-encode on the way shows here.
    final raw = message(
      charset: 'windows-1252',
      body: [0x43, 0x61, 0x66, 0xE9, 0x20, 0x97, 0x20, 0x35, 0x80],
    );
    harness.imap.seedBytes('INBOX', uid: 7, raw: raw);

    final bytes = await harness.datasource.getRawEmailBytes('INBOX:7');

    expect(bytes, raw);
  });

  test('reads the message from the folder its id names', () async {
    final raw = message(charset: 'utf-8', body: ascii.encode('filed'));
    harness.imap.seedBytes('Archive/2026', uid: 3, raw: raw);

    final bytes = await harness.datasource.getRawEmailBytes('Archive/2026:3');

    expect(bytes, raw);
    expect(harness.imap.commands, contains(startsWith('SELECT "Archive/2026"')));
  });

  group('rawBytesOfFetchedMessage', () {
    test('a literal answer is handed back as the very bytes', () {
      final raw = Uint8List.fromList(message(
        charset: 'windows-1252',
        body: [0x43, 0x61, 0x66, 0xE9],
      ));

      final bytes = rawBytesOfFetchedMessage(MimeMessage.parseFromData(raw));

      expect(bytes, raw);
    });

    test('a text answer is UTF-8 encoded, not cut to its low bytes', () {
      // What the fetch parser builds from a non-literal BODY[]: text the
      // response reader has already UTF-8-decoded.
      const text = 'Subject: Café — 日本\r\n\r\nTeší ma\r\n';

      final bytes = rawBytesOfFetchedMessage(MimeMessage.parseFromText(text));

      expect(utf8.decode(bytes), text);
      expect(bytes, utf8.encode(text),
          reason: 'code units would have turned 日 (U+65E5) into 0xE5');
    });
  });
}
