// Pure-function tests for translating the search bar's query into each
// provider's syntax. No collaborators to mock.

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/mail_search_query.dart';

void main() {
  group('MailSearchQuery.parse', () {
    test('splits fields, quoted phrases and free text', () {
      final q = MailSearchQuery.parse(
        'from:alice subject:"quarterly report" invoice has:attachment',
      );

      expect(q.hasAttachment, isTrue);
      expect(
        [for (final t in q.terms) (t.field, t.value)],
        [('from', 'alice'), ('subject', 'quarterly report'), (null, 'invoice')],
      );
    });

    test('leaves times, URLs and unknown operators as free text', () {
      final q = MailSearchQuery.parse('10:30 https://x.io/a is:unread');

      expect(q.terms.map((t) => t.field), everyElement(isNull));
      expect(q.terms.map((t) => t.value), [
        '10:30',
        'https://x.io/a',
        'is:unread',
      ]);
    });

    test('a field with nothing after it is plain text', () {
      final q = MailSearchQuery.parse('from: alice');

      expect(q.terms.map((t) => (t.field, t.value)), [
        (null, 'from:'),
        (null, 'alice'),
      ]);
    });
  });

  group('graphSearchExpression', () {
    test('wraps free text for a body search and maps has:attachment', () {
      expect(
        graphSearchExpression('invoice has:attachment'),
        '"invoice hasAttachments:true"',
      );
    });

    test('escapes a quoted phrase inside the outer quotes', () {
      expect(
        graphSearchExpression(r'body:"net 30" a\b'),
        r'"body:\"net 30\" a\\b"',
      );
    });
  });

  group('gmailSearchQuery', () {
    test('drops body: — a bare term already searches the body', () {
      expect(
        gmailSearchQuery('Body:"net 30" from:alice'),
        '"net 30" from:alice',
      );
    });

    test('passes Gmail operators NightMail does not know through', () {
      expect(
        gmailSearchQuery('after:2026/01/01 label:work has:attachment'),
        'after:2026/01/01 label:work has:attachment',
      );
    });
  });

  group('imapSearchCriteria', () {
    test('free text becomes one TEXT criterion per word', () {
      expect(
        imapSearchCriteria('quarterly report'),
        'TEXT "quarterly" TEXT "report"',
      );
    });

    test('maps fields, keeps a phrase whole, drops has:attachment', () {
      expect(
        imapSearchCriteria('from:alice body:"net 30" has:attachment'),
        'FROM "alice" BODY "net 30"',
      );
    });

    test('maps cc: and skips operators IMAP cannot express', () {
      expect(
        imapSearchCriteria('cc:bob is:unread after:2026/01/01 10:30 http://x'),
        'CC "bob" TEXT "10:30" TEXT "http://x"',
      );
    });

    test('escapes quotes and backslashes', () {
      expect(imapSearchCriteria(r'"a\b c'), r'TEXT "\"a\\b" TEXT "c"');
    });

    test('declares UTF-8 for non-ASCII text', () {
      expect(imapSearchCriteria('café'), 'CHARSET UTF-8 TEXT "café"');
    });

    test('an empty query matches everything', () {
      expect(imapSearchCriteria('  '), 'ALL');
      expect(imapSearchCriteria('has:attachment'), 'ALL');
    });
  });
}
