import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/data/datasources/local/email_local_datasource.dart';
import 'package:nightmail/data/datasources/local/folder_local_datasource.dart';
import 'package:nightmail/data/datasources/local/pending_operations_datasource.dart';
import 'package:nightmail/data/datasources/remote/email_remote_datasource.dart';
import 'package:nightmail/data/models/email_address_model.dart';
import 'package:nightmail/data/models/email_folder_model.dart';
import 'package:nightmail/data/models/email_model.dart';
import 'package:nightmail/data/repositories/email_repository_impl.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/network/connectivity_service.dart';
import 'package:nightmail/infrastructure/sync/outbox_drain_service.dart';

import 'email_repository_impl_test.mocks.dart';

@GenerateMocks([
  AccountManager,
  EmailLocalDatasource,
  FolderLocalDatasource,
  EmailRemoteDatasource,
  PendingOperationsDatasource,
  OutboxDrainService,
  ConnectivityService,
])
void main() {
  late EmailRepositoryImpl repository;
  late MockAccountManager mockAccountManager;
  late MockEmailLocalDatasource mockLocalDatasource;
  late MockFolderLocalDatasource mockFolderLocalDatasource;
  late MockEmailRemoteDatasource mockRemoteDatasource;
  late MockPendingOperationsDatasource mockPendingOperations;
  late MockOutboxDrainService mockOutboxDrainService;
  late MockConnectivityService mockConnectivityService;

  setUp(() {
    mockAccountManager = MockAccountManager();
    mockLocalDatasource = MockEmailLocalDatasource();
    mockFolderLocalDatasource = MockFolderLocalDatasource();
    mockRemoteDatasource = MockEmailRemoteDatasource();
    mockPendingOperations = MockPendingOperationsDatasource();
    mockOutboxDrainService = MockOutboxDrainService();
    mockConnectivityService = MockConnectivityService();

    when(mockAccountManager.emailDatasource).thenReturn(mockRemoteDatasource);
    // Return null active account so getEmails() skips cache write by default
    when(mockAccountManager.activeAccount).thenReturn(null);
    when(mockPendingOperations.enqueue(
      accountId: anyNamed('accountId'),
      emailId: anyNamed('emailId'),
      folderId: anyNamed('folderId'),
      opType: anyNamed('opType'),
      payload: anyNamed('payload'),
    )).thenAnswer((_) async => 1);
    when(mockOutboxDrainService.drainForAccount(any))
        .thenAnswer((_) async {});
    // Online by default — tests that need offline behavior override this.
    when(mockConnectivityService.isOnline).thenAnswer((_) async => true);

    repository = EmailRepositoryImpl(
      accountManager: mockAccountManager,
      localDatasource: mockLocalDatasource,
      folderLocalDatasource: mockFolderLocalDatasource,
      pendingOperations: mockPendingOperations,
      outboxDrainService: mockOutboxDrainService,
      connectivityService: mockConnectivityService,
    );
  });

  const tAccount = MicrosoftAccount(
    id: 'account-1',
    displayName: 'Test',
    emailAddress: 'test@example.com',
    tenantId: 'common',
  );

  final tEmailModel = EmailModel(
    id: 'email-1',
    subject: 'Test',
    from: const EmailAddressModel(address: 'a@b.com'),
    toRecipients: const [],
    ccRecipients: const [],
    bodyPreview: '',
    body: '',
    bodyType: EmailBodyType.text,
    isRead: false,
    receivedDateTime: DateTime(2026, 6, 1),
    importance: EmailImportance.normal,
  );

  final tFolderModel = EmailFolderModel(
    id: 'folder-1',
    displayName: 'Inbox',
    totalItemCount: 10,
    unreadItemCount: 3,
  );

  group('getEmails', () {
    test('returns Right(emails) on datasource success', () async {
      when(mockRemoteDatasource.getEmails(
        top: anyNamed('top'),
        skip: anyNamed('skip'),
        orderBy: anyNamed('orderBy'),
      )).thenAnswer((_) async => [tEmailModel]);

      final result = await repository.getEmails();

      expect(result, isA<Right<Failure, List<Email>>>());
      final emails = (result as Right).value as List<Email>;
      expect(emails.first.id, 'email-1');
    });

    // Regression: the datasource's HTTP client has a 30-60s connect timeout,
    // so without a fast pre-check, an offline call would hang that long
    // before the caller could fall back to the cache — a "stuck spinner"
    // from the user's perspective even though cached data was ready to show.
    test('returns Left(NetworkFailure) immediately when offline, without '
        'calling the datasource', () async {
      when(mockConnectivityService.isOnline).thenAnswer((_) async => false);

      final result = await repository.getEmails();

      expect(result.isLeft(), isTrue);
      expect((result as Left).value, isA<NetworkFailure>());
      verifyNever(mockRemoteDatasource.getEmails(
        top: anyNamed('top'),
        skip: anyNamed('skip'),
        orderBy: anyNamed('orderBy'),
      ));
    });

    test('caches without clearing on first page (skip=0)', () async {
      when(mockRemoteDatasource.getEmails(
        folderId: anyNamed('folderId'),
        top: anyNamed('top'),
        skip: anyNamed('skip'),
        filter: anyNamed('filter'),
        orderBy: anyNamed('orderBy'),
      )).thenAnswer((_) async => [tEmailModel]);
      when(mockLocalDatasource.cacheEmails(
        accountId: anyNamed('accountId'),
        folderId: anyNamed('folderId'),
        emails: anyNamed('emails'),
      )).thenAnswer((_) async {});
      when(mockAccountManager.activeAccount).thenReturn(tAccount);

      await repository.getEmails(folderId: 'folder-1', skip: 0);
      await Future.delayed(Duration.zero);

      // Cache is cleared only via the explicit ClearEmailCacheForFolder use
      // case on refresh, not implicitly by getEmails — otherwise load-more
      // pagination would wipe out the pages fetched just before it.
      verifyNever(mockLocalDatasource.clearCacheForFolder(
        accountId: anyNamed('accountId'),
        folderId: anyNamed('folderId'),
      ));
      verify(mockLocalDatasource.cacheEmails(
        accountId: 'account-1',
        folderId: 'folder-1',
        emails: anyNamed('emails'),
      )).called(1);
    });

    test('does not clear folder cache on subsequent pages (skip>0)', () async {
      when(mockRemoteDatasource.getEmails(
        folderId: anyNamed('folderId'),
        top: anyNamed('top'),
        skip: anyNamed('skip'),
        filter: anyNamed('filter'),
        orderBy: anyNamed('orderBy'),
      )).thenAnswer((_) async => [tEmailModel]);
      when(mockLocalDatasource.cacheEmails(
        accountId: anyNamed('accountId'),
        folderId: anyNamed('folderId'),
        emails: anyNamed('emails'),
      )).thenAnswer((_) async {});
      when(mockAccountManager.activeAccount).thenReturn(tAccount);

      await repository.getEmails(folderId: 'folder-1', skip: 25);
      await Future.delayed(Duration.zero);

      verifyNever(mockLocalDatasource.clearCacheForFolder(
        accountId: anyNamed('accountId'),
        folderId: anyNamed('folderId'),
      ));
    });

    test('returns Left(ServerFailure) on ServerException', () async {
      when(mockRemoteDatasource.getEmails(
        top: anyNamed('top'),
        skip: anyNamed('skip'),
        orderBy: anyNamed('orderBy'),
      )).thenThrow(const ServerException(message: 'Not found', statusCode: 404));

      final result = await repository.getEmails();

      expect(result, isA<Left<Failure, List<Email>>>());
      final failure = (result as Left).value;
      expect(failure, isA<ServerFailure>());
      expect((failure as ServerFailure).statusCode, 404);
    });

    test('returns Left(AuthFailure) on AuthException', () async {
      when(mockRemoteDatasource.getEmails(
        top: anyNamed('top'),
        skip: anyNamed('skip'),
        orderBy: anyNamed('orderBy'),
      )).thenThrow(const AuthException(message: 'Unauthorized'));

      final result = await repository.getEmails();

      expect(result.isLeft(), isTrue);
      expect((result as Left).value, isA<AuthFailure>());
    });

    test('returns Left(NetworkFailure) on NetworkException', () async {
      when(mockRemoteDatasource.getEmails(
        top: anyNamed('top'),
        skip: anyNamed('skip'),
        orderBy: anyNamed('orderBy'),
      )).thenThrow(const NetworkException(message: 'No connection'));

      final result = await repository.getEmails();

      expect(result.isLeft(), isTrue);
      expect((result as Left).value, isA<NetworkFailure>());
    });
  });

  group('getEmail', () {
    // Regression: list/delta fetches only request a preview select
    // (bodyPreview, no attachments) to keep folder loads and polling cheap,
    // so rows they cache have an empty body. If getEmail() served those rows
    // cache-first without checking, opening a message that was only ever
    // seen via a folder load or background poll (the common case) would
    // show a permanently blank body/no attachments — never falling through
    // to the network fetch that actually has the full content.
    test('falls through to network when the cached row is a thin '
        'list-projection (empty body)', () async {
      final thinCached = EmailModel(
        id: 'email-1',
        subject: 'Test',
        from: const EmailAddressModel(address: 'a@b.com'),
        toRecipients: const [],
        ccRecipients: const [],
        bodyPreview: 'preview only',
        body: '', // list/delta select never includes 'body'
        bodyType: EmailBodyType.text,
        isRead: false,
        receivedDateTime: DateTime(2026, 6, 1),
        importance: EmailImportance.normal,
      );
      final fullFromNetwork = EmailModel(
        id: 'email-1',
        subject: 'Test',
        from: const EmailAddressModel(address: 'a@b.com'),
        toRecipients: const [],
        ccRecipients: const [],
        bodyPreview: 'preview only',
        body: '<p>the real content</p>',
        bodyType: EmailBodyType.html,
        isRead: false,
        receivedDateTime: DateTime(2026, 6, 1),
        importance: EmailImportance.normal,
      );
      when(mockAccountManager.activeAccount).thenReturn(tAccount);
      when(mockLocalDatasource.getCachedEmailById(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
      )).thenAnswer((_) async => thinCached);
      when(mockRemoteDatasource.getEmail(any))
          .thenAnswer((_) async => fullFromNetwork);
      when(mockLocalDatasource.cacheEmails(
        accountId: anyNamed('accountId'),
        folderId: anyNamed('folderId'),
        emails: anyNamed('emails'),
      )).thenAnswer((_) async {});

      final result = await repository.getEmail('email-1');

      expect(result.isRight(), isTrue);
      expect((result as Right).value.body, '<p>the real content</p>');
      verify(mockRemoteDatasource.getEmail('email-1')).called(1);
    });

    test('returns the cached copy without hitting network when it already '
        'has a full body', () async {
      final fullCached = EmailModel(
        id: 'email-1',
        subject: 'Test',
        from: const EmailAddressModel(address: 'a@b.com'),
        toRecipients: const [],
        ccRecipients: const [],
        bodyPreview: 'preview',
        body: '<p>already fetched</p>',
        bodyType: EmailBodyType.html,
        isRead: false,
        receivedDateTime: DateTime(2026, 6, 1),
        importance: EmailImportance.normal,
      );
      when(mockAccountManager.activeAccount).thenReturn(tAccount);
      when(mockLocalDatasource.getCachedEmailById(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
      )).thenAnswer((_) async => fullCached);

      final result = await repository.getEmail('email-1');

      expect(result.isRight(), isTrue);
      expect((result as Right).value.body, '<p>already fetched</p>');
      verifyNever(mockRemoteDatasource.getEmail(any));
    });

    test('falls through to network when nothing is cached', () async {
      when(mockAccountManager.activeAccount).thenReturn(tAccount);
      when(mockLocalDatasource.getCachedEmailById(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
      )).thenAnswer((_) async => null);
      when(mockRemoteDatasource.getEmail(any))
          .thenAnswer((_) async => tEmailModel);
      when(mockLocalDatasource.cacheEmails(
        accountId: anyNamed('accountId'),
        folderId: anyNamed('folderId'),
        emails: anyNamed('emails'),
      )).thenAnswer((_) async {});

      final result = await repository.getEmail('email-1');

      expect(result.isRight(), isTrue);
      verify(mockRemoteDatasource.getEmail('email-1')).called(1);
    });
  });

  group('getMailFolders', () {
    test('returns Right(folders) on datasource success', () async {
      when(mockRemoteDatasource.getMailFolders())
          .thenAnswer((_) async => [tFolderModel]);
      when(mockRemoteDatasource.getChildFolders(any))
          .thenAnswer((_) async => []);

      final result = await repository.getMailFolders();

      expect(result.isRight(), isTrue);
    });

    test('returns Left(NetworkFailure) immediately when offline, without '
        'calling the datasource', () async {
      when(mockConnectivityService.isOnline).thenAnswer((_) async => false);

      final result = await repository.getMailFolders();

      expect(result.isLeft(), isTrue);
      expect((result as Left).value, isA<NetworkFailure>());
      verifyNever(mockRemoteDatasource.getMailFolders());
    });
  });

  group('markAsRead', () {
    test('delegates to datasource and returns updated email', () async {
      final updated = EmailModel(
        id: 'email-1',
        subject: 'Test',
        from: const EmailAddressModel(address: 'a@b.com'),
        toRecipients: const [],
        ccRecipients: const [],
        bodyPreview: '',
        body: '',
        bodyType: EmailBodyType.text,
        isRead: true,
        receivedDateTime: DateTime(2026, 6, 1),
        importance: EmailImportance.normal,
      );
      when(mockRemoteDatasource.updateEmailReadStatus(
        id: anyNamed('id'),
        isRead: anyNamed('isRead'),
      )).thenAnswer((_) async => updated);

      final result = await repository.markAsRead(id: 'email-1', isRead: true);

      expect(result.isRight(), isTrue);
      expect((result as Right).value.isRead, isTrue);
    });
  });

  group('getCachedEmails', () {
    test('returns Right(emails) from local datasource', () async {
      when(mockLocalDatasource.getCachedEmails(
        accountId: anyNamed('accountId'),
        folderId: anyNamed('folderId'),
      )).thenAnswer((_) async => [tEmailModel]);

      final result = await repository.getCachedEmails(
        accountId: 'account-1',
        folderId: '__DEFAULT__',
      );

      expect(result.isRight(), isTrue);
      final emails = (result as Right).value as List<Email>;
      expect(emails.first.id, 'email-1');
    });

    test('returns Right([]) when cache is empty', () async {
      when(mockLocalDatasource.getCachedEmails(
        accountId: anyNamed('accountId'),
        folderId: anyNamed('folderId'),
      )).thenAnswer((_) async => []);

      final result = await repository.getCachedEmails(
        accountId: 'account-1',
        folderId: '__DEFAULT__',
      );

      expect(result.isRight(), isTrue);
      expect((result as Right).value, isEmpty);
    });
  });

  group('clearCacheForAccount', () {
    test('delegates to local datasource', () async {
      when(mockLocalDatasource.clearCacheForAccount(any))
          .thenAnswer((_) async {});

      final result = await repository.clearCacheForAccount('account-1');

      expect(result.isRight(), isTrue);
      verify(mockLocalDatasource.clearCacheForAccount('account-1')).called(1);
    });
  });

  group('markAsRead', () {
    test('reads the cached copy, updates it, and enqueues an outbox op '
        'instead of hitting the network', () async {
      when(mockLocalDatasource.getCachedEmailById(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
      )).thenAnswer((_) async => tEmailModel); // cached, isRead: false
      when(mockLocalDatasource.updateEmailReadStatusInCache(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
        isRead: anyNamed('isRead'),
      )).thenAnswer((_) async {});
      when(mockAccountManager.activeAccount).thenReturn(tAccount);

      final result = await repository.markAsRead(id: 'email-1', isRead: true);

      expect(result.isRight(), isTrue);
      expect((result as Right).value.isRead, isTrue);
      verifyNever(mockRemoteDatasource.updateEmailReadStatus(
        id: anyNamed('id'),
        isRead: anyNamed('isRead'),
      ));
      verify(mockPendingOperations.enqueue(
        accountId: 'account-1',
        emailId: 'email-1',
        opType: PendingOperationType.markRead,
        payload: anyNamed('payload'),
      )).called(1);
      verify(mockLocalDatasource.updateEmailReadStatusInCache(
        accountId: 'account-1',
        emailId: 'email-1',
        isRead: true,
      )).called(1);
    });

    test('still succeeds while offline', () async {
      when(mockLocalDatasource.getCachedEmailById(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
      )).thenAnswer((_) async => tEmailModel);
      when(mockLocalDatasource.updateEmailReadStatusInCache(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
        isRead: anyNamed('isRead'),
      )).thenAnswer((_) async {});
      when(mockAccountManager.activeAccount).thenReturn(tAccount);
      when(mockConnectivityService.isOnline).thenAnswer((_) async => false);

      final result = await repository.markAsRead(id: 'email-1', isRead: true);

      expect(result.isRight(), isTrue);
      expect((result as Right).value.isRead, isTrue);
    });

    test('falls back to the network when the email is not cached', () async {
      when(mockLocalDatasource.getCachedEmailById(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
      )).thenAnswer((_) async => null);
      when(mockRemoteDatasource.updateEmailReadStatus(
        id: anyNamed('id'),
        isRead: anyNamed('isRead'),
      )).thenAnswer((_) async => tEmailModel);
      when(mockAccountManager.activeAccount).thenReturn(tAccount);

      final result = await repository.markAsRead(id: 'email-1', isRead: true);

      expect(result.isRight(), isTrue);
      verify(mockRemoteDatasource.updateEmailReadStatus(
        id: 'email-1',
        isRead: true,
      )).called(1);
      verifyNever(mockPendingOperations.enqueue(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
        opType: anyNamed('opType'),
        payload: anyNamed('payload'),
      ));
    });

    test('does not touch cache when no active account', () async {
      when(mockRemoteDatasource.updateEmailReadStatus(
        id: anyNamed('id'),
        isRead: anyNamed('isRead'),
      )).thenAnswer((_) async => tEmailModel);

      await repository.markAsRead(id: 'email-1', isRead: true);

      verifyNever(mockLocalDatasource.updateEmailReadStatusInCache(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
        isRead: anyNamed('isRead'),
      ));
    });
  });

  group('deleteEmail', () {
    test('removes email from cache and enqueues an outbox op instead of '
        'hitting the network', () async {
      when(mockLocalDatasource.deleteEmailFromCache(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
      )).thenAnswer((_) async {});
      when(mockAccountManager.activeAccount).thenReturn(tAccount);

      final result = await repository.deleteEmail('email-1');

      expect(result.isRight(), isTrue);
      verifyNever(mockRemoteDatasource.deleteEmail(any));
      verify(mockPendingOperations.enqueue(
        accountId: 'account-1',
        emailId: 'email-1',
        opType: PendingOperationType.delete,
        payload: anyNamed('payload'),
      )).called(1);
      verify(mockLocalDatasource.deleteEmailFromCache(
        accountId: 'account-1',
        emailId: 'email-1',
      )).called(1);
    });

    // Regression: the outbox path enqueues + updates the cache only — no
    // network call — so it must not be gated behind the same "are we
    // online" check that protects real network calls from a long connect
    // timeout. That check briefly leaked onto this path and made every
    // offline delete/move/junk/mark-read fail immediately instead of
    // queuing.
    test('still succeeds while offline', () async {
      when(mockLocalDatasource.deleteEmailFromCache(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
      )).thenAnswer((_) async {});
      when(mockAccountManager.activeAccount).thenReturn(tAccount);
      when(mockConnectivityService.isOnline).thenAnswer((_) async => false);

      final result = await repository.deleteEmail('email-1');

      expect(result.isRight(), isTrue);
      verify(mockPendingOperations.enqueue(
        accountId: 'account-1',
        emailId: 'email-1',
        opType: PendingOperationType.delete,
        payload: anyNamed('payload'),
      )).called(1);
    });

    test('does not touch cache when no active account', () async {
      when(mockRemoteDatasource.deleteEmail(any)).thenAnswer((_) async {});

      final result = await repository.deleteEmail('email-1');

      expect(result.isRight(), isTrue);
      verifyNever(mockLocalDatasource.deleteEmailFromCache(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
      ));
    });
  });

  group('createServerDraft', () {
    test('returns Right(draftId) on datasource success', () async {
      when(mockRemoteDatasource.createServerDraft(
        toAddresses: anyNamed('toAddresses'),
        ccAddresses: anyNamed('ccAddresses'),
        subject: anyNamed('subject'),
        body: anyNamed('body'),
      )).thenAnswer((_) async => 'draft-id-123');

      final result = await repository.createServerDraft(
        toAddresses: ['to@example.com'],
        subject: 'Draft',
        body: 'Body',
      );

      expect(result.getOrElse((_) => ''), equals('draft-id-123'));
      verify(mockRemoteDatasource.createServerDraft(
        toAddresses: ['to@example.com'],
        ccAddresses: [],
        subject: 'Draft',
        body: 'Body',
      )).called(1);
    });

    test('returns Left(ServerFailure) on ServerException', () async {
      when(mockRemoteDatasource.createServerDraft(
        toAddresses: anyNamed('toAddresses'),
        ccAddresses: anyNamed('ccAddresses'),
        subject: anyNamed('subject'),
        body: anyNamed('body'),
      )).thenThrow(const ServerException(message: 'Server error'));

      final result = await repository.createServerDraft(
        toAddresses: ['to@example.com'],
        subject: 'Draft',
        body: 'Body',
      );

      expect(result.isLeft(), isTrue);
      expect(result.fold((f) => f, (_) => null), isA<ServerFailure>());
    });
  });

  group('updateServerDraft', () {
    test('returns Right(draftId) on datasource success', () async {
      when(mockRemoteDatasource.updateServerDraft(
        draftId: anyNamed('draftId'),
        toAddresses: anyNamed('toAddresses'),
        ccAddresses: anyNamed('ccAddresses'),
        subject: anyNamed('subject'),
        body: anyNamed('body'),
      )).thenAnswer((_) async => 'draft-id-123');

      final result = await repository.updateServerDraft(
        draftId: 'draft-id-123',
        toAddresses: ['to@example.com'],
        subject: 'Draft',
        body: 'Body',
      );

      expect(result.getOrElse((_) => ''), equals('draft-id-123'));
    });

    test('returns Left(NetworkFailure) on NetworkException', () async {
      when(mockRemoteDatasource.updateServerDraft(
        draftId: anyNamed('draftId'),
        toAddresses: anyNamed('toAddresses'),
        ccAddresses: anyNamed('ccAddresses'),
        subject: anyNamed('subject'),
        body: anyNamed('body'),
      )).thenThrow(const NetworkException(message: 'No connection'));

      final result = await repository.updateServerDraft(
        draftId: 'draft-id-123',
        toAddresses: ['to@example.com'],
        subject: 'Draft',
        body: 'Body',
      );

      expect(result.isLeft(), isTrue);
      expect(result.fold((f) => f, (_) => null), isA<NetworkFailure>());
    });
  });

  group('deleteServerDraft', () {
    test('returns Right(unit) on datasource success', () async {
      when(mockRemoteDatasource.deleteServerDraft(
        draftId: anyNamed('draftId'),
      )).thenAnswer((_) async {});

      final result = await repository.deleteServerDraft(draftId: 'draft-id-123');

      expect(result.isRight(), isTrue);
      verify(mockRemoteDatasource.deleteServerDraft(draftId: 'draft-id-123'))
          .called(1);
    });

    test('returns Left(ServerFailure) on ServerException', () async {
      when(mockRemoteDatasource.deleteServerDraft(
        draftId: anyNamed('draftId'),
      )).thenThrow(const ServerException(message: 'Not found'));

      final result =
          await repository.deleteServerDraft(draftId: 'draft-id-123');

      expect(result.isLeft(), isTrue);
      expect(result.fold((f) => f, (_) => null), isA<ServerFailure>());
    });
  });

  group('moveEmail', () {
    test('removes email from cache and enqueues an outbox op instead of '
        'hitting the network', () async {
      when(mockLocalDatasource.deleteEmailFromCache(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
      )).thenAnswer((_) async {});
      when(mockAccountManager.activeAccount).thenReturn(tAccount);

      final result = await repository.moveEmail('email-1', 'folder-2');

      expect(result.isRight(), isTrue);
      verifyNever(mockRemoteDatasource.moveEmail(any, any));
      verify(mockPendingOperations.enqueue(
        accountId: 'account-1',
        emailId: 'email-1',
        opType: PendingOperationType.move,
        payload: anyNamed('payload'),
      )).called(1);
      verify(mockLocalDatasource.deleteEmailFromCache(
        accountId: 'account-1',
        emailId: 'email-1',
      )).called(1);
    });

    test('still succeeds while offline', () async {
      when(mockLocalDatasource.deleteEmailFromCache(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
      )).thenAnswer((_) async {});
      when(mockAccountManager.activeAccount).thenReturn(tAccount);
      when(mockConnectivityService.isOnline).thenAnswer((_) async => false);

      final result = await repository.moveEmail('email-1', 'folder-2');

      expect(result.isRight(), isTrue);
      verify(mockPendingOperations.enqueue(
        accountId: 'account-1',
        emailId: 'email-1',
        opType: PendingOperationType.move,
        payload: anyNamed('payload'),
      )).called(1);
    });

    test('does not touch cache when no active account', () async {
      when(mockRemoteDatasource.moveEmail(any, any))
          .thenAnswer((_) async => 'new-id');

      final result = await repository.moveEmail('email-1', 'folder-2');

      expect(result.isRight(), isTrue);
      verifyNever(mockLocalDatasource.deleteEmailFromCache(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
      ));
    });
  });

  // ---------------------------------------------------------------------------
  // forwardEmail — ccAddresses plumbing
  // ---------------------------------------------------------------------------

  group('forwardEmail', () {
    test('passes ccAddresses to datasource', () async {
      when(mockRemoteDatasource.forwardEmail(
        messageId: anyNamed('messageId'),
        toAddresses: anyNamed('toAddresses'),
        ccAddresses: anyNamed('ccAddresses'),
        comment: anyNamed('comment'),
        excludedAttachmentIds: anyNamed('excludedAttachmentIds'),
        bodyType: anyNamed('bodyType'),
        newAttachments: anyNamed('newAttachments'),
      )).thenAnswer((_) async {});

      await repository.forwardEmail(
        messageId: 'msg1',
        toAddresses: ['to@example.com'],
        ccAddresses: ['cc@example.com'],
        comment: 'FYI',
      );

      verify(mockRemoteDatasource.forwardEmail(
        messageId: 'msg1',
        toAddresses: ['to@example.com'],
        ccAddresses: ['cc@example.com'],
        comment: 'FYI',
        excludedAttachmentIds: anyNamed('excludedAttachmentIds'),
        bodyType: anyNamed('bodyType'),
        newAttachments: anyNamed('newAttachments'),
      )).called(1);
    });

    test('passes empty ccAddresses when no Cc specified', () async {
      when(mockRemoteDatasource.forwardEmail(
        messageId: anyNamed('messageId'),
        toAddresses: anyNamed('toAddresses'),
        ccAddresses: anyNamed('ccAddresses'),
        comment: anyNamed('comment'),
        excludedAttachmentIds: anyNamed('excludedAttachmentIds'),
        bodyType: anyNamed('bodyType'),
        newAttachments: anyNamed('newAttachments'),
      )).thenAnswer((_) async {});

      await repository.forwardEmail(
        messageId: 'msg1',
        toAddresses: ['to@example.com'],
        comment: 'FYI',
      );

      verify(mockRemoteDatasource.forwardEmail(
        messageId: 'msg1',
        toAddresses: ['to@example.com'],
        ccAddresses: [],
        comment: 'FYI',
        excludedAttachmentIds: anyNamed('excludedAttachmentIds'),
        bodyType: anyNamed('bodyType'),
        newAttachments: anyNamed('newAttachments'),
      )).called(1);
    });

    test('returns Right(unit) on success', () async {
      when(mockRemoteDatasource.forwardEmail(
        messageId: anyNamed('messageId'),
        toAddresses: anyNamed('toAddresses'),
        ccAddresses: anyNamed('ccAddresses'),
        comment: anyNamed('comment'),
        excludedAttachmentIds: anyNamed('excludedAttachmentIds'),
        bodyType: anyNamed('bodyType'),
        newAttachments: anyNamed('newAttachments'),
      )).thenAnswer((_) async {});

      final result = await repository.forwardEmail(
        messageId: 'msg1',
        toAddresses: ['to@example.com'],
        ccAddresses: ['cc@example.com'],
        comment: 'FYI',
      );

      expect(result.isRight(), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // replyToEmail — recipient plumbing
  // ---------------------------------------------------------------------------

  group('replyToEmail', () {
    test('passes toAddresses and ccAddresses to datasource on plain reply', () async {
      when(mockRemoteDatasource.replyToEmail(
        messageId: anyNamed('messageId'),
        comment: anyNamed('comment'),
        replyAll: anyNamed('replyAll'),
        toAddresses: anyNamed('toAddresses'),
        ccAddresses: anyNamed('ccAddresses'),
        bodyType: anyNamed('bodyType'),
        newAttachments: anyNamed('newAttachments'),
      )).thenAnswer((_) async {});

      await repository.replyToEmail(
        messageId: 'msg1',
        comment: 'Thanks',
        replyAll: false,
        toAddresses: ['sender@example.com'],
        ccAddresses: ['cc@example.com'],
      );

      verify(mockRemoteDatasource.replyToEmail(
        messageId: 'msg1',
        comment: 'Thanks',
        replyAll: false,
        toAddresses: ['sender@example.com'],
        ccAddresses: ['cc@example.com'],
        bodyType: anyNamed('bodyType'),
        newAttachments: anyNamed('newAttachments'),
      )).called(1);
    });

    test('passes replyAll=true when replying to all', () async {
      when(mockRemoteDatasource.replyToEmail(
        messageId: anyNamed('messageId'),
        comment: anyNamed('comment'),
        replyAll: anyNamed('replyAll'),
        toAddresses: anyNamed('toAddresses'),
        ccAddresses: anyNamed('ccAddresses'),
        bodyType: anyNamed('bodyType'),
        newAttachments: anyNamed('newAttachments'),
      )).thenAnswer((_) async {});

      await repository.replyToEmail(
        messageId: 'msg1',
        comment: 'Thanks',
        replyAll: true,
        toAddresses: ['a@example.com', 'b@example.com'],
        ccAddresses: ['cc1@example.com', 'cc2@example.com'],
      );

      verify(mockRemoteDatasource.replyToEmail(
        messageId: 'msg1',
        comment: 'Thanks',
        replyAll: true,
        toAddresses: ['a@example.com', 'b@example.com'],
        ccAddresses: ['cc1@example.com', 'cc2@example.com'],
        bodyType: anyNamed('bodyType'),
        newAttachments: anyNamed('newAttachments'),
      )).called(1);
    });
  });
}
