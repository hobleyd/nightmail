import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/entities/email_folder.dart';
import 'package:nightmail/presentation/widgets/email_folder_label.dart';

Email _email({
  String? parentFolderId,
  List<String> folderIds = const [],
}) =>
    Email(
      id: 'email-1',
      subject: 'Quarterly numbers',
      from: const EmailAddress(address: 'sender@example.com', name: 'Ada'),
      toRecipients: const [],
      ccRecipients: const [],
      bodyPreview: '',
      body: '',
      bodyType: EmailBodyType.text,
      isRead: true,
      receivedDateTime: DateTime(2026, 6, 10, 9),
      importance: EmailImportance.normal,
      parentFolderId: parentFolderId,
      folderIds: folderIds,
    );

EmailFolder _folder(String id, String name) => EmailFolder(
      id: id,
      displayName: name,
      totalItemCount: 0,
      unreadItemCount: 0,
    );

void main() {
  const names = {
    'inbox': 'Inbox',
    'sent': 'Sent Items',
    'label-7': 'Suppliers',
  };

  group('emailFolderLabel', () {
    // The pane already names the folder above the list; saying it again on
    // nearly every row would crowd out the sender for nothing.
    test('a message in the folder on screen gets no label', () {
      final label = emailFolderLabel(
        _email(folderIds: const ['inbox']),
        folderNames: names,
        currentFolder: _folder('inbox', 'Inbox'),
      );

      expect(label, isNull);
    });

    test('suppression does not depend on the folder tree knowing the folder',
        () {
      final label = emailFolderLabel(
        _email(folderIds: const ['archive-42']),
        folderNames: names,
        currentFolder: _folder('archive-42', 'Archive'),
      );

      expect(label, isNull);
    });

    // A Gmail message can be in the folder on screen *and* somewhere else at
    // once. Being here is what counts.
    test('a message in the folder on screen and elsewhere still gets no label',
        () {
      final label = emailFolderLabel(
        _email(folderIds: const ['inbox', 'label-7']),
        folderNames: names,
        currentFolder: _folder('inbox', 'Inbox'),
      );

      expect(label, isNull);
    });

    // The Sent copy a thread expansion brings into an Inbox listing — the case
    // this label exists for.
    test('a message from another folder names that folder', () {
      final label = emailFolderLabel(
        _email(folderIds: const ['sent']),
        folderNames: names,
        currentFolder: _folder('inbox', 'Inbox'),
      );

      expect(label, 'Sent Items');
    });

    test('a Gmail label that is not a folder is skipped, not shown raw', () {
      final label = emailFolderLabel(
        _email(folderIds: const ['UNREAD', 'CATEGORY_PERSONAL', 'label-7']),
        folderNames: names,
        currentFolder: _folder('inbox', 'Inbox'),
      );

      expect(label, 'Suppliers');
    });

    test('falls back to the parent folder when no label resolves', () {
      final label = emailFolderLabel(
        _email(parentFolderId: 'sent'),
        folderNames: names,
        currentFolder: _folder('inbox', 'Inbox'),
      );

      expect(label, 'Sent Items');
    });

    test('an unresolvable folder gets no brackets at all', () {
      final label = emailFolderLabel(
        _email(folderIds: const ['AAMkAGRaw==']),
        folderNames: names,
        currentFolder: _folder('inbox', 'Inbox'),
      );

      expect(label, isNull);
    });

    // Search results and a focused thread span the mailbox, so nothing is
    // suppressed there — the panel passes no current folder.
    test('every row names its folder when no folder is on screen', () {
      expect(
        emailFolderLabel(
          _email(folderIds: const ['label-7']),
          folderNames: names,
        ),
        'Suppliers',
      );
      expect(
        emailFolderLabel(
          _email(folderIds: const ['inbox']),
          folderNames: names,
        ),
        'Inbox',
      );
    });
  });

  group('folderLabelMaxWidth', () {
    test('is capped at 120 on a wide row', () {
      expect(folderLabelMaxWidth(800), 120);
    });

    test('leaves the narrow row to the sender and the date', () {
      expect(folderLabelMaxWidth(180), lessThan(70));
    });
  });
}
