import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/presentation/widgets/email_list_correspondent.dart';

const _me = EmailAddress(address: 'me@example.com', name: 'Me');
const _ada = EmailAddress(address: 'ada@example.com', name: 'Ada');
const _bob = EmailAddress(address: 'bob@example.com', name: 'Bob');
const _cat = EmailAddress(address: 'cat@example.com', name: 'Cat');

Email _email({
  EmailAddress from = _ada,
  List<EmailAddress> to = const [_me],
  List<EmailAddress> cc = const [],
}) =>
    Email(
      id: 'e',
      subject: 's',
      from: from,
      toRecipients: to,
      ccRecipients: cc,
      bodyPreview: '',
      body: '',
      bodyType: EmailBodyType.text,
      isRead: true,
      receivedDateTime: DateTime(2026, 9, 1),
      importance: EmailImportance.normal,
      hasAttachments: false,
    );

void main() {
  group('showsRecipients', () {
    test('never in an incoming folder, even for the reader\'s own message', () {
      expect(
        showsRecipients(_email(from: _me, to: const [_ada]),
            outgoingFolder: false, selfAddress: 'me@example.com'),
        isFalse,
      );
    });

    test('for the reader\'s own message in an outgoing folder', () {
      expect(
        showsRecipients(_email(from: _me, to: const [_ada]),
            outgoingFolder: true, selfAddress: 'me@example.com'),
        isTrue,
      );
    });

    test('compares the address case-insensitively and trimmed', () {
      expect(
        showsRecipients(_email(from: _me, to: const [_ada]),
            outgoingFolder: true, selfAddress: '  Me@Example.COM '),
        isTrue,
      );
    });

    test('not for a correspondent\'s reply expanded into a Sent listing', () {
      // Both providers surface the Inbox copies of a thread alongside its Sent
      // page; those rows still say who wrote back.
      expect(
        showsRecipients(_email(from: _ada, to: const [_me]),
            outgoingFolder: true, selfAddress: 'me@example.com'),
        isFalse,
      );
    });

    test('an unsent draft (empty from) counts as the reader\'s own', () {
      expect(
        showsRecipients(
            _email(from: const EmailAddress(address: ''), to: const [_ada]),
            outgoingFolder: true,
            selfAddress: 'me@example.com'),
        isTrue,
      );
    });

    test('with no self address every row in an outgoing folder qualifies', () {
      expect(
        showsRecipients(_email(from: _ada), outgoingFolder: true),
        isTrue,
      );
      expect(
        showsRecipients(_email(from: _ada),
            outgoingFolder: true, selfAddress: ''),
        isTrue,
      );
    });
  });

  group('emailListCorrespondent', () {
    test('names the sender by default', () {
      expect(emailListCorrespondent(_email()), 'Ada');
    });

    test('names the recipients when asked', () {
      expect(
        emailListCorrespondent(_email(from: _me, to: const [_ada, _bob]),
            showRecipients: true),
        'To: Ada, Bob',
      );
    });

    test('lists two recipients, then elides', () {
      expect(
        emailListCorrespondent(_email(from: _me, to: const [_ada, _bob, _cat]),
            showRecipients: true),
        'To: Ada, Bob…',
      );
    });

    test('falls back to the address for a recipient with no name', () {
      expect(
        emailListCorrespondent(
            _email(from: _me, to: const [EmailAddress(address: 'x@example.com')]),
            showRecipients: true),
        'To: x@example.com',
      );
    });

    test('uses Cc when nobody is in To', () {
      expect(
        emailListCorrespondent(_email(from: _me, to: const [], cc: const [_bob]),
            showRecipients: true),
        'To: Bob',
      );
    });

    test('falls back to the sender when there are no recipients at all', () {
      // A Bcc-only message: the row still has to say something.
      expect(
        emailListCorrespondent(_email(from: _me, to: const []),
            showRecipients: true),
        'Me',
      );
    });

    test('an unsent draft shows its recipients without being asked', () {
      expect(
        emailListCorrespondent(
            _email(from: const EmailAddress(address: ''), to: const [_bob])),
        'To: Bob',
      );
    });

    test('is blank only when there is neither sender nor recipient', () {
      expect(
        emailListCorrespondent(
            _email(from: const EmailAddress(address: ''), to: const [])),
        '',
      );
    });
  });
}
