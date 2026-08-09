import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/usecases/cache_emails.dart';
import 'package:nightmail/domain/usecases/classify_emails.dart';
import 'package:nightmail/domain/usecases/clear_email_cache_for_folder.dart';
import 'package:nightmail/domain/usecases/delete_email.dart';
import 'package:nightmail/domain/usecases/empty_folder.dart';
import 'package:nightmail/domain/usecases/get_cached_emails.dart';
import 'package:nightmail/domain/usecases/get_conversation_thread.dart';
import 'package:nightmail/domain/usecases/get_email.dart';
import 'package:nightmail/domain/usecases/get_emails.dart';
import 'package:nightmail/domain/usecases/mark_email_as_read.dart';
import 'package:nightmail/domain/usecases/move_email.dart';
import 'package:nightmail/domain/usecases/record_known_senders.dart';
import 'package:nightmail/domain/usecases/report_junk.dart';
import 'package:nightmail/domain/usecases/search_emails.dart';
import 'package:nightmail/domain/usecases/train_spam_filter.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/sync/outbox_drain_service.dart';
import 'package:nightmail/infrastructure/sync/spam_db_sync_service.dart';
import 'package:nightmail/presentation/blocs/email_list/email_list_bloc.dart';
import 'package:nightmail/presentation/blocs/email_list/email_list_event.dart';
import 'package:nightmail/presentation/blocs/email_list/email_list_state.dart';

import 'email_list_bloc_test.mocks.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _addr = EmailAddress(address: 'a@b.com', name: 'A');

Email _email(
  String id, {
  String? conversationId,
  bool isRead = true,
  String? parentFolderId,
  List<String> folderIds = const [],
}) =>
    Email(
      id: id,
      subject: 'Subject $id',
      from: _addr,
      toRecipients: const [],
      ccRecipients: const [],
      bodyPreview: '',
      body: '',
      bodyType: EmailBodyType.text,
      isRead: isRead,
      receivedDateTime: DateTime(2026),
      importance: EmailImportance.normal,
      conversationId: conversationId,
      parentFolderId: parentFolderId,
      folderIds: folderIds,
    );

// Fake AccountManager that always reports no active account — keeps the BLoC
// from attempting cache writes or spam classification in tests.
class _FakeAccountManager extends Fake implements AccountManager {
  @override
  Account? get activeAccount => null;
}

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

@GenerateMocks([
  GetEmails,
  GetCachedEmails,
  CacheEmails,
  MarkEmailAsRead,
  MoveEmail,
  ReportJunk,
  DeleteEmail,
  EmptyFolder,
  RecordKnownSenders,
  ClassifyEmails,
  TrainSpamFilter,
  SearchEmails,
  GetEmail,
  GetConversationThread,
  ClearEmailCacheForFolder,
  SpamDbSyncService,
  OutboxDrainService,
])
void main() {
  late EmailListBloc bloc;
  late MockGetEmails mockGetEmails;
  late MockGetCachedEmails mockGetCachedEmails;
  late MockMoveEmail mockMoveEmail;
  late MockEmptyFolder mockEmptyFolder;
  late MockMarkEmailAsRead mockMarkEmailAsRead;
  late MockDeleteEmail mockDeleteEmail;
  late MockGetEmail mockGetEmail;
  late MockGetConversationThread mockGetConversationThread;

  setUpAll(() {
    // Mockito needs dummy values for sealed/generic types it can't construct.
    provideDummy<Either<Failure, List<Email>>>(const Right([]));
    provideDummy<Either<Failure, Email>>(Right(_email('dummy')));
    provideDummy<Either<Failure, Unit>>(const Right(unit));
    provideDummy<Set<String>>(<String>{});
  });

  setUp(() {
    mockGetEmails = MockGetEmails();
    mockGetCachedEmails = MockGetCachedEmails();
    mockMoveEmail = MockMoveEmail();
    mockEmptyFolder = MockEmptyFolder();
    mockMarkEmailAsRead = MockMarkEmailAsRead();
    mockDeleteEmail = MockDeleteEmail();
    mockGetEmail = MockGetEmail();
    mockGetConversationThread = MockGetConversationThread();

    bloc = EmailListBloc(
      getEmails: mockGetEmails,
      getCachedEmails: mockGetCachedEmails,
      cacheEmails: MockCacheEmails(),
      clearEmailCacheForFolder: MockClearEmailCacheForFolder(),
      markEmailAsRead: mockMarkEmailAsRead,
      moveEmail: mockMoveEmail,
      reportJunk: MockReportJunk(),
      deleteEmail: mockDeleteEmail,
      emptyFolder: mockEmptyFolder,
      accountManager: _FakeAccountManager(),
      recordKnownSenders: MockRecordKnownSenders(),
      classifyEmails: MockClassifyEmails(),
      trainSpamFilter: MockTrainSpamFilter(),
      searchEmails: MockSearchEmails(),
      getEmail: mockGetEmail,
      getConversationThread: mockGetConversationThread,
      spamDbSyncService: MockSpamDbSyncService(),
      outboxDrainService: MockOutboxDrainService(),
    );
  });

  tearDown(() async => bloc.close());

  Future<void> _loadEmails(List<Email> emails, {String? folderId}) async {
    when(mockGetCachedEmails(any)).thenAnswer((_) async => const Right([]));
    when(mockGetEmails(any)).thenAnswer((_) async => Right(emails));
    bloc.add(EmailListLoadRequested(folderId: folderId));
    await bloc.stream.firstWhere((s) => s is EmailListLoaded);
  }

  // ---------------------------------------------------------------------------
  // EmailListEmailsMoved
  // ---------------------------------------------------------------------------

  group('EmailListEmailsMoved', () {
    test(
        'with conversationId removes all emails sharing that id, '
        'not just the ones listed in emailIds', () async {
      await _loadEmails([
        _email('id1', conversationId: 'conv-a'),
        _email('id2', conversationId: 'conv-a'),
        _email('id3', conversationId: 'conv-a'),
        _email('id4', conversationId: 'conv-b'),
        _email('id5', conversationId: 'conv-b'),
      ]);

      when(mockMoveEmail(any)).thenAnswer((_) async => const Right(unit));

      // Only supply one ID — the other two conv-a emails must also be removed.
      bloc.add(const EmailListEmailsMoved(
        emailIds: ['id1'],
        destinationFolderId: 'folder-x',
        conversationId: 'conv-a',
      ));

      final state = await bloc.stream
          .firstWhere((s) => s is EmailListLoaded) as EmailListLoaded;
      final ids = state.emails.map((e) => e.id).toSet();

      expect(ids, isNot(contains('id1')));
      expect(ids, isNot(contains('id2')));
      expect(ids, isNot(contains('id3')));
      expect(ids, contains('id4'));
      expect(ids, contains('id5'));
    });

    test('without conversationId removes only the specified emailIds', () async {
      await _loadEmails([
        _email('id1', conversationId: 'conv-a'),
        _email('id2', conversationId: 'conv-a'),
        _email('id3', conversationId: 'conv-b'),
      ]);

      when(mockMoveEmail(any)).thenAnswer((_) async => const Right(unit));

      bloc.add(const EmailListEmailsMoved(
        emailIds: ['id1'],
        destinationFolderId: 'folder-x',
      ));

      final state = await bloc.stream
          .firstWhere((s) => s is EmailListLoaded) as EmailListLoaded;
      final ids = state.emails.map((e) => e.id).toSet();

      expect(ids, isNot(contains('id1')));
      expect(ids, contains('id2')); // same conversation but not in emailIds
      expect(ids, contains('id3'));
    });

    // Regression: a prior fix incorrectly called _getEmails(filter: conversationId)
    // inside _onEmailsMoved, which cleared and replaced the entire folder cache
    // with only the conversation emails, corrupting subsequent refreshes.
    test('does not call getEmails during move', () async {
      await _loadEmails([_email('id1', conversationId: 'conv-a')]);

      clearInteractions(mockGetEmails);
      when(mockMoveEmail(any)).thenAnswer((_) async => const Right(unit));

      bloc.add(const EmailListEmailsMoved(
        emailIds: ['id1'],
        destinationFolderId: 'folder-x',
        conversationId: 'conv-a',
      ));

      await bloc.stream.firstWhere((s) => s is EmailListLoaded);

      verifyNever(mockGetEmails(any));
    });

    test('calls moveEmail once per id in emailIds', () async {
      await _loadEmails([
        _email('id1', conversationId: 'conv-a'),
        _email('id2', conversationId: 'conv-a'),
        _email('id3', conversationId: 'conv-a'),
      ]);

      when(mockMoveEmail(any)).thenAnswer((_) async => const Right(unit));

      bloc.add(const EmailListEmailsMoved(
        emailIds: ['id1', 'id2', 'id3'],
        destinationFolderId: 'folder-x',
        conversationId: 'conv-a',
      ));

      await bloc.stream.firstWhere((s) => s is EmailListLoaded);
      // Allow the awaited Future.wait inside _onEmailsMoved to complete.
      await Future.delayed(const Duration(milliseconds: 50));

      verify(mockMoveEmail(any)).called(3);
    });

    // Returns the ids _onEmailsMoved actually sent to the use case.
    List<String> movedIds() => verify(mockMoveEmail(captureAny))
        .captured
        .cast<MoveEmailParams>()
        .map((p) => p.id)
        .toList();

    // The same rule the delete path applies. On Gmail a move is a relabel, so
    // filing an Inbox thread by sweeping every id in it drops the destination
    // label onto the copies in Sent — and strips whatever labels they already
    // carried, because moveEmail removes every Label_* it finds on the message.
    test('leaves the copies in Sent alone when filing from another folder',
        () async {
      await _loadEmails([
        _email('id1',
            conversationId: 'conv-a',
            parentFolderId: 'INBOX',
            folderIds: ['INBOX']),
        _email('sent1', conversationId: 'conv-a', folderIds: ['SENT']),
        _email('id2',
            conversationId: 'conv-a',
            parentFolderId: 'INBOX',
            folderIds: ['INBOX']),
      ], folderId: 'INBOX');

      when(mockMoveEmail(any)).thenAnswer((_) async => const Right(unit));

      bloc.add(const EmailListEmailsMoved(
        emailIds: ['id1', 'sent1', 'id2'],
        destinationFolderId: 'Label_18',
        conversationId: 'conv-a',
      ));

      await bloc.stream.firstWhere((s) => s is EmailListLoaded);
      await Future.delayed(const Duration(milliseconds: 50));

      final moved = movedIds();
      expect(moved, containsAll(['id1', 'id2']));
      expect(moved, isNot(contains('sent1')));
    });

    // The thread's in-folder members are gone, so the conversation no longer
    // belongs in this folder — the Sent rows kept on screen purely as context
    // go with it rather than leaving a stub behind.
    test('still clears the whole thread from view when sparing Sent copies',
        () async {
      await _loadEmails([
        _email('id1',
            conversationId: 'conv-a',
            parentFolderId: 'INBOX',
            folderIds: ['INBOX']),
        _email('sent1', conversationId: 'conv-a', folderIds: ['SENT']),
        _email('other',
            conversationId: 'conv-b',
            parentFolderId: 'INBOX',
            folderIds: ['INBOX']),
      ], folderId: 'INBOX');

      when(mockMoveEmail(any)).thenAnswer((_) async => const Right(unit));

      bloc.add(const EmailListEmailsMoved(
        emailIds: ['id1', 'sent1'],
        destinationFolderId: 'Label_18',
        conversationId: 'conv-a',
      ));

      final state = await bloc.stream
          .firstWhere((s) => s is EmailListLoaded) as EmailListLoaded;
      final ids = state.emails.map((e) => e.id).toSet();

      expect(ids, isNot(contains('id1')));
      expect(ids, isNot(contains('sent1')));
      expect(ids, contains('other'));
    });

    // A thread on screen purely as other-folder context: no move would have
    // relocated anything, so neither the server nor the list should be touched.
    test('does nothing when no message in the thread is in this folder',
        () async {
      await _loadEmails([
        _email('sent1', conversationId: 'conv-a', folderIds: ['SENT']),
        _email('sent2', conversationId: 'conv-a', folderIds: ['SENT']),
      ], folderId: 'INBOX');

      when(mockMoveEmail(any)).thenAnswer((_) async => const Right(unit));

      bloc.add(const EmailListEmailsMoved(
        emailIds: ['sent1', 'sent2'],
        destinationFolderId: 'Label_18',
        conversationId: 'conv-a',
      ));

      await Future.delayed(const Duration(milliseconds: 50));

      verifyNever(mockMoveEmail(any));
      final state = bloc.state as EmailListLoaded;
      expect(state.emails.map((e) => e.id), containsAll(['sent1', 'sent2']));
    });
  });

  // ---------------------------------------------------------------------------
  // EmailListMarkThreadReadRequested
  // ---------------------------------------------------------------------------

  group('EmailListMarkThreadReadRequested', () {
    // Stubs markEmailAsRead to echo back the same email flipped to the
    // requested read state, mirroring the real use case's contract.
    void stubMarkReadEchoes(List<Email> emails) {
      final byId = {for (final e in emails) e.id: e};
      when(mockMarkEmailAsRead(any)).thenAnswer((inv) async {
        final params = inv.positionalArguments[0] as MarkEmailAsReadParams;
        final source = byId[params.id] ?? _email(params.id);
        return Right(source.copyWith(isRead: params.isRead));
      });
    }

    test('marks every listed email read, not just the first', () async {
      final emails = [
        _email('id1', conversationId: 'conv-a', isRead: false),
        _email('id2', conversationId: 'conv-a', isRead: false),
        _email('id3', conversationId: 'conv-a', isRead: false),
        _email('id4', conversationId: 'conv-b', isRead: false),
      ];
      await _loadEmails(emails);
      stubMarkReadEchoes(emails);

      // Opening thread conv-a hands the BLoC all three of its unread ids.
      bloc.add(const EmailListMarkThreadReadRequested(
        emailIds: ['id1', 'id2', 'id3'],
        isRead: true,
      ));

      final state = await bloc.stream.firstWhere((s) =>
          s is EmailListLoaded &&
          s.emails.where((e) => !e.isRead).every((e) => e.id == 'id4'))
          as EmailListLoaded;

      Email byId(String id) => state.emails.firstWhere((e) => e.id == id);
      expect(byId('id1').isRead, isTrue);
      expect(byId('id2').isRead, isTrue);
      expect(byId('id3').isRead, isTrue);
      // A different thread is untouched.
      expect(byId('id4').isRead, isFalse);
    });

    test('calls markEmailAsRead once per listed id', () async {
      final emails = [
        _email('id1', conversationId: 'conv-a', isRead: false),
        _email('id2', conversationId: 'conv-a', isRead: false),
      ];
      await _loadEmails(emails);
      stubMarkReadEchoes(emails);

      bloc.add(const EmailListMarkThreadReadRequested(
        emailIds: ['id1', 'id2'],
        isRead: true,
      ));

      await bloc.stream.firstWhere(
          (s) => s is EmailListLoaded && s.emails.every((e) => e.isRead));

      verify(mockMarkEmailAsRead(any)).called(2);
    });

    // A single message that fails to persist must not stop the rest of the
    // thread from being marked read.
    test('a failing id does not block the others', () async {
      final emails = [
        _email('id1', conversationId: 'conv-a', isRead: false),
        _email('id2', conversationId: 'conv-a', isRead: false),
      ];
      await _loadEmails(emails);
      when(mockMarkEmailAsRead(any)).thenAnswer((inv) async {
        final params = inv.positionalArguments[0] as MarkEmailAsReadParams;
        if (params.id == 'id1') {
          return const Left(ServerFailure(message: 'boom'));
        }
        return Right(_email(params.id, conversationId: 'conv-a')
            .copyWith(isRead: params.isRead));
      });

      bloc.add(const EmailListMarkThreadReadRequested(
        emailIds: ['id1', 'id2'],
        isRead: true,
      ));

      final state = await bloc.stream.firstWhere((s) =>
          s is EmailListLoaded &&
          s.emails.firstWhere((e) => e.id == 'id2').isRead) as EmailListLoaded;

      expect(state.emails.firstWhere((e) => e.id == 'id1').isRead, isFalse);
      expect(state.emails.firstWhere((e) => e.id == 'id2').isRead, isTrue);
    });

    test('an empty id list makes no use-case calls', () async {
      await _loadEmails([_email('id1', isRead: false)]);
      clearInteractions(mockMarkEmailAsRead);

      bloc.add(const EmailListMarkThreadReadRequested(
        emailIds: [],
        isRead: true,
      ));
      await Future.delayed(const Duration(milliseconds: 20));

      verifyNever(mockMarkEmailAsRead(any));
    });
  });

  // ---------------------------------------------------------------------------
  // EmailListConversationDeleted
  // ---------------------------------------------------------------------------

  group('EmailListConversationDeleted', () {
    setUp(() {
      when(mockDeleteEmail(any)).thenAnswer((_) async => const Right(unit));
    });

    List<String> deletedIds() =>
        verify(mockDeleteEmail(captureAny)).captured
            .map((p) => (p as DeleteEmailParams).id)
            .toList();

    test('deletes every in-folder message of the thread, not just the latest',
        () async {
      await _loadEmails([
        _email('id1', conversationId: 'conv-a', parentFolderId: 'inbox'),
        _email('id2', conversationId: 'conv-a', parentFolderId: 'inbox'),
        _email('id3', conversationId: 'conv-a', parentFolderId: 'inbox'),
        _email('id4', conversationId: 'conv-b', parentFolderId: 'inbox'),
      ], folderId: 'inbox');

      bloc.add(const EmailListConversationDeleted(conversationId: 'conv-a'));

      final state = await bloc.stream.firstWhere((s) =>
          s is EmailListLoaded &&
          !s.emails.any((e) => e.conversationId == 'conv-a')) as EmailListLoaded;
      // Allow the awaited deletes to flush.
      await Future.delayed(const Duration(milliseconds: 20));

      final deleted = deletedIds();
      expect(deleted, containsAll(['id1', 'id2', 'id3']));
      expect(deleted, isNot(contains('id4')));
      // The other thread is left in view.
      expect(state.emails.map((e) => e.id), ['id4']);
    });

    test('leaves messages the thread has filed in a sub-folder untouched',
        () async {
      await _loadEmails([
        _email('id1', conversationId: 'conv-a', parentFolderId: 'inbox'),
        _email('id2', conversationId: 'conv-a', parentFolderId: 'inbox'),
        // Same thread, already filed into a sub-folder (cross-folder
        // augmentation surfaced it in the inbox view).
        _email('id3', conversationId: 'conv-a', parentFolderId: 'archive'),
      ], folderId: 'inbox');

      bloc.add(const EmailListConversationDeleted(conversationId: 'conv-a'));

      final state = await bloc.stream.firstWhere((s) =>
          s is EmailListLoaded &&
          !s.emails.any((e) => e.conversationId == 'conv-a')) as EmailListLoaded;
      await Future.delayed(const Duration(milliseconds: 20));

      final deleted = deletedIds();
      expect(deleted, containsAll(['id1', 'id2']));
      expect(deleted, isNot(contains('id3')),
          reason: 'sub-folder member must survive');
      // Whole thread stub still leaves the current view.
      expect(state.emails.where((e) => e.conversationId == 'conv-a'), isEmpty);
    });

    test('treats a null parentFolderId as in-folder', () async {
      await _loadEmails([
        _email('id1', conversationId: 'conv-a', parentFolderId: 'inbox'),
        _email('id2', conversationId: 'conv-a'), // null parentFolderId
      ], folderId: 'inbox');

      bloc.add(const EmailListConversationDeleted(conversationId: 'conv-a'));

      await bloc.stream.firstWhere((s) =>
          s is EmailListLoaded && s.emails.isEmpty);
      await Future.delayed(const Duration(milliseconds: 20));

      expect(deletedIds(), containsAll(['id1', 'id2']));
    });

    test('deletes the whole thread when the view is unscoped (null folder)',
        () async {
      await _loadEmails([
        _email('id1', conversationId: 'conv-a', parentFolderId: 'inbox'),
        _email('id2', conversationId: 'conv-a', parentFolderId: 'archive'),
      ]); // no folderId → currentFolderId null

      bloc.add(const EmailListConversationDeleted(conversationId: 'conv-a'));

      await bloc.stream.firstWhere((s) =>
          s is EmailListLoaded && s.emails.isEmpty);
      await Future.delayed(const Duration(milliseconds: 20));

      expect(deletedIds(), containsAll(['id1', 'id2']));
    });

    // Gmail's folder listing is a *thread* listing: every message of a matching
    // thread comes back, labels and all. The sent replies carry only SENT, and
    // no parentFolderId the Inbox view would recognise — deleting the thread
    // out of the Inbox once took the record of what was sent with it.
    test('leaves the copies in Sent alone when deleting from another folder',
        () async {
      await _loadEmails([
        _email('id1',
            conversationId: 'conv-a',
            parentFolderId: 'INBOX',
            folderIds: ['INBOX']),
        _email('sent1', conversationId: 'conv-a', folderIds: ['SENT']),
        _email('id2',
            conversationId: 'conv-a',
            parentFolderId: 'INBOX',
            folderIds: ['INBOX']),
        _email('sent2', conversationId: 'conv-a', folderIds: ['SENT']),
      ], folderId: 'INBOX');

      bloc.add(const EmailListConversationDeleted(conversationId: 'conv-a'));

      await bloc.stream.firstWhere((s) =>
          s is EmailListLoaded &&
          !s.emails.any((e) => e.conversationId == 'conv-a'));
      await Future.delayed(const Duration(milliseconds: 20));

      final deleted = deletedIds();
      expect(deleted, containsAll(['id1', 'id2']));
      expect(deleted, isNot(contains('sent1')));
      expect(deleted, isNot(contains('sent2')));
    });

    test('leaves a draft in the thread alone', () async {
      await _loadEmails([
        _email('id1', conversationId: 'conv-a', folderIds: ['INBOX']),
        _email('draft1', conversationId: 'conv-a', folderIds: ['DRAFT']),
      ], folderId: 'INBOX');

      bloc.add(const EmailListConversationDeleted(conversationId: 'conv-a'));

      await bloc.stream.firstWhere((s) =>
          s is EmailListLoaded &&
          !s.emails.any((e) => e.conversationId == 'conv-a'));
      await Future.delayed(const Duration(milliseconds: 20));

      expect(deletedIds(), ['id1']);
    });

    // A sent message the user also filed under the label being viewed really is
    // in that label — but the sent record still must not be destroyed.
    test('leaves a sent message that also carries the current label alone',
        () async {
      await _loadEmails([
        _email('id1', conversationId: 'conv-a', folderIds: ['Label_7']),
        _email('sent1', conversationId: 'conv-a', folderIds: ['SENT', 'Label_7']),
      ], folderId: 'Label_7');

      bloc.add(const EmailListConversationDeleted(conversationId: 'conv-a'));

      await bloc.stream.firstWhere((s) =>
          s is EmailListLoaded &&
          !s.emails.any((e) => e.conversationId == 'conv-a'));
      await Future.delayed(const Duration(milliseconds: 20));

      expect(deletedIds(), ['id1']);
    });

    test('deletes the sent messages when Sent is the folder being viewed',
        () async {
      await _loadEmails([
        _email('sent1', conversationId: 'conv-a', folderIds: ['SENT']),
        _email('sent2', conversationId: 'conv-a', folderIds: ['SENT']),
        _email('id1', conversationId: 'conv-a', folderIds: ['INBOX']),
      ], folderId: 'SENT');

      bloc.add(const EmailListConversationDeleted(conversationId: 'conv-a'));

      await bloc.stream.firstWhere((s) =>
          s is EmailListLoaded &&
          !s.emails.any((e) => e.conversationId == 'conv-a'));
      await Future.delayed(const Duration(milliseconds: 20));

      final deleted = deletedIds();
      expect(deleted, containsAll(['sent1', 'sent2']));
      expect(deleted, isNot(contains('id1')),
          reason: 'the inbox copy is not in Sent');
    });

    // A Gmail message carries every label it holds, so the one folder a
    // parentFolderId can name is not the only one it is in. Viewed under a user
    // label, an INBOX-labelled member of the thread is still in that label.
    test('deletes a message that holds the current label among others',
        () async {
      await _loadEmails([
        _email('id1',
            conversationId: 'conv-a',
            parentFolderId: 'INBOX',
            folderIds: ['INBOX', 'Label_7']),
        _email('id2', conversationId: 'conv-a', folderIds: ['Label_7']),
        _email('other', conversationId: 'conv-a', folderIds: ['Archive']),
      ], folderId: 'Label_7');

      bloc.add(const EmailListConversationDeleted(conversationId: 'conv-a'));

      await bloc.stream.firstWhere((s) =>
          s is EmailListLoaded &&
          !s.emails.any((e) => e.conversationId == 'conv-a'));
      await Future.delayed(const Duration(milliseconds: 20));

      final deleted = deletedIds();
      expect(deleted, containsAll(['id1', 'id2']));
      expect(deleted, isNot(contains('other')));
    });

    // Nothing to delete means nothing to hide: a thread on screen purely as
    // other-folder context must not vanish from a delete that does nothing.
    test('deletes nothing and keeps the thread when no member is in the folder',
        () async {
      await _loadEmails([
        _email('sent1', conversationId: 'conv-a', folderIds: ['SENT']),
        _email('filed1', conversationId: 'conv-a', folderIds: ['Archive']),
        _email('id9', conversationId: 'conv-b', folderIds: ['INBOX']),
      ], folderId: 'INBOX');

      bloc.add(const EmailListConversationDeleted(conversationId: 'conv-a'));
      await Future.delayed(const Duration(milliseconds: 50));

      verifyNever(mockDeleteEmail(any));
      final state = bloc.state as EmailListLoaded;
      expect(state.emails.map((e) => e.id),
          containsAll(['sent1', 'filed1', 'id9']));
    });

    // The optimistic removal is a lie until the server agrees. A delete the
    // server refused leaves the message where it was, so the row has to come
    // back rather than wait for the next refresh to resurrect it.
    test('restores the thread when every delete fails', () async {
      await _loadEmails([
        _email('id1', conversationId: 'conv-a', folderIds: ['INBOX']),
        _email('id2', conversationId: 'conv-a', folderIds: ['INBOX']),
        _email('sent1', conversationId: 'conv-a', folderIds: ['SENT']),
      ], folderId: 'INBOX');
      when(mockDeleteEmail(any))
          .thenAnswer((_) async => const Left(ServerFailure(message: 'boom')));

      bloc.add(const EmailListConversationDeleted(conversationId: 'conv-a'));

      final state = await bloc.stream.firstWhere((s) =>
              s is EmailListLoaded &&
              s.emails.any((e) => e.conversationId == 'conv-a'))
          as EmailListLoaded;

      expect(state.emails.map((e) => e.id),
          containsAll(['id1', 'id2', 'sent1']),
          reason: 'the Sent row was hidden with the thread, so it comes back too');
    });

    test('restores only what the server did not delete', () async {
      await _loadEmails([
        _email('id1', conversationId: 'conv-a', folderIds: ['INBOX']),
        _email('id2', conversationId: 'conv-a', folderIds: ['INBOX']),
      ], folderId: 'INBOX');
      when(mockDeleteEmail(any)).thenAnswer((inv) async {
        final params = inv.positionalArguments[0] as DeleteEmailParams;
        return params.id == 'id2'
            ? const Left(ServerFailure(message: 'boom'))
            : const Right(unit);
      });

      bloc.add(const EmailListConversationDeleted(conversationId: 'conv-a'));

      final state = await bloc.stream.firstWhere((s) =>
              s is EmailListLoaded &&
              s.emails.any((e) => e.conversationId == 'conv-a'))
          as EmailListLoaded;

      expect(state.emails.map((e) => e.id), ['id2']);
    });

    test('does not restore into a folder the user has moved on to', () async {
      await _loadEmails([
        _email('id1', conversationId: 'conv-a', folderIds: ['INBOX']),
      ], folderId: 'INBOX');
      final deleteBlocked = Completer<void>();
      when(mockDeleteEmail(any)).thenAnswer((_) async {
        await deleteBlocked.future;
        return const Left(ServerFailure(message: 'boom'));
      });

      bloc.add(const EmailListConversationDeleted(conversationId: 'conv-a'));
      await bloc.stream.firstWhere(
          (s) => s is EmailListLoaded && s.emails.isEmpty);

      // The user switches folders while the delete is still in flight.
      when(mockGetEmails(any))
          .thenAnswer((_) async => Right([_email('other1')]));
      bloc.add(const EmailListLoadRequested(folderId: 'archive'));
      await bloc.stream.firstWhere((s) =>
          s is EmailListLoaded && s.currentFolderId == 'archive');
      deleteBlocked.complete();
      await Future.delayed(const Duration(milliseconds: 50));

      final state = bloc.state as EmailListLoaded;
      expect(state.currentFolderId, 'archive');
      expect(state.emails.map((e) => e.id), ['other1']);
    });

    // A refresh landing mid-delete can put the surviving rows back on its own.
    test('does not restore a row the list already has', () async {
      await _loadEmails([
        _email('id1', conversationId: 'conv-a', folderIds: ['INBOX']),
        _email('id2', conversationId: 'conv-a', folderIds: ['INBOX']),
      ], folderId: 'INBOX');
      final deleteBlocked = Completer<void>();
      when(mockDeleteEmail(any)).thenAnswer((_) async {
        await deleteBlocked.future;
        return const Left(ServerFailure(message: 'boom'));
      });

      bloc.add(const EmailListConversationDeleted(conversationId: 'conv-a'));
      await bloc.stream.firstWhere(
          (s) => s is EmailListLoaded && s.emails.isEmpty);

      // A reload of the same folder lands while the delete is still in flight
      // and puts one of the two rows back on its own.
      when(mockGetEmails(any)).thenAnswer((_) async => Right([
            _email('id1', conversationId: 'conv-a', folderIds: ['INBOX']),
          ]));
      bloc.add(const EmailListLoadRequested(folderId: 'INBOX'));
      await bloc.stream.firstWhere((s) =>
          s is EmailListLoaded && s.emails.any((e) => e.id == 'id1'));
      deleteBlocked.complete();
      await Future.delayed(const Duration(milliseconds: 50));

      final state = bloc.state as EmailListLoaded;
      expect(state.emails.map((e) => e.id), ['id1', 'id2']);
    });
  });

  // ---------------------------------------------------------------------------
  // EmailListFolderEmptied
  // ---------------------------------------------------------------------------

  group('EmailListFolderEmptied', () {
    // Regression: a Delete All that fails partway through (e.g. throttled by
    // the server on a large folder) must not leave the optimistic "folder is
    // empty" view standing — whatever the server never actually deleted has
    // to reappear.
    test('re-fetches the folder when emptyFolder fails, restoring emails '
        'the server never actually deleted', () async {
      when(mockGetCachedEmails(any)).thenAnswer((_) async => const Right([]));
      when(mockGetEmails(any)).thenAnswer((_) async => Right([_email('id1'), _email('id2')]));
      bloc.add(const EmailListLoadRequested(folderId: 'folder-1'));
      await bloc.stream.firstWhere((s) => s is EmailListLoaded);

      when(mockEmptyFolder(any)).thenAnswer(
          (_) async => const Left(ServerFailure(message: 'throttled')));
      // Server only actually deleted id1 before failing.
      when(mockGetEmails(any)).thenAnswer((_) async => Right([_email('id2')]));

      bloc.add(const EmailListFolderEmptied(folderId: 'folder-1'));

      final state = await bloc.stream
          .firstWhere((s) => s is EmailListLoaded && s.emails.isNotEmpty)
          as EmailListLoaded;

      expect(state.emails.map((e) => e.id), contains('id2'));
    });

    test('does not re-fetch when emptyFolder succeeds', () async {
      when(mockGetCachedEmails(any)).thenAnswer((_) async => const Right([]));
      when(mockGetEmails(any)).thenAnswer((_) async => Right([_email('id1'), _email('id2')]));
      bloc.add(const EmailListLoadRequested(folderId: 'folder-1'));
      await bloc.stream.firstWhere((s) => s is EmailListLoaded);

      when(mockEmptyFolder(any)).thenAnswer((_) async => const Right(unit));
      clearInteractions(mockGetEmails);

      bloc.add(const EmailListFolderEmptied(folderId: 'folder-1'));
      await bloc.stream.firstWhere(
          (s) => s is EmailListLoaded && s.emptyingFolderIds.isEmpty);

      verifyNever(mockGetEmails(any));
    });

    // Regression: the folder-row shimmer is driven by emptyingFolderIds, which
    // is keyed by folder id, not by whichever folder is on screen. Navigating
    // to another folder while a large Delete All is still running server-side
    // used to overwrite emptyingFolderIds with a fresh empty set, killing the
    // shimmer for a delete that hadn't actually finished.
    test('navigating to another folder mid-delete keeps the emptying folder tracked',
        () async {
      when(mockGetCachedEmails(any)).thenAnswer((_) async => const Right([]));
      when(mockGetEmails(any)).thenAnswer((_) async => Right([_email('id1')]));
      bloc.add(const EmailListLoadRequested(folderId: 'folder-1'));
      await bloc.stream.firstWhere((s) => s is EmailListLoaded);

      final emptyCompleter = Completer<Either<Failure, Unit>>();
      when(mockEmptyFolder(any)).thenAnswer((_) => emptyCompleter.future);

      bloc.add(const EmailListFolderEmptied(folderId: 'folder-2'));
      final emptying = await bloc.stream.firstWhere((s) =>
          s is EmailListLoaded &&
          s.emptyingFolderIds.contains('folder-2')) as EmailListLoaded;
      expect(emptying.emptyingFolderIds, contains('folder-2'));

      // User navigates to a different folder while folder-2 is still being emptied.
      when(mockGetEmails(any)).thenAnswer((_) async => Right([_email('id3')]));
      bloc.add(const EmailListLoadRequested(folderId: 'folder-3'));

      final loaded = await bloc.stream.firstWhere((s) =>
          s is EmailListLoaded && s.currentFolderId == 'folder-3') as EmailListLoaded;
      expect(loaded.emptyingFolderIds, contains('folder-2'));

      emptyCompleter.complete(const Right(unit));
      await bloc.stream.firstWhere(
          (s) => s is EmailListLoaded && s.emptyingFolderIds.isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Folder-switch races
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // EmailListThreadFocusRequested
  // ---------------------------------------------------------------------------

  group('EmailListThreadFocusRequested', () {
    Future<EmailListLoaded> _focus(String emailId) async {
      bloc.add(EmailListThreadFocusRequested(emailId: emailId));
      return await bloc.stream.firstWhere(
        (s) => s is EmailListLoaded && s.focusedThreadId != null,
      ) as EmailListLoaded;
    }

    test('replaces the list with the anchor email\'s thread', () async {
      await _loadEmails([
        _email('id1', conversationId: 'conv-a'),
        _email('id2', conversationId: 'conv-b'),
      ]);
      when(mockGetConversationThread(any)).thenAnswer((_) async => Right([
            _email('id1', conversationId: 'conv-a'),
            _email('id1-reply', conversationId: 'conv-a'),
          ]));

      final state = await _focus('id1');

      expect(state.emails.map((e) => e.id), {'id1', 'id1-reply'});
      expect(state.focusedThreadId, 'conv-a');
      expect(state.focusedThreadSubject, 'Subject id1');
      expect(state.expandedConversationIds, contains('conv-a'),
          reason: 'a focused thread should open, not need a second click');
      expect(state.hasMore, isFalse,
          reason: 'scrolling must not append folder pages to the thread');
    });

    // The task being opened from may reference an email in a folder that was
    // never loaded — the id alone has to be enough.
    test('fetches the anchor by id when it is not in the current list',
        () async {
      await _loadEmails([_email('other', conversationId: 'conv-b')]);
      when(mockGetEmail(any)).thenAnswer(
          (_) async => Right(_email('archived', conversationId: 'conv-z')));
      when(mockGetConversationThread(any)).thenAnswer((_) async =>
          Right([_email('archived', conversationId: 'conv-z')]));

      final state = await _focus('archived');

      verify(mockGetEmail(any)).called(1);
      expect(state.focusedThreadId, 'conv-z');
      expect(state.emails.single.id, 'archived');
    });

    // A partial or failed thread fetch must never lose the message the
    // reading pane is already showing.
    test('keeps the anchor when the thread fetch fails', () async {
      await _loadEmails([_email('id1', conversationId: 'conv-a')]);
      when(mockGetConversationThread(any)).thenAnswer(
          (_) async => const Left(ServerFailure(message: 'boom')));

      final state = await _focus('id1');

      expect(state.emails.map((e) => e.id), contains('id1'));
    });

    test('an anchor that cannot be resolved leaves the folder listing alone',
        () async {
      await _loadEmails([_email('id1', conversationId: 'conv-a')]);
      when(mockGetEmail(any)).thenAnswer(
          (_) async => const Left(ServerFailure(message: 'gone')));

      bloc.add(const EmailListThreadFocusRequested(emailId: 'missing'));
      await Future.delayed(const Duration(milliseconds: 50));

      final state = bloc.state as EmailListLoaded;
      expect(state.focusedThreadId, isNull);
      expect(state.emails.map((e) => e.id), ['id1']);
      expect(state.isLoadingFresh, isFalse);
    });

    // Regression: the poller repaints the list from the folder cache every
    // cycle. Left unguarded it would swap the thread out from under the user.
    test('a background cache refresh does not replace the focused thread',
        () async {
      await _loadEmails([_email('id1', conversationId: 'conv-a')]);
      when(mockGetConversationThread(any)).thenAnswer((_) async => Right([
            _email('id1', conversationId: 'conv-a'),
            _email('id1-reply', conversationId: 'conv-a'),
          ]));
      await _focus('id1');

      bloc.add(const EmailListCacheRefreshRequested());
      await Future.delayed(const Duration(milliseconds: 50));

      final state = bloc.state as EmailListLoaded;
      expect(state.focusedThreadId, 'conv-a');
      expect(state.emails.map((e) => e.id), {'id1', 'id1-reply'});
      verifyNever(mockGetCachedEmails(any));
    });

    // Same hazard via the periodic foreground refresh: it should re-read the
    // thread, not fall back to the folder.
    test('a refresh re-fetches the thread instead of the folder', () async {
      await _loadEmails([_email('id1', conversationId: 'conv-a')]);
      when(mockGetConversationThread(any)).thenAnswer(
          (_) async => Right([_email('id1', conversationId: 'conv-a')]));
      await _focus('id1');

      when(mockGetConversationThread(any)).thenAnswer((_) async => Right([
            _email('id1', conversationId: 'conv-a'),
            _email('id1-new', conversationId: 'conv-a'),
          ]));
      clearInteractions(mockGetEmails);

      bloc.add(const EmailListRefreshRequested());
      await Future.delayed(const Duration(milliseconds: 50));

      final state = bloc.state as EmailListLoaded;
      expect(state.focusedThreadId, 'conv-a');
      expect(state.emails.map((e) => e.id), contains('id1-new'));
      verifyNever(mockGetEmails(any));
    });

    test('clearing the focus reloads the folder', () async {
      await _loadEmails([_email('id1', conversationId: 'conv-a')],
          folderId: 'folder-1');
      when(mockGetConversationThread(any)).thenAnswer((_) async => Right([
            _email('id1', conversationId: 'conv-a'),
            _email('id1-reply', conversationId: 'conv-a'),
          ]));
      await _focus('id1');

      when(mockGetEmails(any)).thenAnswer((_) async => Right([
            _email('id1', conversationId: 'conv-a'),
            _email('id9', conversationId: 'conv-c'),
          ]));

      bloc.add(const EmailListThreadFocusCleared());
      // The focus flags drop on the first emit (mirroring search-clear, so the
      // header reverts immediately); the folder listing lands on the next one.
      final state = await bloc.stream.firstWhere(
        (s) => s is EmailListLoaded && s.emails.any((e) => e.id == 'id9'),
      ) as EmailListLoaded;

      expect(state.focusedThreadId, isNull);
      expect(state.currentFolderId, 'folder-1');
      expect(state.emails.map((e) => e.id), contains('id9'));
      expect(state.focusedThreadSubject, isNull);
    });
  });

  group('folder switch races', () {
    // Regression: clicking folder A kicks off a server fetch; switching to
    // folder B before A's fetch resolves must not let A's late-arriving
    // result clobber B's state once it's on screen.
    test('a slow load for a folder navigated away from does not overwrite '
        'the newly selected folder', () async {
      when(mockGetCachedEmails(any)).thenAnswer((_) async => const Right([]));

      final folderACompleter = Completer<Either<Failure, List<Email>>>();
      when(mockGetEmails(argThat(predicate<GetEmailsParams>(
              (p) => p.folderId == 'folder-a'))))
          .thenAnswer((_) => folderACompleter.future);

      bloc.add(const EmailListLoadRequested(
        folderId: 'folder-a',
        folderDisplayName: 'Folder A',
      ));
      // Let the cache-read phase (Phase 1) run so folder-a is genuinely
      // in flight before switching away.
      await Future.delayed(Duration.zero);

      when(mockGetEmails(argThat(predicate<GetEmailsParams>(
              (p) => p.folderId == 'folder-b'))))
          .thenAnswer((_) async => Right([_email('id-b')]));

      bloc.add(const EmailListLoadRequested(
        folderId: 'folder-b',
        folderDisplayName: 'Folder B',
      ));

      final loadedB = await bloc.stream.firstWhere((s) =>
          s is EmailListLoaded && s.currentFolderId == 'folder-b') as EmailListLoaded;
      expect(loadedB.emails.map((e) => e.id), contains('id-b'));

      // Folder A's fetch finally resolves after the user is already on B.
      folderACompleter.complete(Right([_email('id-a')]));
      await Future.delayed(const Duration(milliseconds: 50));

      final finalState = bloc.state as EmailListLoaded;
      expect(finalState.currentFolderId, 'folder-b',
          reason: 'stale folder-a result must not overwrite folder-b');
      expect(finalState.emails.map((e) => e.id), contains('id-b'));
      expect(finalState.emails.map((e) => e.id), isNot(contains('id-a')));
    });

    // Regression: same bug via EmailListRefreshRequested — a refresh in
    // flight for the folder that was on screen must not clobber a folder
    // the user has since switched to.
    test('a slow refresh for the previous folder does not overwrite a '
        'folder switched to in the meantime', () async {
      when(mockGetCachedEmails(any)).thenAnswer((_) async => const Right([]));
      when(mockGetEmails(argThat(predicate<GetEmailsParams>(
              (p) => p.folderId == 'folder-a'))))
          .thenAnswer((_) async => Right([_email('id-a')]));
      bloc.add(const EmailListLoadRequested(folderId: 'folder-a'));
      await bloc.stream.firstWhere(
          (s) => s is EmailListLoaded && s.currentFolderId == 'folder-a');

      final refreshCompleter = Completer<Either<Failure, List<Email>>>();
      when(mockGetEmails(argThat(predicate<GetEmailsParams>(
              (p) => p.folderId == 'folder-a'))))
          .thenAnswer((_) => refreshCompleter.future);
      bloc.add(const EmailListRefreshRequested(folderId: 'folder-a'));
      await Future.delayed(Duration.zero);

      when(mockGetEmails(argThat(predicate<GetEmailsParams>(
              (p) => p.folderId == 'folder-b'))))
          .thenAnswer((_) async => Right([_email('id-b')]));
      bloc.add(const EmailListLoadRequested(folderId: 'folder-b'));
      final loadedB = await bloc.stream.firstWhere((s) =>
          s is EmailListLoaded && s.currentFolderId == 'folder-b') as EmailListLoaded;
      expect(loadedB.emails.map((e) => e.id), contains('id-b'));

      refreshCompleter.complete(Right([_email('id-a-refreshed')]));
      await Future.delayed(const Duration(milliseconds: 50));

      final finalState = bloc.state as EmailListLoaded;
      expect(finalState.currentFolderId, 'folder-b',
          reason: 'stale refresh of folder-a must not overwrite folder-b');
    });
  });

  // ---------------------------------------------------------------------------
  // EmailListRefreshRequested — cache ordering
  // ---------------------------------------------------------------------------

  group('EmailListRefreshRequested cache ordering (active account)', () {
    // Regression: the folder cache must be cleared and then explicitly
    // re-written with the fresh page, strictly in that order. The repository
    // also fires its own unawaited cache write as a side effect of
    // getEmails() succeeding; if the clear ran after that write (or nothing
    // re-wrote the cache after the clear), the folder's on-disk cache would
    // be left empty after a successful refresh — a poll-triggered
    // EmailListCacheRefreshRequested right after would then show a blank
    // inbox. Asserting the explicit clear-then-write order here is what
    // guarantees the final cache state is correct regardless of how the
    // repository's own fire-and-forget write happens to interleave.
    test('clears the folder cache before re-writing the fresh page', () async {
      final mockCacheEmails = MockCacheEmails();
      final mockClearEmailCacheForFolder = MockClearEmailCacheForFolder();
      final mockRecordKnownSenders = MockRecordKnownSenders();
      final orderedBloc = EmailListBloc(
        getEmails: mockGetEmails,
        getCachedEmails: mockGetCachedEmails,
        cacheEmails: mockCacheEmails,
        clearEmailCacheForFolder: mockClearEmailCacheForFolder,
        markEmailAsRead: MockMarkEmailAsRead(),
        moveEmail: mockMoveEmail,
        reportJunk: MockReportJunk(),
        deleteEmail: MockDeleteEmail(),
        emptyFolder: mockEmptyFolder,
        accountManager: _FakeActiveAccountManager(),
        recordKnownSenders: mockRecordKnownSenders,
        classifyEmails: MockClassifyEmails(),
        trainSpamFilter: MockTrainSpamFilter(),
        searchEmails: MockSearchEmails(),
        getEmail: MockGetEmail(),
        getConversationThread: MockGetConversationThread(),
        spamDbSyncService: MockSpamDbSyncService(),
        outboxDrainService: MockOutboxDrainService(),
      );
      addTearDown(orderedBloc.close);

      when(mockGetCachedEmails(any)).thenAnswer((_) async => const Right([]));
      when(mockGetEmails(any))
          .thenAnswer((_) async => Right([_email('id1')]));
      when(mockClearEmailCacheForFolder(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockCacheEmails(any)).thenAnswer((_) async => const Right(unit));
      when(mockRecordKnownSenders(any))
          .thenAnswer((_) async => const Right(unit));

      orderedBloc
          .add(const EmailListRefreshRequested(folderId: 'folder-1'));
      await orderedBloc.stream.firstWhere((s) => s is EmailListLoaded);

      verifyInOrder([
        mockClearEmailCacheForFolder(any),
        mockCacheEmails(any),
      ]);
    });
  });

  // ---------------------------------------------------------------------------
  // EmailListLoadRequested — a first fetch that fails behind a populated cache
  //
  // Regression: the failure is swallowed so the cached mail stays on screen,
  // which is right, but nothing then re-fetched the folder — so a cold start
  // whose first request lost a race with the machine's network coming up sat
  // there showing yesterday's mail until the user pressed Refresh.
  // ---------------------------------------------------------------------------

  group('EmailListLoadRequested retry (active account)', () {
    EmailListBloc makeBloc({required List<Duration> retryDelays}) {
      final mockRecordKnownSenders = MockRecordKnownSenders();
      when(mockRecordKnownSenders(any))
          .thenAnswer((_) async => const Right(unit));
      return EmailListBloc(
        getEmails: mockGetEmails,
        getCachedEmails: mockGetCachedEmails,
        cacheEmails: MockCacheEmails(),
        clearEmailCacheForFolder: MockClearEmailCacheForFolder(),
        markEmailAsRead: MockMarkEmailAsRead(),
        moveEmail: mockMoveEmail,
        reportJunk: MockReportJunk(),
        deleteEmail: MockDeleteEmail(),
        emptyFolder: mockEmptyFolder,
        accountManager: _FakeActiveAccountManager(),
        recordKnownSenders: mockRecordKnownSenders,
        classifyEmails: MockClassifyEmails(),
        trainSpamFilter: MockTrainSpamFilter(),
        searchEmails: MockSearchEmails(),
        getEmail: MockGetEmail(),
        getConversationThread: MockGetConversationThread(),
        spamDbSyncService: MockSpamDbSyncService(),
        outboxDrainService: MockOutboxDrainService(),
        staleRetryDelays: retryDelays,
      );
    }

    test('retries and replaces the cached page with the fresh one', () async {
      final retryBloc = makeBloc(retryDelays: const [Duration.zero]);
      addTearDown(retryBloc.close);

      when(mockGetCachedEmails(any))
          .thenAnswer((_) async => Right([_email('yesterday')]));
      var calls = 0;
      when(mockGetEmails(any)).thenAnswer((_) async {
        calls++;
        return calls == 1
            ? const Left(NetworkFailure(message: 'No network connection'))
            : Right([_email('this-morning')]);
      });

      retryBloc.add(const EmailListLoadRequested(folderId: 'folder-1'));
      final state = await retryBloc.stream.firstWhere((s) =>
              s is EmailListLoaded &&
              s.emails.any((e) => e.id == 'this-morning'))
          as EmailListLoaded;

      expect(calls, 2);
      expect(state.emails.first.id, 'this-morning');
      expect(state.isLoadingFresh, isFalse);
    });

    test('gives up after the configured attempts, cached mail still showing',
        () async {
      final retryBloc =
          makeBloc(retryDelays: const [Duration.zero, Duration.zero]);
      addTearDown(retryBloc.close);

      when(mockGetCachedEmails(any))
          .thenAnswer((_) async => Right([_email('yesterday')]));
      when(mockGetEmails(any)).thenAnswer(
        (_) async => const Left(NetworkFailure(message: 'No network')),
      );

      retryBloc.add(const EmailListLoadRequested(folderId: 'folder-1'));
      await pumpEventQueue(times: 50);

      verify(mockGetEmails(any)).called(3);
      final state = retryBloc.state as EmailListLoaded;
      expect(state.emails.single.id, 'yesterday');
      expect(state.isLoadingFresh, isFalse);
    });

    test('does not retry when there was nothing cached to go stale', () async {
      final retryBloc = makeBloc(retryDelays: const [Duration.zero]);
      addTearDown(retryBloc.close);

      when(mockGetCachedEmails(any)).thenAnswer((_) async => const Right([]));
      when(mockGetEmails(any)).thenAnswer(
        (_) async => const Left(NetworkFailure(message: 'No network')),
      );

      retryBloc.add(const EmailListLoadRequested(folderId: 'folder-1'));
      await retryBloc.stream.firstWhere((s) => s is EmailListError);
      await pumpEventQueue();

      verify(mockGetEmails(any)).called(1);
    });
  });
}

class _FakeActiveAccountManager extends Fake implements AccountManager {
  @override
  Account? get activeAccount => const MicrosoftAccount(
        id: 'account-1',
        displayName: 'Test',
        emailAddress: 'test@example.com',
        tenantId: 'common',
      );
}
