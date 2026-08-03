import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';

Email _email({
  String? parentFolderId,
  List<String> folderIds = const [],
}) =>
    Email(
      id: 'id',
      subject: 'Subject',
      from: const EmailAddress(address: 'a@b.com', name: 'A'),
      toRecipients: const [],
      ccRecipients: const [],
      bodyPreview: '',
      body: '',
      bodyType: EmailBodyType.text,
      isRead: true,
      receivedDateTime: DateTime(2026),
      importance: EmailImportance.normal,
      parentFolderId: parentFolderId,
      folderIds: folderIds,
    );

void main() {
  // ---------------------------------------------------------------------------
  // isInFolder
  // ---------------------------------------------------------------------------

  group('isInFolder', () {
    test('folderIds decides when the provider reported membership', () {
      final email = _email(folderIds: ['INBOX', 'Label_7']);

      expect(email.isInFolder('INBOX'), isTrue);
      expect(email.isInFolder('Label_7'), isTrue);
      expect(email.isInFolder('SENT'), isFalse);
    });

    // Gmail is the reason folderIds exists: a message can be in several
    // folders at once, which one parent id cannot express.
    test('a message in several folders is in every one of them', () {
      final email = _email(
        parentFolderId: 'INBOX',
        folderIds: ['INBOX', 'SENT', 'Label_7'],
      );

      expect(email.isInFolder('INBOX'), isTrue);
      expect(email.isInFolder('SENT'), isTrue);
      expect(email.isInFolder('Label_7'), isTrue);
      expect(email.isInFolder('Label_9'), isFalse);
    });

    test('falls back to parentFolderId when membership is unreported', () {
      expect(_email(parentFolderId: 'inbox').isInFolder('inbox'), isTrue);
      expect(_email(parentFolderId: 'archive').isInFolder('inbox'), isFalse);
    });

    // Cross-folder additions always carry a real parent id, so a null one means
    // the message came straight from the folder query.
    test('a null parentFolderId with no folderIds counts as in-folder', () {
      expect(_email().isInFolder('inbox'), isTrue);
    });

    test('everything is in an unscoped view', () {
      expect(_email(parentFolderId: 'archive').isInFolder(null), isTrue);
      expect(_email(folderIds: ['SENT']).isInFolder(null), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // isDeletableFrom
  // ---------------------------------------------------------------------------

  group('isDeletableFrom', () {
    test('an in-folder message is deletable', () {
      expect(_email(folderIds: ['INBOX']).isDeletableFrom('INBOX'), isTrue);
      expect(_email(parentFolderId: 'inbox').isDeletableFrom('inbox'), isTrue);
      expect(_email().isDeletableFrom('inbox'), isTrue);
    });

    test('a message filed in another folder is not', () {
      expect(_email(folderIds: ['Archive']).isDeletableFrom('INBOX'), isFalse);
      expect(_email(parentFolderId: 'archive').isDeletableFrom('inbox'), isFalse);
    });

    // The bug this rule exists for: Gmail hands the Inbox listing every message
    // in the thread, and the sent replies carry no folder the Inbox view knows,
    // so nothing but the SENT label distinguishes them.
    test('the copy in Sent survives a delete from another folder', () {
      final sent = _email(folderIds: ['SENT']);

      expect(sent.isDeletableFrom('INBOX'), isFalse);
      expect(_email(folderIds: ['DRAFT']).isDeletableFrom('INBOX'), isFalse);
    });

    test('a sent message also carrying the folder being viewed survives', () {
      final sentAndLabelled = _email(folderIds: ['SENT', 'Label_7']);

      expect(sentAndLabelled.isInFolder('Label_7'), isTrue,
          reason: 'it really is in that label');
      expect(sentAndLabelled.isDeletableFrom('Label_7'), isFalse,
          reason: 'but deleting the thread must not destroy the sent record');
    });

    test('viewing Sent itself deletes from Sent', () {
      expect(_email(folderIds: ['SENT']).isDeletableFrom('SENT'), isTrue);
      expect(_email(folderIds: ['DRAFT']).isDeletableFrom('DRAFT'), isTrue);
    });

    // Providers that put a message in exactly one folder need no sent guard —
    // membership already rules the Sent copy out — and their opaque folder ids
    // would not match 'SENT' anyway.
    test('a single-folder provider is governed by membership alone', () {
      final graphSent = _email(
        parentFolderId: 'AAMkAGsentitems',
        folderIds: ['AAMkAGsentitems'],
      );

      expect(graphSent.isDeletableFrom('AAMkAGinbox'), isFalse);
      expect(graphSent.isDeletableFrom('AAMkAGsentitems'), isTrue);
    });

    test('an unscoped view deletes everything shown', () {
      expect(_email(folderIds: ['SENT']).isDeletableFrom(null), isTrue);
      expect(_email(parentFolderId: 'archive').isDeletableFrom(null), isTrue);
    });
  });
}
