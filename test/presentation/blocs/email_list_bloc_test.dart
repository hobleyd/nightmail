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
