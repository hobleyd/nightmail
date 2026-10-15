import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/local/pending_operations_datasource.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/infrastructure/sync/pending_removals.dart';
import 'package:nightmail/infrastructure/sync/recent_mutation_store.dart';

void main() {
  var nextId = 0;
  PendingOperationRecord op(
    String emailId,
    PendingOperationType type, {
    String? destination,
  }) =>
      PendingOperationRecord(
        id: nextId++,
        accountId: 'acc',
        emailId: emailId,
        folderId: null,
        opType: type,
        payload: destination == null
            ? '{}'
            : jsonEncode({'destinationFolderId': destination}),
        createdAtMs: nextId,
        retryCount: 0,
        lastError: null,
      );

  Email email(String id, String folder, {int day = 15}) => Email(
        id: id,
        subject: 'Subj',
        from: const EmailAddress(address: 's@example.com'),
        toRecipients: const [],
        ccRecipients: const [],
        bodyPreview: '',
        body: '',
        bodyType: EmailBodyType.text,
        isRead: true,
        receivedDateTime: DateTime(2026, 10, day),
        importance: EmailImportance.normal,
        conversationId: 'c-$id',
        parentFolderId: folder,
        folderIds: [folder],
      );

  late RecentMutationStore recent;
  setUp(() => recent = RecentMutationStore());

  group('tombstonedFor', () {
    test('a move is a removal from every folder but its destination', () {
      final removals = PendingRemovals.from('acc', [
        op('moved', PendingOperationType.move, destination: 'archive'),
        op('deleted', PendingOperationType.delete),
      ], recent);

      expect(removals.tombstonedFor('inbox'), {'moved', 'deleted'});
      expect(removals.tombstonedFor('archive'), {'deleted'});
      expect(removals.tombstonedFor(null), {'moved', 'deleted'},
          reason: 'a mailbox-wide listing has no destination to spare');
      expect(removals.all, {'moved', 'deleted'});
    });

    test('a recent removal carries its destination the same way', () {
      recent.recordRemoval('acc', 'moved', destinationFolderId: 'archive');
      recent.recordRemoval('acc', 'deleted');

      final removals = PendingRemovals.from('acc', const [], recent);

      expect(removals.tombstonedFor('archive'), {'deleted'});
      // Not an arrival on its own: on IMAP that id is the source's UID, which
      // the destination does not list — see the IMAP test below.
      expect(removals.arrivalsIn('archive'), isEmpty);
    });

    test('a recorded arrival a later move sent elsewhere is void', () {
      recent.recordArrival('acc', 'id', 'archive');
      final removals = PendingRemovals.from('acc', [
        op('id', PendingOperationType.move, destination: 'projects'),
      ], recent);

      expect(removals.arrivalsIn('archive'), isEmpty);
      expect(removals.arrivalsIn('projects'), {'id'});
      expect(removals.isArriving('id'), isTrue);
    });

    test('the last queued op for a message wins — a move then a delete is a '
        'delete everywhere', () {
      final removals = PendingRemovals.from('acc', [
        op('id', PendingOperationType.move, destination: 'archive'),
        op('id', PendingOperationType.delete),
      ], recent);

      expect(removals.tombstonedFor('archive'), {'id'});
      expect(removals.arrivalsIn('archive'), isEmpty);
    });

    test('a queued op outranks a recent entry for the same message', () {
      recent.recordRemoval('acc', 'id', destinationFolderId: 'archive');
      recent.recordArrival('acc', 'id', 'archive');

      final removals = PendingRemovals.from(
          'acc', [op('id', PendingOperationType.junk)], recent);

      expect(removals.tombstonedFor('archive'), {'id'});
      expect(removals.arrivalsIn('archive'), isEmpty);
    });
  });

  group('withArrivals', () {
    test('adds the cached copy of a moved-in message the page lacks, in date '
        'order', () async {
      final removals = PendingRemovals.from('acc', [
        op('moved', PendingOperationType.move, destination: 'archive'),
      ], recent);

      final result = await removals.withArrivals(
        [email('newer', 'archive', day: 20), email('older', 'archive', day: 1)],
        folderId: 'archive',
        cachedById: (id) async => email(id, 'archive', day: 10),
      );

      expect(result.map((e) => e.id), ['newer', 'moved', 'older']);
    });

    test('leaves the page alone when it already lists the message', () async {
      final removals = PendingRemovals.from('acc', [
        op('moved', PendingOperationType.move, destination: 'archive'),
      ], recent);
      var looked = false;

      final result = await removals.withArrivals(
        [email('moved', 'archive')],
        folderId: 'archive',
        cachedById: (id) async {
          looked = true;
          return null;
        },
      );

      expect(result.map((e) => e.id), ['moved']);
      expect(looked, isFalse);
    });

    test('skips a copy that is not cached, or not filed under the folder',
        () async {
      final removals = PendingRemovals.from('acc', [
        op('gone', PendingOperationType.move, destination: 'archive'),
        op('elsewhere', PendingOperationType.move, destination: 'archive'),
      ], recent);

      final result = await removals.withArrivals(
        [email('other', 'archive')],
        folderId: 'archive',
        cachedById: (id) async =>
            id == 'elsewhere' ? email(id, 'inbox') : null,
      );

      expect(result.map((e) => e.id), ['other']);
    });

    test('adds nothing to another folder or a mailbox-wide listing', () async {
      final removals = PendingRemovals.from('acc', [
        op('moved', PendingOperationType.move, destination: 'archive'),
      ], recent);
      Future<Email?> cached(String id) async => email(id, 'archive');

      expect(
        await removals.withArrivals(const [],
            folderId: 'inbox', cachedById: cached),
        isEmpty,
      );
      expect(
        await removals.withArrivals(const [],
            folderId: null, cachedById: cached),
        isEmpty,
      );
    });

    // Regression: the drain cannot learn the UID an IMAP destination assigns,
    // so it renames nothing. Treating the source id's acknowledged tombstone
    // as an arrival put the stale `INBOX:123` beside the real `Archive:456`.
    test('IMAP: an acknowledged move whose new id is unknown adds nothing',
        () async {
      recent.recordRemoval('acc', 'INBOX:123', destinationFolderId: 'Archive');
      final removals = PendingRemovals.from('acc', const [], recent);

      final result = await removals.withArrivals(
        [email('Archive:456', 'Archive')],
        folderId: 'Archive',
        cachedById: (id) async => email(id, 'Archive'),
      );

      expect(result.map((e) => e.id), ['Archive:456']);
    });

    test('a Graph move\'s new id, recorded as an arrival, is kept too',
        () async {
      recent.recordRemoval('acc', 'old-id', destinationFolderId: 'archive');
      recent.recordArrival('acc', 'new-id', 'archive');
      final removals = PendingRemovals.from('acc', const [], recent);

      final result = await removals.withArrivals(
        const [],
        folderId: 'archive',
        // The drain renamed the row; the old id is no longer cached.
        cachedById: (id) async =>
            id == 'new-id' ? email(id, 'archive') : null,
      );

      expect(result.map((e) => e.id), ['new-id']);
      expect(removals.tombstonedFor('archive'), isEmpty);
    });
  });
}
