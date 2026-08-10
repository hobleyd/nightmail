import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/presentation/blocs/email_list/email_list_state.dart';
import 'package:nightmail/presentation/widgets/reading_pane.dart';

Email _email(
  String id, {
  bool isRead = true,
  bool isFlagged = false,
  String? parentFolderId,
  DateTime? receivedDateTime,
}) =>
    Email(
      id: id,
      subject: 'Subject $id',
      from: const EmailAddress(address: 'a@b.com', name: 'A'),
      toRecipients: const [],
      ccRecipients: const [],
      bodyPreview: '',
      body: '',
      bodyType: EmailBodyType.text,
      isRead: isRead,
      isFlagged: isFlagged,
      receivedDateTime: receivedDateTime ?? DateTime(2026, 6, 10),
      importance: EmailImportance.normal,
      parentFolderId: parentFolderId,
    );

EmailListLoaded _list(
  List<Email> emails, {
  String? activeSearchQuery,
  String? focusedThreadId,
}) =>
    EmailListLoaded(
      emails: emails,
      currentFolderId: 'folder-1',
      activeSearchQuery: activeSearchQuery,
      focusedThreadId: focusedThreadId,
    );

void main() {
  group('openMessageSyncAction', () {
    test('does nothing when the listed row matches what is on screen', () {
      final open = _email('id1');
      expect(
        openMessageSyncAction(
          open: open,
          list: _list([_email('id1'), _email('id2')]),
          knownIds: const {'id1', 'id2'},
        ),
        OpenMessageSyncAction.none,
      );
    });

    test('refreshes when the message was read on another machine', () {
      expect(
        openMessageSyncAction(
          open: _email('id1', isRead: false),
          list: _list([_email('id1')]),
          knownIds: const {'id1'},
        ),
        OpenMessageSyncAction.refresh,
      );
    });

    test('refreshes when the message was flagged on another machine', () {
      expect(
        openMessageSyncAction(
          open: _email('id1'),
          list: _list([_email('id1', isFlagged: true)]),
          knownIds: const {'id1'},
        ),
        OpenMessageSyncAction.refresh,
      );
    });

    // A stale parentFolderId sends the folder-count delta of a delete to the
    // wrong folder's badge.
    test('refreshes when the message was moved to another folder', () {
      expect(
        openMessageSyncAction(
          open: _email('id1', parentFolderId: 'folder-1'),
          list: _list([_email('id1', parentFolderId: 'folder-9')]),
          knownIds: const {'id1'},
        ),
        OpenMessageSyncAction.refresh,
      );
    });

    test('closes the pane when the message it listed has gone', () {
      expect(
        openMessageSyncAction(
          open: _email('id1', receivedDateTime: DateTime(2026, 6, 10)),
          list: _list([_email('id2', receivedDateTime: DateTime(2026, 6, 9))]),
          knownIds: const {'id1', 'id2'},
        ),
        OpenMessageSyncAction.close,
      );
    });

    // Search results and a focused thread are not the folder's contents, so
    // absence from them says nothing about whether the message still exists.
    test('leaves search results alone', () {
      expect(
        openMessageSyncAction(
          open: _email('id1'),
          list: _list([_email('hit')], activeSearchQuery: 'q'),
          knownIds: const {'id1'},
        ),
        OpenMessageSyncAction.none,
      );
    });

    test('leaves a focused thread alone', () {
      expect(
        openMessageSyncAction(
          open: _email('id1'),
          list: _list([_email('other')], focusedThreadId: 'conv-a'),
          knownIds: const {'id1'},
        ),
        OpenMessageSyncAction.none,
      );
    });

    // A message opened from a task, from another folder, or parsed out of a
    // .eml attachment was never in this listing — its absence is not news.
    test('does not close a message the listing never held', () {
      expect(
        openMessageSyncAction(
          open: _email('elsewhere'),
          list: _list([_email('id1')]),
          knownIds: const {'id1'},
        ),
        OpenMessageSyncAction.none,
      );
    });

    test('does not close on the first listing it has seen', () {
      expect(
        openMessageSyncAction(
          open: _email('id1'),
          list: _list([_email('id2')]),
          knownIds: null,
        ),
        OpenMessageSyncAction.none,
      );
    });

    // A network refresh truncates the list back to its first page, so a message
    // opened from page three drops out of it without going anywhere.
    test('does not close a message that fell out of the loaded window', () {
      expect(
        openMessageSyncAction(
          open: _email('old', receivedDateTime: DateTime(2026, 5, 1)),
          list: _list([
            _email('new1', receivedDateTime: DateTime(2026, 6, 10)),
            _email('new2', receivedDateTime: DateTime(2026, 6, 9)),
          ]),
          knownIds: const {'old', 'new1', 'new2'},
        ),
        OpenMessageSyncAction.none,
      );
    });

    test('an empty listing is not proof the message has gone', () {
      expect(
        openMessageSyncAction(
          open: _email('id1'),
          list: _list(const []),
          knownIds: const {'id1'},
        ),
        OpenMessageSyncAction.none,
      );
    });
  });
}
