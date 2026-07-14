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
import 'package:nightmail/presentation/blocs/email_list/email_list_bloc.dart';
import 'package:nightmail/presentation/blocs/email_list/email_list_event.dart';
import 'package:nightmail/presentation/blocs/email_list/email_list_state.dart';

import 'email_list_bloc_test.mocks.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _addr = EmailAddress(address: 'a@b.com', name: 'A');

Email _email(String id, {String? conversationId}) => Email(
      id: id,
      subject: 'Subject $id',
      from: _addr,
      toRecipients: const [],
      ccRecipients: const [],
      bodyPreview: '',
      body: '',
      bodyType: EmailBodyType.text,
      isRead: true,
      receivedDateTime: DateTime(2026),
      importance: EmailImportance.normal,
      conversationId: conversationId,
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
])
void main() {
  late EmailListBloc bloc;
  late MockGetEmails mockGetEmails;
  late MockGetCachedEmails mockGetCachedEmails;
  late MockMoveEmail mockMoveEmail;
  late MockEmptyFolder mockEmptyFolder;

  setUpAll(() {
    // Mockito needs dummy values for sealed/generic types it can't construct.
    provideDummy<Either<Failure, List<Email>>>(const Right([]));
    provideDummy<Either<Failure, Unit>>(const Right(unit));
    provideDummy<Set<String>>(<String>{});
  });

  setUp(() {
    mockGetEmails = MockGetEmails();
    mockGetCachedEmails = MockGetCachedEmails();
    mockMoveEmail = MockMoveEmail();
    mockEmptyFolder = MockEmptyFolder();

    bloc = EmailListBloc(
      getEmails: mockGetEmails,
      getCachedEmails: mockGetCachedEmails,
      cacheEmails: MockCacheEmails(),
      clearEmailCacheForFolder: MockClearEmailCacheForFolder(),
      markEmailAsRead: MockMarkEmailAsRead(),
      moveEmail: mockMoveEmail,
      reportJunk: MockReportJunk(),
      deleteEmail: MockDeleteEmail(),
      emptyFolder: mockEmptyFolder,
      accountManager: _FakeAccountManager(),
      recordKnownSenders: MockRecordKnownSenders(),
      classifyEmails: MockClassifyEmails(),
      trainSpamFilter: MockTrainSpamFilter(),
      searchEmails: MockSearchEmails(),
    );
  });

  tearDown(() async => bloc.close());

  Future<void> _loadEmails(List<Email> emails) async {
    when(mockGetCachedEmails(any)).thenAnswer((_) async => const Right([]));
    when(mockGetEmails(any)).thenAnswer((_) async => Right(emails));
    bloc.add(const EmailListLoadRequested());
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
