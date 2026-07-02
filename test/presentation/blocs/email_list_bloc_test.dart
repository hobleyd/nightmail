import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
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

    bloc = EmailListBloc(
      getEmails: mockGetEmails,
      getCachedEmails: mockGetCachedEmails,
      clearEmailCacheForFolder: MockClearEmailCacheForFolder(),
      markEmailAsRead: MockMarkEmailAsRead(),
      moveEmail: mockMoveEmail,
      reportJunk: MockReportJunk(),
      deleteEmail: MockDeleteEmail(),
      emptyFolder: MockEmptyFolder(),
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
}
