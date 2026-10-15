import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/orphaned_thread_rows.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';

void main() {
  // Graph's shape: one folder per message, named by parentFolderId.
  Email email(String id, {required String folder, String? conversationId}) =>
      Email(
        id: id,
        subject: 'Subj',
        from: const EmailAddress(address: 's@example.com'),
        toRecipients: const [],
        ccRecipients: const [],
        bodyPreview: '',
        body: '',
        bodyType: EmailBodyType.text,
        isRead: true,
        receivedDateTime: DateTime(2026, 10, 15),
        importance: EmailImportance.normal,
        conversationId: conversationId ?? 'c1',
        parentFolderId: folder,
        folderIds: [folder],
      );

  List<String> ids(List<Email> emails) => emails.map((e) => e.id).toList();

  group('dropThreadsLeftOutsideFolder', () {
    // Regression: on Office 365 a message moved out of the Inbox vanished,
    // came back, and vanished again at the next sync. A listing answered from
    // a replica behind the move still named it under its old id; that id was
    // tombstoned, but the expansion had already fetched its thread — and the
    // moved copy, under the new id Graph assigned it in the destination.
    test('drops the moved copy and the thread context when nothing of the '
        'thread is left in the folder', () {
      final stale = email('X', folder: 'inbox');
      final moved = email('X2', folder: 'projects');
      final sent = email('S', folder: 'sent');
      final other = email('Y', folder: 'inbox', conversationId: 'c2');

      final result = dropThreadsLeftOutsideFolder(
        [moved, sent, other],
        removed: [stale],
        folderId: 'inbox',
      );

      expect(ids(result), ['Y']);
    });

    test('keeps the moved copy beside a sibling still in the folder', () {
      final stale = email('X', folder: 'inbox');
      final sibling = email('Y', folder: 'inbox');
      final moved = email('X2', folder: 'projects');

      final result = dropThreadsLeftOutsideFolder(
        [sibling, moved],
        removed: [stale],
        folderId: 'inbox',
      );

      expect(ids(result), ['Y', 'X2']);
    });

    // A thread can be listed with no message in the folder (Gmail lists by
    // thread). Removing one of its *other-folder* rows says nothing about
    // whether the thread belongs here.
    test('ignores a thread whose removed row was not in the folder', () {
      final removedSent = email('S', folder: 'sent');
      final archived = email('A', folder: 'archive');

      final result = dropThreadsLeftOutsideFolder(
        [archived],
        removed: [removedSent],
        folderId: 'inbox',
      );

      expect(ids(result), ['A']);
    });

    // Graph does not encode a folder id consistently; a listing whose rows
    // never compare equal to the folder id must not lose every thread the user
    // removed a message from.
    test('does nothing when the folder id does not match the rows', () {
      final stale = email('X', folder: 'AAMk-inbox');
      final moved = email('X2', folder: 'AAMk-projects');

      final result = dropThreadsLeftOutsideFolder(
        [moved],
        removed: [stale],
        folderId: 'AQMk-inbox',
      );

      expect(ids(result), ['X2']);
    });

    test('does nothing for a mailbox-wide listing', () {
      final stale = email('X', folder: 'inbox');
      final moved = email('X2', folder: 'projects');

      final result = dropThreadsLeftOutsideFolder(
        [moved],
        removed: [stale],
        folderId: null,
      );

      expect(ids(result), ['X2']);
    });
  });
}
