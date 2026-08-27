import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/usecases/cache_emails.dart';
import 'package:nightmail/domain/usecases/forget_cached_emails.dart';
import 'package:nightmail/domain/usecases/classify_emails.dart';
import 'package:nightmail/domain/usecases/delete_email.dart';
import 'package:nightmail/domain/usecases/empty_folder.dart';
import 'package:nightmail/domain/usecases/get_cached_emails.dart';
import 'package:nightmail/domain/usecases/get_conversation_thread.dart';
import 'package:nightmail/domain/usecases/get_email.dart';
import 'package:nightmail/domain/usecases/get_emails.dart';
import 'package:nightmail/domain/usecases/mark_email_as_read.dart';
import 'package:nightmail/domain/usecases/move_email.dart';
import 'package:nightmail/domain/usecases/remove_conversation_from_folder.dart';
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

// Fake AccountManager. Reports no active account by default, which keeps the
// BLoC from attempting cache writes or spam classification; tests that need the
// cache paths (a repaint reads it) set [account].
class _FakeAccountManager extends Fake implements AccountManager {
  Account? account;

  @override
  Account? get activeAccount => account;
}

const _account = MicrosoftAccount(
  id: 'account-1',
  displayName: 'Test',
  emailAddress: 'test@example.com',
  tenantId: 'common',
);

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

@GenerateMocks([
  GetEmails,
  GetCachedEmails,
  CacheEmails,
  ForgetCachedEmails,
  MarkEmailAsRead,
  MoveEmail,
  RemoveConversationFromFolder,
  ReportJunk,
  DeleteEmail,
  EmptyFolder,
  RecordKnownSenders,
  ClassifyEmails,
  TrainSpamFilter,
  SearchEmails,
  GetEmail,
  GetConversationThread,
  SpamDbSyncService,
  OutboxDrainService,
])
void main() {
  late EmailListBloc bloc;
  late MockGetEmails mockGetEmails;
  late MockGetCachedEmails mockGetCachedEmails;
  late MockMoveEmail mockMoveEmail;
  late MockRemoveConversationFromFolder mockRemoveConversationFromFolder;
  late MockEmptyFolder mockEmptyFolder;
  late MockMarkEmailAsRead mockMarkEmailAsRead;
  late MockDeleteEmail mockDeleteEmail;
  late MockGetEmail mockGetEmail;
  late MockGetConversationThread mockGetConversationThread;
  late MockSearchEmails mockSearchEmails;
  late MockRecordKnownSenders mockRecordKnownSenders;
  late MockCacheEmails mockCacheEmails;
  late MockForgetCachedEmails mockForgetCachedEmails;
  late _FakeAccountManager fakeAccountManager;

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
    mockRemoveConversationFromFolder = MockRemoveConversationFromFolder();
    mockEmptyFolder = MockEmptyFolder();
    mockMarkEmailAsRead = MockMarkEmailAsRead();
    mockDeleteEmail = MockDeleteEmail();
    mockGetEmail = MockGetEmail();
    mockGetConversationThread = MockGetConversationThread();
    mockSearchEmails = MockSearchEmails();
    mockRecordKnownSenders = MockRecordKnownSenders();
    mockCacheEmails = MockCacheEmails();
    mockForgetCachedEmails = MockForgetCachedEmails();
    when(mockForgetCachedEmails(any)).thenAnswer((_) async => const Right(unit));
    fakeAccountManager = _FakeAccountManager();
    when(mockRecordKnownSenders(any)).thenAnswer((_) async => const Right(unit));
    when(mockCacheEmails(any)).thenAnswer((_) async => const Right(unit));

    bloc = EmailListBloc(
      getEmails: mockGetEmails,
      getCachedEmails: mockGetCachedEmails,
      cacheEmails: mockCacheEmails,
      forgetCachedEmails: mockForgetCachedEmails,
      markEmailAsRead: mockMarkEmailAsRead,
      moveEmail: mockMoveEmail,
      removeConversationFromFolder: mockRemoveConversationFromFolder,
      reportJunk: MockReportJunk(),
      deleteEmail: mockDeleteEmail,
      emptyFolder: mockEmptyFolder,
      accountManager: fakeAccountManager,
      recordKnownSenders: mockRecordKnownSenders,
      classifyEmails: MockClassifyEmails(),
      trainSpamFilter: MockTrainSpamFilter(),
      searchEmails: mockSearchEmails,
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

    // Regression: reply to a message, then file the thread out of the folder.
    // The reply's copy in Sent is surfaced in this folder's listing purely as
    // thread context, and a folder-scoped move deliberately does not relocate
    // it — so nothing sent it through moveEmail, which is what drops a row from
    // the cache. It stayed cached under this folder, and the next repaint from
    // cache brought it back on its own: a reply sitting in the folder its thread
    // had just left. It only went away when a network refresh replaced the
    // folder wholesale, which is exactly the "disappears on the next refresh"
    // half of the report.
    test('forgets the cached rows a folder-scoped move spared', () async {
      await _loadEmails([
        // In this folder, and the target of the move.
        _email('original',
            conversationId: 'conv-a',
            parentFolderId: 'INBOX',
            folderIds: ['INBOX']),
        // The reply's copy in Sent — same thread, listed here as context only.
        _email('reply-in-sent', conversationId: 'conv-a', folderIds: ['SENT']),
      ], folderId: 'INBOX');

      when(mockMoveEmail(any)).thenAnswer((_) async => const Right(unit));

      bloc.add(const EmailListEmailsMoved(
        emailIds: ['original', 'reply-in-sent'],
        destinationFolderId: 'folder-x',
        conversationId: 'conv-a',
      ));
      await bloc.stream.firstWhere((s) => s is EmailListLoaded);
      await Future.delayed(const Duration(milliseconds: 50));

      // The Sent copy is not relocated on the server...
      final movedIds = verify(mockMoveEmail(captureAny))
          .captured
          .cast<MoveEmailParams>()
          .map((p) => p.id);
      expect(movedIds, ['original']);

      // ...but it does leave this folder's cache, or it comes back alone.
      final forgotten = verify(mockForgetCachedEmails(captureAny))
          .captured
          .cast<ForgetCachedEmailsParams>()
          .expand((p) => p.emailIds);
      expect(forgotten, ['reply-in-sent']);
    });

    test('does not forget anything when nothing was spared', () async {
      await _loadEmails([
        _email('id1',
            conversationId: 'conv-a',
            parentFolderId: 'INBOX',
            folderIds: ['INBOX']),
      ], folderId: 'INBOX');
      when(mockMoveEmail(any)).thenAnswer((_) async => const Right(unit));

      bloc.add(const EmailListEmailsMoved(
        emailIds: ['id1'],
        destinationFolderId: 'folder-x',
        conversationId: 'conv-a',
      ));
      await bloc.stream.firstWhere((s) => s is EmailListLoaded);
      await Future.delayed(const Duration(milliseconds: 50));

      verifyNever(mockForgetCachedEmails(any));
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

    // A thread on screen purely as other-folder context, on a provider that
    // files a message in exactly one folder: no move would have relocated
    // anything, so neither the server nor the list should be touched — and the
    // user is told nothing, because nothing went wrong.
    test('does nothing when the provider has no thread-level membership',
        () async {
      await _loadEmails([
        _email('sent1', conversationId: 'conv-a', folderIds: ['SENT']),
        _email('sent2', conversationId: 'conv-a', folderIds: ['SENT']),
      ], folderId: 'INBOX');

      when(mockMoveEmail(any)).thenAnswer((_) async => const Right(unit));
      when(mockRemoveConversationFromFolder(any)).thenAnswer(
        (_) async => const Left(UnsupportedFailure(message: 'nope')),
      );

      bloc.add(const EmailListEmailsMoved(
        emailIds: ['sent1', 'sent2'],
        destinationFolderId: 'Label_18',
        conversationId: 'conv-a',
      ));

      await Future.delayed(const Duration(milliseconds: 50));

      verifyNever(mockMoveEmail(any));
      final state = bloc.state as EmailListLoaded;
      expect(state.emails.map((e) => e.id), containsAll(['sent1', 'sent2']));
      expect(state.actionFailure, isNull);
    });

    // The Gmail case this whole fallback exists for: the *thread* is listed in
    // the folder while not one of its messages carries it, so the per-message
    // move has nothing to act on. Before the fallback this returned silently
    // and the thread came back on the next listing.
    test(
        'falls back to a thread-level removal when the thread is in the folder '
        'but none of its messages is', () async {
      await _loadEmails([
        _email('sent1', conversationId: 'conv-a', folderIds: ['SENT']),
        _email('filed', conversationId: 'conv-a', folderIds: ['Label_11']),
        _email('other', conversationId: 'conv-b', folderIds: ['INBOX']),
      ], folderId: 'INBOX');

      when(mockMoveEmail(any)).thenAnswer((_) async => const Right(unit));
      when(mockRemoveConversationFromFolder(any))
          .thenAnswer((_) async => const Right(unit));

      bloc.add(const EmailListEmailsMoved(
        emailIds: ['sent1', 'filed'],
        destinationFolderId: 'Label_18',
        conversationId: 'conv-a',
      ));

      await Future.delayed(const Duration(milliseconds: 50));

      // Never per message — that is the call that does nothing here.
      verifyNever(mockMoveEmail(any));
      final params = verify(mockRemoveConversationFromFolder(captureAny))
          .captured
          .single as RemoveConversationFromFolderParams;
      expect(params.conversationId, 'conv-a');
      expect(params.folderId, 'INBOX');

      final state = bloc.state as EmailListLoaded;
      expect(state.emails.map((e) => e.id), ['other']);
      expect(state.actionFailure, isNull);
    });

    // The silence is the bug, not just the inaction: a move that could not be
    // performed has to say so.
    test('reports a failed thread-level removal instead of returning silently',
        () async {
      await _loadEmails([
        _email('sent1', conversationId: 'conv-a', folderIds: ['SENT']),
        _email('filed', conversationId: 'conv-a', folderIds: ['Label_11']),
      ], folderId: 'INBOX');

      when(mockMoveEmail(any)).thenAnswer((_) async => const Right(unit));
      when(mockRemoveConversationFromFolder(any)).thenAnswer(
        (_) async => const Left(ServerFailure(message: 'boom')),
      );

      bloc.add(const EmailListEmailsMoved(
        emailIds: ['sent1', 'filed'],
        destinationFolderId: 'Label_18',
        conversationId: 'conv-a',
      ));

      await Future.delayed(const Duration(milliseconds: 50));

      final state = bloc.state as EmailListLoaded;
      expect(state.actionFailure, isNotNull);
      expect(state.actionFailure!.message, contains('boom'));
      // Nothing was removed on a failure — the thread is still there to retry.
      expect(state.emails.map((e) => e.id), containsAll(['sent1', 'filed']));
    });

    // Without a distinct sequence the second emit compares equal on props and
    // is dropped, so pressing the same broken button twice reports once.
    test('reports the same failure twice as two distinct states', () async {
      await _loadEmails([
        _email('sent1', conversationId: 'conv-a', folderIds: ['SENT']),
      ], folderId: 'INBOX');

      when(mockRemoveConversationFromFolder(any)).thenAnswer(
        (_) async => const Left(ServerFailure(message: 'boom')),
      );

      const move = EmailListEmailsMoved(
        emailIds: ['sent1'],
        destinationFolderId: 'Label_18',
        conversationId: 'conv-a',
      );

      bloc.add(move);
      await Future.delayed(const Duration(milliseconds: 50));
      final first = (bloc.state as EmailListLoaded).actionFailure!;

      bloc.add(move);
      await Future.delayed(const Duration(milliseconds: 50));
      final second = (bloc.state as EmailListLoaded).actionFailure!;

      expect(second.message, first.message);
      expect(second, isNot(first));
      expect(second.sequence, greaterThan(first.sequence));
    });

    // A single-message move must never reach the thread-level removal: it has
    // no conversation to address, and the removal cannot file anything anyway.
    test('does not fall back for a move with no conversationId', () async {
      await _loadEmails([
        _email('sent1', folderIds: ['SENT']),
      ], folderId: 'INBOX');

      when(mockMoveEmail(any)).thenAnswer((_) async => const Right(unit));

      bloc.add(const EmailListEmailsMoved(
        emailIds: ['sent1'],
        destinationFolderId: 'Label_18',
      ));

      await Future.delayed(const Duration(milliseconds: 50));

      verifyNever(mockMoveEmail(any));
      verifyNever(mockRemoveConversationFromFolder(any));
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
    // Regression: the fresh page must *replace* the folder's rows, so an email
    // deleted or moved elsewhere stops being listed. The repository also fires
    // its own unawaited cache write as a side effect of getEmails() succeeding,
    // which isn't ordered against this one — so the bloc writes explicitly.
    //
    // It must do that in ONE call with replaceFolder, not clear-then-write.
    // cacheEmails preserves an already-cached full body by looking the old row
    // up first; a separate clear on the line before guaranteed that lookup
    // found nothing, so every refresh discarded every cached body in the folder
    // and BodyPrefetchService re-downloaded up to 20 messages. The delete now
    // happens inside the same transaction and after the preservation lookups.
    test('replaces the folder cache in a single write', () async {
      final mockCacheEmails = MockCacheEmails();
      final mockRecordKnownSenders = MockRecordKnownSenders();
      final orderedBloc = EmailListBloc(
        getEmails: mockGetEmails,
        getCachedEmails: mockGetCachedEmails,
        cacheEmails: mockCacheEmails,
        forgetCachedEmails: mockForgetCachedEmails,
        markEmailAsRead: MockMarkEmailAsRead(),
        moveEmail: mockMoveEmail,
        removeConversationFromFolder: mockRemoveConversationFromFolder,
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
      when(mockCacheEmails(any)).thenAnswer((_) async => const Right(unit));
      when(mockRecordKnownSenders(any))
          .thenAnswer((_) async => const Right(unit));

      orderedBloc
          .add(const EmailListRefreshRequested(folderId: 'folder-1'));
      await orderedBloc.stream.firstWhere((s) => s is EmailListLoaded);

      final captured = verify(mockCacheEmails(captureAny)).captured;
      expect(captured, hasLength(1),
          reason: 'one write, not a clear followed by a write');
      final params = captured.single as CacheEmailsParams;
      expect(params.replaceFolder, isTrue,
          reason: 'the fresh page must replace the folder, not merge into it');
      expect(params.folderId, 'folder-1');
      expect(params.emails.map((e) => e.id), ['id1']);
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
        forgetCachedEmails: mockForgetCachedEmails,
        markEmailAsRead: MockMarkEmailAsRead(),
        moveEmail: mockMoveEmail,
        removeConversationFromFolder: mockRemoveConversationFromFolder,
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

  // ---------------------------------------------------------------------------
  // EmailListCacheRefreshRequested — the poller's repaint must not be dropped
  // ---------------------------------------------------------------------------

  group('EmailListCacheRefreshRequested (active account)', () {
    setUp(() => fakeAccountManager.account = _account);

    // Regression: the handler returned when the state wasn't Loaded — which is
    // precisely the cold start whose first fetch failed with an empty cache,
    // the state MailPollerCubit's first-cycle staleness check exists to repair.
    test('a repaint arriving on a failed cold start loads the folder instead',
        () async {
      when(mockGetCachedEmails(any)).thenAnswer((_) async => const Right([]));
      when(mockGetEmails(any)).thenAnswer(
          (_) async => const Left(NetworkFailure(message: 'No network')));
      bloc.add(const EmailListLoadRequested(
        folderId: 'folder-1',
        folderDisplayName: 'Inbox',
      ));
      await bloc.stream.firstWhere((s) => s is EmailListError);

      when(mockGetEmails(any))
          .thenAnswer((_) async => Right([_email('id1')]));
      bloc.add(const EmailListCacheRefreshRequested());

      final state = await bloc.stream.firstWhere((s) => s is EmailListLoaded)
          as EmailListLoaded;
      expect(state.emails.map((e) => e.id), ['id1']);
      expect(state.currentFolderId, 'folder-1',
          reason: 'the reload must target the folder that failed to load');
      expect(state.currentFolderName, 'Inbox');
    });

    // Regression: HomePage routes a poll here while a search or a focused
    // thread is showing, expecting the bloc to defer the repaint. Standing
    // down was right; losing the signal was not.
    test('a repaint deferred during a search is spent when the search clears',
        () async {
      await _loadEmails([_email('id1')], folderId: 'folder-1');
      when(mockSearchEmails(any))
          .thenAnswer((_) async => Right([_email('hit')]));
      bloc.add(const EmailListSearchRequested(query: 'q'));
      await bloc.stream.firstWhere(
          (s) => s is EmailListLoaded && s.activeSearchQuery == 'q');

      clearInteractions(mockGetCachedEmails);
      when(mockGetCachedEmails(any))
          .thenAnswer((_) async => Right([_email('id1'), _email('id2')]));
      bloc.add(const EmailListCacheRefreshRequested());
      await pumpEventQueue();

      expect((bloc.state as EmailListLoaded).emails.map((e) => e.id), ['hit'],
          reason: 'the search results are what the user is looking at');
      verifyNever(mockGetCachedEmails(any));

      // Clearing the search re-fetches the folder and that fetch fails, so what
      // is left on screen is the repaint that was owed — not the dismissed
      // search results.
      when(mockGetEmails(any)).thenAnswer(
          (_) async => const Left(NetworkFailure(message: 'No network')));
      bloc.add(const EmailListSearchCleared());
      await pumpEventQueue();

      expect((bloc.state as EmailListLoaded).emails.map((e) => e.id),
          ['id1', 'id2']);
    });

    test('a repaint deferred during a focused thread is spent when it clears',
        () async {
      await _loadEmails([_email('id1', conversationId: 'conv-a')],
          folderId: 'folder-1');
      when(mockGetConversationThread(any)).thenAnswer((_) async =>
          Right([_email('id1', conversationId: 'conv-a')]));
      bloc.add(const EmailListThreadFocusRequested(emailId: 'id1'));
      await bloc.stream.firstWhere(
          (s) => s is EmailListLoaded && s.focusedThreadId == 'conv-a');

      when(mockGetCachedEmails(any))
          .thenAnswer((_) async => Right([_email('id1'), _email('id2')]));
      bloc.add(const EmailListCacheRefreshRequested());
      await pumpEventQueue();
      expect((bloc.state as EmailListLoaded).focusedThreadId, 'conv-a');

      when(mockGetEmails(any)).thenAnswer(
          (_) async => const Left(NetworkFailure(message: 'No network')));
      bloc.add(const EmailListThreadFocusCleared());
      await pumpEventQueue();

      expect((bloc.state as EmailListLoaded).emails.map((e) => e.id),
          ['id1', 'id2']);
    });

    // Regression: a repaint that shortened the list left the server offset
    // past the end of the folder, so the next Load-more skipped the rows that
    // had shifted up into page one and left a hole nothing ever filled.
    test('a repaint that shortens the folder pulls the server offset back',
        () async {
      final page = List.generate(25, (i) => _email('id$i'));
      when(mockGetCachedEmails(any)).thenAnswer((_) async => const Right([]));
      when(mockGetEmails(any)).thenAnswer((_) async => Right(page));
      bloc.add(const EmailListLoadRequested(folderId: 'folder-1'));
      await bloc.stream.firstWhere(
          (s) => s is EmailListLoaded && s.emails.length == 25);

      // Five were deleted elsewhere, so the poller's cache is 20 rows deep.
      when(mockGetCachedEmails(any))
          .thenAnswer((_) async => Right(page.take(20).toList()));
      bloc.add(const EmailListCacheRefreshRequested());
      await pumpEventQueue();
      expect((bloc.state as EmailListLoaded).emails, hasLength(20));

      clearInteractions(mockGetEmails);
      when(mockGetEmails(any)).thenAnswer((_) async => const Right([]));
      bloc.add(const EmailListLoadMoreRequested());
      await pumpEventQueue();

      final params =
          verify(mockGetEmails(captureAny)).captured.single as GetEmailsParams;
      expect(params.skip, 20,
          reason: 'skip 25 would jump the five rows that moved up');
    });

    test('a repaint never raises the offset above what was paged in', () async {
      // Cross-folder conversation expansion puts more rows on screen than the
      // server was ever asked for, so the cached count is a ceiling rather
      // than a measurement of how far in we have read.
      when(mockGetCachedEmails(any)).thenAnswer((_) async => const Right([]));
      when(mockGetEmails(any))
          .thenAnswer((_) async => Right(List.generate(25, (i) => _email('id$i'))));
      bloc.add(const EmailListLoadRequested(folderId: 'folder-1'));
      await bloc.stream.firstWhere(
          (s) => s is EmailListLoaded && s.emails.length == 25);

      when(mockGetCachedEmails(any)).thenAnswer(
          (_) async => Right(List.generate(40, (i) => _email('id$i'))));
      bloc.add(const EmailListCacheRefreshRequested());
      await pumpEventQueue();

      clearInteractions(mockGetEmails);
      when(mockGetEmails(any)).thenAnswer((_) async => const Right([]));
      bloc.add(const EmailListLoadMoreRequested());
      await pumpEventQueue();

      final params =
          verify(mockGetEmails(captureAny)).captured.single as GetEmailsParams;
      expect(params.skip, 25);
    });
  });

  // ---------------------------------------------------------------------------
  // EmailListRefreshRequested — search guard
  // ---------------------------------------------------------------------------

  group('EmailListRefreshRequested during a search', () {
    // Regression: the handler guarded a focused thread but not a search, so a
    // network refresh — the manual Refresh button, the mobile foreground timer,
    // or a poll on a folder whose cache the poller did not write — replaced the
    // results with the folder's contents.
    test('re-runs the query instead of replacing it with the folder', () async {
      await _loadEmails([_email('folder-row')], folderId: 'folder-1');
      when(mockSearchEmails(any))
          .thenAnswer((_) async => Right([_email('hit')]));
      bloc.add(const EmailListSearchRequested(query: 'q'));
      await bloc.stream.firstWhere(
          (s) => s is EmailListLoaded && s.activeSearchQuery == 'q');

      clearInteractions(mockGetEmails);
      when(mockSearchEmails(any)).thenAnswer(
          (_) async => Right([_email('hit'), _email('hit-2')]));
      bloc.add(const EmailListRefreshRequested());
      await pumpEventQueue();

      final state = bloc.state as EmailListLoaded;
      expect(state.activeSearchQuery, 'q');
      expect(state.emails.map((e) => e.id), ['hit', 'hit-2']);
      expect(state.isLoadingFresh, isFalse);
      verifyNever(mockGetEmails(any));
    });

    test('a failed re-run leaves the results on screen', () async {
      await _loadEmails([_email('folder-row')], folderId: 'folder-1');
      when(mockSearchEmails(any))
          .thenAnswer((_) async => Right([_email('hit')]));
      bloc.add(const EmailListSearchRequested(query: 'q'));
      await bloc.stream.firstWhere(
          (s) => s is EmailListLoaded && s.activeSearchQuery == 'q');

      when(mockSearchEmails(any)).thenAnswer(
          (_) async => const Left(NetworkFailure(message: 'No network')));
      bloc.add(const EmailListRefreshRequested());
      await pumpEventQueue();

      final state = bloc.state as EmailListLoaded;
      expect(state.emails.map((e) => e.id), ['hit']);
      expect(state.isLoadingFresh, isFalse);
    });
  });
}

class _FakeActiveAccountManager extends Fake implements AccountManager {
  @override
  Account? get activeAccount => _account;
}
