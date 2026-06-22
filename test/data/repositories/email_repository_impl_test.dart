import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/data/datasources/local/email_local_datasource.dart';
import 'package:nightmail/data/datasources/local/folder_local_datasource.dart';
import 'package:nightmail/data/datasources/remote/email_remote_datasource.dart';
import 'package:nightmail/data/models/email_address_model.dart';
import 'package:nightmail/data/models/email_folder_model.dart';
import 'package:nightmail/data/models/email_model.dart';
import 'package:nightmail/data/repositories/email_repository_impl.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';

import 'email_repository_impl_test.mocks.dart';

@GenerateMocks([AccountManager, EmailLocalDatasource, FolderLocalDatasource, EmailRemoteDatasource])
void main() {
  late EmailRepositoryImpl repository;
  late MockAccountManager mockAccountManager;
  late MockEmailLocalDatasource mockLocalDatasource;
  late MockFolderLocalDatasource mockFolderLocalDatasource;
  late MockEmailRemoteDatasource mockRemoteDatasource;

  setUp(() {
    mockAccountManager = MockAccountManager();
    mockLocalDatasource = MockEmailLocalDatasource();
    mockFolderLocalDatasource = MockFolderLocalDatasource();
    mockRemoteDatasource = MockEmailRemoteDatasource();

    when(mockAccountManager.emailDatasource).thenReturn(mockRemoteDatasource);
    // Return null active account so getEmails() skips cache write by default
    when(mockAccountManager.activeAccount).thenReturn(null);

    repository = EmailRepositoryImpl(
      accountManager: mockAccountManager,
      localDatasource: mockLocalDatasource,
      folderLocalDatasource: mockFolderLocalDatasource,
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

    test('clears folder cache before caching on first page (skip=0)', () async {
      when(mockRemoteDatasource.getEmails(
        folderId: anyNamed('folderId'),
        top: anyNamed('top'),
        skip: anyNamed('skip'),
        filter: anyNamed('filter'),
        orderBy: anyNamed('orderBy'),
      )).thenAnswer((_) async => [tEmailModel]);
      when(mockLocalDatasource.clearCacheForFolder(
        accountId: anyNamed('accountId'),
        folderId: anyNamed('folderId'),
      )).thenAnswer((_) async {});
      when(mockLocalDatasource.cacheEmails(
        accountId: anyNamed('accountId'),
        folderId: anyNamed('folderId'),
        emails: anyNamed('emails'),
      )).thenAnswer((_) async {});
      when(mockAccountManager.activeAccount).thenReturn(tAccount);

      await repository.getEmails(folderId: 'folder-1', skip: 0);
      // Two ticks: one for clearCacheForFolder, one for cacheEmails
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      verify(mockLocalDatasource.clearCacheForFolder(
        accountId: 'account-1',
        folderId: 'folder-1',
      )).called(1);
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

  group('getMailFolders', () {
    test('returns Right(folders) on datasource success', () async {
      when(mockRemoteDatasource.getMailFolders())
          .thenAnswer((_) async => [tFolderModel]);
      when(mockRemoteDatasource.getChildFolders(any))
          .thenAnswer((_) async => []);

      final result = await repository.getMailFolders();

      expect(result.isRight(), isTrue);
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
    test('updates isRead in cache after successful remote call', () async {
      when(mockRemoteDatasource.updateEmailReadStatus(
        id: anyNamed('id'),
        isRead: anyNamed('isRead'),
      )).thenAnswer((_) async => tEmailModel);
      when(mockLocalDatasource.updateEmailReadStatusInCache(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
        isRead: anyNamed('isRead'),
      )).thenAnswer((_) async {});
      when(mockAccountManager.activeAccount).thenReturn(tAccount);

      final result = await repository.markAsRead(id: 'email-1', isRead: true);

      expect(result.isRight(), isTrue);
      await Future.delayed(Duration.zero);
      verify(mockLocalDatasource.updateEmailReadStatusInCache(
        accountId: 'account-1',
        emailId: 'email-1',
        isRead: true,
      )).called(1);
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
    test('removes email from cache after successful remote delete', () async {
      when(mockRemoteDatasource.deleteEmail(any)).thenAnswer((_) async {});
      when(mockLocalDatasource.deleteEmailFromCache(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
      )).thenAnswer((_) async {});
      when(mockAccountManager.activeAccount).thenReturn(tAccount);

      final result = await repository.deleteEmail('email-1');

      expect(result.isRight(), isTrue);
      await Future.delayed(Duration.zero);
      verify(mockLocalDatasource.deleteEmailFromCache(
        accountId: 'account-1',
        emailId: 'email-1',
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
    test('removes email from cache after successful remote move', () async {
      when(mockRemoteDatasource.moveEmail(any, any))
          .thenAnswer((_) async => 'new-id');
      when(mockLocalDatasource.deleteEmailFromCache(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
      )).thenAnswer((_) async {});
      when(mockAccountManager.activeAccount).thenReturn(tAccount);

      final result = await repository.moveEmail('email-1', 'folder-2');

      expect(result.isRight(), isTrue);
      await Future.delayed(Duration.zero);
      verify(mockLocalDatasource.deleteEmailFromCache(
        accountId: 'account-1',
        emailId: 'email-1',
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
}
