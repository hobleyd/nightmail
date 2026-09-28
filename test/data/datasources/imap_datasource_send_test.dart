import 'package:flutter_test/flutter_test.dart';

import 'imap_test_harness.dart';

/// Replies and forwards sent through a real (local) IMAP + SMTP dialogue.
/// See [ImapTestHarness] for what the servers keep of the protocol.
void main() {
  late ImapTestHarness harness;

  setUp(() async {
    harness = await ImapTestHarness.start();
    addTearDown(harness.close);
  });

  String original({String subject = 'Budget'}) =>
      'From: Alice <alice@example.com>\r\n'
      'To: me@example.com\r\n'
      'Subject: $subject\r\n'
      'Message-ID: <orig-1@example.com>\r\n'
      'MIME-Version: 1.0\r\n'
      'Content-Type: text/plain; charset=utf-8\r\n'
      '\r\n'
      'Hello there';

  group('replyToEmail', () {
    test('goes out over SMTP with "Re:" alone, even to a forward', () async {
      harness.imap.seed('INBOX', uid: 7, raw: original(subject: 'Fwd: Budget'));

      await harness.datasource.replyToEmail(
        messageId: 'INBOX:7',
        comment: 'Thanks',
      );

      final sent = harness.smtp.sent.single;
      expect(sent.message.decodeSubject(), 'Re: Budget');
      expect(sent.recipients, ['alice@example.com']);
      expect(sent.from, 'me@example.com');
      expect(
        sent.message.getHeaderValue('in-reply-to'),
        '<orig-1@example.com>',
      );
    });

    test('collapses a whole stack of prefixes', () async {
      harness.imap.seed(
        'INBOX',
        uid: 7,
        raw: original(subject: 'Re: RE: Fwd: FW: Budget'),
      );

      await harness.datasource.replyToEmail(
        messageId: 'INBOX:7',
        comment: 'Thanks',
      );

      expect(harness.smtp.sent.single.message.decodeSubject(), 'Re: Budget');
    });

    test('uses the compose subject when one is given', () async {
      harness.imap.seed('INBOX', uid: 7, raw: original());

      await harness.datasource.replyToEmail(
        messageId: 'INBOX:7',
        comment: 'Thanks',
        subject: 'Re: Budget (approved)',
      );

      expect(
        harness.smtp.sent.single.message.decodeSubject(),
        'Re: Budget (approved)',
      );
    });

    test(
      'fetches the original from its folder and files a Sent copy',
      () async {
        harness.imap.seed('INBOX', uid: 7, raw: original());

        await harness.datasource.replyToEmail(
          messageId: 'INBOX:7',
          comment: 'Thanks',
        );

        final commands = harness.imap.commands;
        final select = commands.indexWhere((c) => c.startsWith('SELECT'));
        final fetch = commands.indexWhere((c) => c.startsWith('UID FETCH 7'));
        expect(select, greaterThanOrEqualTo(0));
        expect(fetch, greaterThan(select));
        expect(commands[select], contains('INBOX'));

        final copy = harness.imap.appended.single;
        expect(copy.mailbox, 'Sent');
        expect(copy.flags, [r'\Seen']);
        expect(copy.message.decodeSubject(), 'Re: Budget');
      },
    );
  });

  group('forwardEmail', () {
    test('goes out with "Fwd:" alone, even for a reply', () async {
      harness.imap.seed('INBOX', uid: 3, raw: original(subject: 'Re: Budget'));

      await harness.datasource.forwardEmail(
        messageId: 'INBOX:3',
        toAddresses: ['bob@example.com'],
        comment: 'FYI',
      );

      final sent = harness.smtp.sent.single;
      expect(sent.message.decodeSubject(), 'Fwd: Budget');
      expect(sent.recipients, ['bob@example.com']);
    });

    test('normalises an existing "FW:" to "Fwd:"', () async {
      harness.imap.seed('INBOX', uid: 3, raw: original(subject: 'FW: Budget'));

      await harness.datasource.forwardEmail(
        messageId: 'INBOX:3',
        toAddresses: ['bob@example.com'],
        comment: 'FYI',
      );

      expect(harness.smtp.sent.single.message.decodeSubject(), 'Fwd: Budget');
    });

    test('uses the compose subject when one is given', () async {
      harness.imap.seed('INBOX', uid: 3, raw: original());

      await harness.datasource.forwardEmail(
        messageId: 'INBOX:3',
        toAddresses: ['bob@example.com'],
        comment: 'FYI',
        subject: 'Fwd: Budget (final)',
      );

      expect(
        harness.smtp.sent.single.message.decodeSubject(),
        'Fwd: Budget (final)',
      );
    });

    test('an empty compose subject falls back to the derived one', () async {
      harness.imap.seed('INBOX', uid: 3, raw: original());

      await harness.datasource.forwardEmail(
        messageId: 'INBOX:3',
        toAddresses: ['bob@example.com'],
        comment: 'FYI',
        subject: '   ',
      );

      expect(harness.smtp.sent.single.message.decodeSubject(), 'Fwd: Budget');
    });
  });
}
