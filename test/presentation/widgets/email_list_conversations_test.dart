import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/presentation/widgets/email_list_conversations.dart';

const _addr = EmailAddress(address: 'a@b.com', name: 'A');

const _me = 'me@nightmail.test';

Email _email(
  String id, {
  String? conversationId,
  List<String> folderIds = const [],
  String? parentFolderId,
  int minute = 0,
  String? from,
}) =>
    Email(
      id: id,
      subject: 'Subject $id',
      from: from == null ? _addr : EmailAddress(address: from),
      toRecipients: const [],
      ccRecipients: const [],
      bodyPreview: '',
      body: '',
      bodyType: EmailBodyType.text,
      isRead: true,
      receivedDateTime: DateTime(2026, 6, 1, 9, minute),
      importance: EmailImportance.normal,
      conversationId: conversationId,
      parentFolderId: parentFolderId,
      folderIds: folderIds,
    );

/// A message the account itself sent.
Email _mine(String id, {String? conversationId, int minute = 0}) =>
    _email(id, conversationId: conversationId, minute: minute, from: _me);

void main() {
  // The toolbar and multi-select delete work off the selected row's id. A
  // conversation row is selected by the id of the newest message it shows, so
  // deleting that id alone used to leave the rest of the thread in the folder.
  group('resolveDeleteTargets', () {
    test('a selected conversation row deletes the thread, not one message', () {
      final targets = resolveDeleteTargets(
        emails: [
          _email('id1', conversationId: 'conv-a', minute: 3, folderIds: ['INBOX']),
          _email('id2', conversationId: 'conv-a', minute: 2, folderIds: ['INBOX']),
          _email('id3', conversationId: 'conv-a', minute: 1, folderIds: ['INBOX']),
        ],
        // id1 is newest, so it is the id the conversation row carries.
        selectedIds: ['id1'],
        currentFolderId: 'INBOX',
      );

      expect(targets.conversationIds, ['conv-a']);
      expect(targets.emailIds, isEmpty);
      expect(targets.removed.map((e) => e.id), ['id1', 'id2', 'id3']);
    });

    test('a standalone message stays a single delete', () {
      final targets = resolveDeleteTargets(
        emails: [
          _email('id1', conversationId: 'conv-a', folderIds: ['INBOX']),
          _email('id2', conversationId: 'conv-b', folderIds: ['INBOX']),
        ],
        selectedIds: ['id1'],
        currentFolderId: 'INBOX',
      );

      expect(targets.conversationIds, isEmpty);
      expect(targets.emailIds, ['id1']);
      expect(targets.removed.map((e) => e.id), ['id1']);
    });

    // Only the newest message heads the row; the others are child rows, which
    // stand for themselves.
    test('a child row of an expanded thread deletes only that message', () {
      final targets = resolveDeleteTargets(
        emails: [
          _email('id1', conversationId: 'conv-a', minute: 2, folderIds: ['INBOX']),
          _email('id2', conversationId: 'conv-a', minute: 1, folderIds: ['INBOX']),
        ],
        selectedIds: ['id2'],
        currentFolderId: 'INBOX',
      );

      expect(targets.conversationIds, isEmpty);
      expect(targets.emailIds, ['id2']);
    });

    test('a child row selected with its own thread row is not deleted twice',
        () {
      final targets = resolveDeleteTargets(
        emails: [
          _email('id1', conversationId: 'conv-a', minute: 2, folderIds: ['INBOX']),
          _email('id2', conversationId: 'conv-a', minute: 1, folderIds: ['INBOX']),
        ],
        selectedIds: ['id1', 'id2'],
        currentFolderId: 'INBOX',
      );

      expect(targets.conversationIds, ['conv-a']);
      expect(targets.emailIds, isEmpty);
      expect(targets.removed.map((e) => e.id), ['id1', 'id2']);
    });

    test('a mixed selection splits into thread and single deletes', () {
      final targets = resolveDeleteTargets(
        emails: [
          _email('id1', conversationId: 'conv-a', minute: 3, folderIds: ['INBOX']),
          _email('id2', conversationId: 'conv-a', minute: 2, folderIds: ['INBOX']),
          _email('solo', conversationId: 'conv-b', minute: 1, folderIds: ['INBOX']),
        ],
        selectedIds: ['id1', 'solo'],
        currentFolderId: 'INBOX',
      );

      expect(targets.conversationIds, ['conv-a']);
      expect(targets.emailIds, ['solo']);
      expect(targets.removed.map((e) => e.id), ['id1', 'id2', 'solo']);
    });

    // The badge deltas come off `removed`. Counting the messages that survive
    // the delete would walk the folder's totals below what it holds.
    test('what leaves the folder excludes the copies in Sent', () {
      final targets = resolveDeleteTargets(
        emails: [
          _email('id1', conversationId: 'conv-a', minute: 3, folderIds: ['INBOX']),
          _email('sent1', conversationId: 'conv-a', minute: 2, folderIds: ['SENT']),
          _email('filed1',
              conversationId: 'conv-a', minute: 1, folderIds: ['Archive']),
        ],
        selectedIds: ['id1'],
        currentFolderId: 'INBOX',
      );

      expect(targets.conversationIds, ['conv-a']);
      expect(targets.removed.map((e) => e.id), ['id1']);
    });

    test('a thread with nothing in this folder removes nothing', () {
      final targets = resolveDeleteTargets(
        emails: [
          _email('sent1', conversationId: 'conv-a', minute: 2, folderIds: ['SENT']),
          _email('filed1',
              conversationId: 'conv-a', minute: 1, folderIds: ['Archive']),
        ],
        selectedIds: ['sent1'],
        currentFolderId: 'INBOX',
      );

      // The thread delete is still dispatched — the BLoC is the one that owns
      // the decision, and it will find nothing to delete and leave the row be.
      expect(targets.conversationIds, ['conv-a']);
      expect(targets.removed, isEmpty);
    });

    // Deleting from a search or thread-focus view has no folder to scope to.
    test('an unscoped view counts every message of the thread', () {
      final targets = resolveDeleteTargets(
        emails: [
          _email('id1', conversationId: 'conv-a', minute: 2, folderIds: ['INBOX']),
          _email('sent1', conversationId: 'conv-a', minute: 1, folderIds: ['SENT']),
        ],
        selectedIds: ['id1'],
        currentFolderId: null,
      );

      expect(targets.removed.map((e) => e.id), ['id1', 'sent1']);
    });

    test('an id the list does not know is still deleted', () {
      final targets = resolveDeleteTargets(
        emails: [_email('id1', folderIds: ['INBOX'])],
        selectedIds: ['gone'],
        currentFolderId: 'INBOX',
      );

      expect(targets.emailIds, ['gone']);
      expect(targets.removed, isEmpty);
    });

    test('an empty selection targets nothing', () {
      final targets = resolveDeleteTargets(
        emails: [_email('id1', folderIds: ['INBOX'])],
        selectedIds: const [],
        currentFolderId: 'INBOX',
      );

      expect(targets.isEmpty, isTrue);
      expect(targets.removed, isEmpty);
    });

    // Messages with no conversationId group under their own id, and a
    // one-message group is drawn as a plain row, never a thread.
    test('an email with no conversation id is never a thread', () {
      final targets = resolveDeleteTargets(
        emails: [
          _email('id1', folderIds: ['INBOX']),
          _email('id2', folderIds: ['INBOX']),
        ],
        selectedIds: ['id1'],
        currentFolderId: 'INBOX',
      );

      expect(targets.conversationIds, isEmpty);
      expect(targets.emailIds, ['id1']);
    });
  });

  group('groupIntoConversations', () {
    test('groups by conversation id, newest message first', () {
      final conversations = groupIntoConversations([
        _email('old', conversationId: 'conv-a', minute: 1),
        _email('new', conversationId: 'conv-a', minute: 5),
        _email('solo', conversationId: 'conv-b', minute: 3),
      ]);

      expect(conversations.map((c) => c.id), ['conv-a', 'conv-b']);
      expect(conversations.first.latest.id, 'new');
      expect(conversations.first.emails.map((e) => e.id), ['new', 'old']);
    });

    test('falls back to the message id when there is no conversation id', () {
      final conversations = groupIntoConversations([_email('id1')]);

      expect(conversations.single.id, 'id1');
    });
  });

  // A row headed by the user's own reply tells them nothing they don't know.
  // The anchor is the newest message somebody else sent; the header shows it,
  // and the expansion shows the thread whole.
  group('conversation anchor', () {
    test('a thread the user has not answered is headed by its newest', () {
      final conv = groupIntoConversations([
        _email('a', conversationId: 'c', minute: 3),
        _email('b', conversationId: 'c', minute: 2),
        _email('c', conversationId: 'c', minute: 1),
      ], selfAddress: _me).single;

      expect(conv.anchor.id, 'a');
      // The anchor already heads the list, so repeating it directly beneath the
      // header it just filled would be noise.
      expect(conv.expandedEmails.map((e) => e.id), ['b', 'c']);
    });

    test("the user's own reply never heads the row", () {
      final conv = groupIntoConversations([
        _mine('my-reply-to-a', conversationId: 'c', minute: 5),
        _email('a', conversationId: 'c', minute: 4),
        _email('b', conversationId: 'c', minute: 3),
        _mine('my-reply-to-c', conversationId: 'c', minute: 2),
        _email('c', conversationId: 'c', minute: 1),
      ], selfAddress: _me).single;

      expect(conv.latest.id, 'my-reply-to-a');
      expect(conv.anchor.id, 'a');
      // The whole thread, in order — including the anchor, which the header is
      // already showing, because a reply sitting above nothing reads as a gap.
      expect(conv.expandedEmails.map((e) => e.id), [
        'my-reply-to-a',
        'a',
        'b',
        'my-reply-to-c',
        'c',
      ]);
      expect(conv.expandedEmails.where(conv.isAnchor).map((e) => e.id), ['a']);
    });

    test('a thread of nothing but the user is still headed by its newest', () {
      final conv = groupIntoConversations([
        _mine('sent2', conversationId: 'c', minute: 2),
        _mine('sent1', conversationId: 'c', minute: 1),
      ], selfAddress: _me).single;

      expect(conv.anchor.id, 'sent2');
      expect(conv.expandedEmails.map((e) => e.id), ['sent1']);
    });

    test('an unsent draft counts as the user own message', () {
      final conv = groupIntoConversations([
        _email('draft', conversationId: 'c', minute: 3, from: ''),
        _email('theirs', conversationId: 'c', minute: 2),
      ], selfAddress: _me).single;

      expect(conv.anchor.id, 'theirs');
    });

    test('the address match ignores case', () {
      final conv = groupIntoConversations([
        _email('mine', conversationId: 'c', minute: 2, from: 'ME@NightMail.test'),
        _email('theirs', conversationId: 'c', minute: 1),
      ], selfAddress: _me).single;

      expect(conv.anchor.id, 'theirs');
    });

    // Every thread is headed by its newest message when there is no account
    // address to compare against — the pre-anchor behaviour.
    test('no self address leaves every thread headed by its newest', () {
      final conv = groupIntoConversations([
        _mine('my-reply', conversationId: 'c', minute: 2),
        _email('theirs', conversationId: 'c', minute: 1),
      ]).single;

      expect(conv.anchor.id, 'my-reply');
      expect(conv.expandedEmails.map((e) => e.id), ['theirs']);
    });

    // The row shows the anchor, so ordering the list on anything else runs the
    // visible dates out of sequence.
    test('threads are ordered by their anchor, not their newest message', () {
      final conversations = groupIntoConversations([
        // Answered a week later: still the older thread as far as the list goes.
        _email('stale-them', conversationId: 'stale', minute: 1),
        _mine('stale-me', conversationId: 'stale', minute: 9),
        _email('fresh-them', conversationId: 'fresh', minute: 5),
      ], selfAddress: _me);

      expect(conversations.map((c) => c.id), ['fresh', 'stale']);
    });
  });

  group('resolveDeleteTargets with an anchor', () {
    // The row carries the anchor's id, not the thread's newest — so that is the
    // id a thread delete has to be recognised by.
    test('the anchor id selects the thread', () {
      final targets = resolveDeleteTargets(
        emails: [
          _mine('my-reply', conversationId: 'c', minute: 3),
          _email('theirs', conversationId: 'c', minute: 2),
          _email('older', conversationId: 'c', minute: 1),
        ],
        selectedIds: ['theirs'],
        currentFolderId: null,
        selfAddress: _me,
      );

      expect(targets.conversationIds, ['c']);
      expect(targets.emailIds, isEmpty);
    });

    test('the thread newest is a single delete once it is not the anchor', () {
      final targets = resolveDeleteTargets(
        emails: [
          _mine('my-reply', conversationId: 'c', minute: 3),
          _email('theirs', conversationId: 'c', minute: 2),
        ],
        selectedIds: ['my-reply'],
        currentFolderId: null,
        selfAddress: _me,
      );

      expect(targets.conversationIds, isEmpty);
      expect(targets.emailIds, ['my-reply']);
    });
  });
}
