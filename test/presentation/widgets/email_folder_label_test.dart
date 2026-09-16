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

  // The categories as the folder tree really exposes them: Gmail's
  // `getMailFolders` turns `CATEGORY_PERSONAL` into a folder displayed as
  // "Personal", so these ids resolve like any other.
  const categoryNames = {
    ...names,
    'CATEGORY_PERSONAL': 'Personal',
    'CATEGORY_PROMOTIONS': 'Promotions',
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
        _email(folderIds: const ['UNREAD', 'label-7']),
        folderNames: names,
        currentFolder: _folder('inbox', 'Inbox'),
      );

      expect(label, 'Suppliers');
    });

    // Gmail's categories *are* in the folder tree (`Category/Personal` and
    // friends), and Gmail's own label order routinely puts one ahead of the
    // label the user filed the message under — so the first id that resolves
    // is the wrong answer. A message nobody moved to Personal must not say it
    // is in Personal.
    test('a Gmail category never wins over the folder the message is filed in',
        () {
      final label = emailFolderLabel(
        _email(folderIds: const ['CATEGORY_PERSONAL', 'label-7']),
        folderNames: categoryNames,
        currentFolder: _folder('inbox', 'Inbox'),
      );

      expect(label, 'Suppliers');
    });

    // An archived message with nothing but a category on it. Saying nothing is
    // strictly better than pointing at a folder it was never put in.
    test('a message whose only folder is a Gmail category gets no brackets',
        () {
      expect(
        emailFolderLabel(
          _email(folderIds: const ['CATEGORY_PROMOTIONS']),
          folderNames: categoryNames,
          currentFolder: _folder('inbox', 'Inbox'),
        ),
        isNull,
      );
      // Including the parent-folder fallback, which must not reinstate what the
      // loop just skipped.
      expect(
        emailFolderLabel(
          _email(parentFolderId: 'CATEGORY_PERSONAL'),
          folderNames: categoryNames,
          currentFolder: _folder('inbox', 'Inbox'),
        ),
        isNull,
      );
    });

    // The five ids are a closed set; a user label is free to be called
    // anything, and swallowing one would be the bug in reverse.
    test('a user label that merely looks like a category still names itself',
        () {
      final label = emailFolderLabel(
        _email(folderIds: const ['CATEGORY_WHATEVER']),
        folderNames: const {'CATEGORY_WHATEVER': 'Receipts'},
        currentFolder: _folder('inbox', 'Inbox'),
      );

      expect(label, 'Receipts');
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
