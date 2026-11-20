import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/domain/entities/email.dart';

import 'imap_test_harness.dart';

/// The IMAP commands behind NightMail's own rules, driven through a real
/// (local) IMAP dialogue — see [ImapTestHarness].
void main() {
  late ImapTestHarness harness;

  setUp(() async {
    harness = await ImapTestHarness.start();
    addTearDown(harness.close);
  });

  String message(String subject) =>
      'From: Alice <alice@example.com>\r\n'
      'To: me@example.com\r\n'
      'Subject: $subject\r\n'
      'MIME-Version: 1.0\r\n'
      'Content-Type: text/plain; charset=utf-8\r\n'
      '\r\n'
      'Body of $subject';

  group('fetchInboxArrivals', () {
    test('reports UIDVALIDITY, UIDNEXT and keyword support', () async {
      harness.imap.seed('INBOX', uid: 3, raw: message('a'));
      harness.imap.seed('INBOX', uid: 9, raw: message('b'));

      final now = await harness.datasource.fetchInboxArrivals(
        afterUid: null,
        limit: 0,
      );

      expect(now.uidValidity, 1);
      expect(now.lastExistingUid, 9);
      // The scripted server lists `\*` in PERMANENTFLAGS.
      expect(now.keywordsAllowed, isTrue);
      expect(now.messages, isEmpty);
    });

    test('returns only UIDs above the mark, oldest first', () async {
      for (final uid in [3, 9, 12]) {
        harness.imap.seed('INBOX', uid: uid, raw: message('m$uid'));
      }

      final arrivals = await harness.datasource.fetchInboxArrivals(
        afterUid: 3,
        limit: 50,
      );

      expect(arrivals.messages.map((m) => m.id), ['INBOX:9', 'INBOX:12']);
    });

    test('nothing new reads as nothing, despite `n:*` matching the last '
        'message', () async {
      // `UID 13:*` with 12 the highest UID still matches 12 on a real
      // server: `*` is the last message and the range is unordered.
      harness.imap.seed('INBOX', uid: 12, raw: message('old'));

      final arrivals = await harness.datasource.fetchInboxArrivals(
        afterUid: 12,
        limit: 50,
      );

      expect(arrivals.messages, isEmpty);
    });

    test('caps the batch', () async {
      for (var uid = 1; uid <= 5; uid++) {
        harness.imap.seed('INBOX', uid: uid, raw: message('m$uid'));
      }

      final arrivals = await harness.datasource.fetchInboxArrivals(
        afterUid: 0,
        limit: 2,
      );

      expect(arrivals.messages.map((m) => m.id), ['INBOX:1', 'INBOX:2']);
    });

    test('leaves out claimed mail when the server keeps keywords', () async {
      harness.imap.seed('INBOX', uid: 4, raw: message('a'));

      await harness.datasource.fetchInboxArrivals(
        afterUid: 0,
        limit: 50,
        excludeKeyword: r'$NightMailRules',
      );

      expect(
        harness.imap.commands.where((c) => c.contains('SEARCH')).single,
        contains(r'UNKEYWORD $NightMailRules'),
      );
    });
  });

  test('peekEmail reads the body without setting \\Seen', () async {
    harness.imap.seed('INBOX', uid: 7, raw: message('Invoice'));

    final email = await harness.datasource.peekEmail('INBOX:7');

    expect(email.body, contains('Body of Invoice'));
    final fetch = harness.imap.commands.lastWhere((c) => c.contains('FETCH'));
    expect(fetch, contains('BODY.PEEK[]'));
  });

  test('addFlags stores the flags on the message', () async {
    harness.imap.seed('INBOX', uid: 7, raw: message('x'));

    await harness.datasource.addFlags('INBOX:7', [r'\Flagged']);

    expect(
      harness.imap.commands.last,
      allOf(contains('UID STORE 7 +FLAGS'), contains(r'\Flagged')),
    );
  });

  test('copyEmail copies to the destination by UID', () async {
    harness.imap.seed('INBOX', uid: 7, raw: message('x'));

    await harness.datasource.copyEmail('INBOX:7', 'Receipts');

    expect(harness.imap.commands.last, 'UID COPY 7 Receipts');
  });

  test('a rule forward is marked Auto-Submitted', () async {
    harness.imap.seed('INBOX', uid: 7, raw: message('Invoice'));

    await harness.datasource.forwardForRule(
      messageId: 'INBOX:7',
      toAddresses: ['boss@example.com'],
      comment: 'Forwarded',
      bodyType: EmailBodyType.text,
    );

    final sent = harness.smtp.sent.single.message;
    expect(sent.getHeaderValue('auto-submitted'), 'auto-forwarded');
  });

  test('a user forward is not marked Auto-Submitted', () async {
    harness.imap.seed('INBOX', uid: 7, raw: message('Invoice'));

    await harness.datasource.forwardEmail(
      messageId: 'INBOX:7',
      toAddresses: ['boss@example.com'],
      comment: 'FYI',
    );

    expect(
      harness.smtp.sent.single.message.getHeaderValue('auto-submitted'),
      isNull,
    );
  });

  test('trashEmail refuses, rather than expunging, with no Trash', () async {
    // The scripted server has INBOX and Sent only.
    harness.imap.seed('INBOX', uid: 7, raw: message('x'));

    await expectLater(
      harness.datasource.trashEmail('INBOX:7'),
      throwsA(isA<ServerException>()),
    );
    expect(
      harness.imap.commands.where(
        (c) => c.contains('STORE') || c.contains('EXPUNGE'),
      ),
      isEmpty,
    );
  });
}
