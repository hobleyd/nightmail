import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/models/email_model.dart';

void main() {
  // Regression: a delta-sync poll that hit one message without
  // receivedDateTime populated used to throw inside EmailModel.fromJson,
  // discarding the entire batch (including genuinely new mail in the same
  // response) and — because the crash happened before the delta token was
  // saved — repeating on every subsequent poll indefinitely.
  group('EmailModel.fromJson', () {
    Map<String, dynamic> baseJson({Object? receivedDateTime = '2026-06-01T12:00:00Z'}) => {
          'id': 'msg-1',
          'subject': 'Hello',
          'from': {'emailAddress': {'address': 'a@b.com', 'name': 'A'}},
          'toRecipients': <dynamic>[],
          'ccRecipients': <dynamic>[],
          'bodyPreview': 'preview',
          'isRead': false,
          'receivedDateTime': receivedDateTime,
          'importance': 'normal',
        };

    test('parses normally when receivedDateTime is present', () {
      final email = EmailModel.fromJson(baseJson());
      expect(email.receivedDateTime, DateTime.parse('2026-06-01T12:00:00Z'));
    });

    test('falls back instead of throwing when receivedDateTime is null', () {
      final email = EmailModel.fromJson(baseJson(receivedDateTime: null));
      expect(email.id, 'msg-1');
      expect(email.receivedDateTime, DateTime.fromMillisecondsSinceEpoch(0));
    });

    test('falls back instead of throwing when receivedDateTime is unparseable', () {
      final email = EmailModel.fromJson(baseJson(receivedDateTime: 'not-a-date'));
      expect(email.receivedDateTime, DateTime.fromMillisecondsSinceEpoch(0));
    });
  });
}
