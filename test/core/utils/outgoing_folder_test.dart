import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/outgoing_folder.dart';
import 'package:nightmail/domain/entities/email_folder.dart';

EmailFolder _folder(String id, String displayName) => EmailFolder(
      id: id,
      displayName: displayName,
      totalItemCount: 0,
      unreadItemCount: 0,
    );

void main() {
  group('isOutgoingMailFolder', () {
    // The three providers name and identify these folders differently, and the
    // anchor rule has to invert for all of them — see `groupIntoConversations`.
    test('Gmail is matched by its well-known label id', () {
      expect(isOutgoingMailFolder(_folder('SENT', 'Sent')), isTrue);
      expect(isOutgoingMailFolder(_folder('DRAFT', 'Drafts')), isTrue);
    });

    test('Graph is matched by display name, its ids being opaque', () {
      expect(
        isOutgoingMailFolder(_folder('AAMkAGMwOGJjZDQx', 'Sent Items')),
        isTrue,
      );
      expect(isOutgoingMailFolder(_folder('AAMkAGMwOGJjZDQx', 'Sent')), isTrue);
      expect(
        isOutgoingMailFolder(_folder('AAMkAGMwOGJjZDQx', 'Drafts')),
        isTrue,
      );
    });

    test('an IMAP path under INBOX is matched by its leaf display name', () {
      expect(isOutgoingMailFolder(_folder('INBOX.Sent', 'Sent')), isTrue);
    });

    test('the name match ignores case and surrounding space', () {
      expect(isOutgoingMailFolder(_folder('x', '  SENT ITEMS  ')), isTrue);
    });

    test('an incoming folder is not outgoing', () {
      expect(isOutgoingMailFolder(_folder('INBOX', 'Inbox')), isFalse);
      expect(isOutgoingMailFolder(_folder('TRASH', 'Deleted Items')), isFalse);
      expect(isOutgoingMailFolder(_folder('x', 'Harris Family')), isFalse);
    });

    // A folder whose name merely contains "sent" is not one.
    test('a name that only contains sent is not matched', () {
      expect(isOutgoingMailFolder(_folder('x', 'Consent forms')), isFalse);
      expect(isOutgoingMailFolder(_folder('x', 'Sent by courier')), isFalse);
    });

    // An unscoped view mixes both directions and wants the ordinary rule.
    test('no folder is not an outgoing folder', () {
      expect(isOutgoingMailFolder(null), isFalse);
    });
  });
}
