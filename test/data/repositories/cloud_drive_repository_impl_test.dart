import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/data/datasources/remote/cloud_drive_datasource.dart';
import 'package:nightmail/data/repositories/cloud_drive_repository_impl.dart';
import 'package:nightmail/domain/entities/cloud_document.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';

import 'cloud_drive_repository_impl_test.mocks.dart';

/// Which account fetches a linked document, and what happens when it cannot.
///
/// The link decides the provider, so these tests are all about the mail arriving
/// in one place and the file living in another.
@GenerateMocks([AccountManager, CloudDriveDatasource])
void main() {
  late MockAccountManager accounts;
  late CloudDriveRepositoryImpl repository;

  const driveLink = CloudDocumentLink(
    provider: CloudDriveProvider.google,
    url: 'https://drive.google.com/file/d/1AbCdEfGhIjKlMn/view',
    fileId: '1AbCdEfGhIjKlMn',
  );

  final document = CloudDocument(
    name: 'Budget.pdf',
    contentType: 'application/pdf',
    bytes: Uint8List.fromList([1, 2, 3]),
  );

  GmailAccount gmail(String id) => GmailAccount(
        id: id,
        displayName: id,
        emailAddress: '$id@gmail.com',
      );

  setUp(() {
    accounts = MockAccountManager();
    repository = CloudDriveRepositoryImpl(accountManager: accounts);
  });

  test('a Drive link is fetched by a Google account even with none active',
      () async {
    // The reader is in their Exchange mailbox; the file is in Drive. The
    // candidate list is the Gmail accounts regardless of what is active.
    final datasource = MockCloudDriveDatasource();
    when(accounts.cloudDriveCandidates(CloudDriveProvider.google))
        .thenReturn([gmail('ann')]);
    when(accounts.hasCloudDriveAccess('ann')).thenAnswer((_) async => true);
    when(accounts.cloudDriveDatasourceForAccount('ann')).thenReturn(datasource);
    when(datasource.fetchDocument(driveLink)).thenAnswer((_) async => document);

    final result = await repository.fetchDocument(driveLink);

    expect(result.toNullable(), document);
  });

  test('no account of that provider is a settled "not here"', () async {
    when(accounts.cloudDriveCandidates(CloudDriveProvider.google))
        .thenReturn([]);

    final result = await repository.fetchDocument(driveLink);

    expect(result.getLeft().toNullable(), isA<CloudDriveUnavailable>());
  });

  test('an account that has never been asked for access is offered', () async {
    when(accounts.cloudDriveCandidates(CloudDriveProvider.google))
        .thenReturn([gmail('ann')]);
    when(accounts.hasCloudDriveAccess('ann')).thenAnswer((_) async => false);
    when(accounts.accountById('ann')).thenReturn(gmail('ann'));

    final result = await repository.fetchDocument(driveLink);

    final failure = result.getLeft().toNullable();
    expect(failure, isA<CloudDriveAccessNotGranted>());
    expect((failure as CloudDriveAccessNotGranted).accountEmail,
        'ann@gmail.com');
    verifyNever(accounts.cloudDriveDatasourceForAccount(any));
  });

  test('a file the first account cannot see is tried with the second',
      () async {
    final annDatasource = MockCloudDriveDatasource();
    final bobDatasource = MockCloudDriveDatasource();
    when(accounts.cloudDriveCandidates(CloudDriveProvider.google))
        .thenReturn([gmail('ann'), gmail('bob')]);
    when(accounts.hasCloudDriveAccess(any)).thenAnswer((_) async => true);
    when(accounts.cloudDriveDatasourceForAccount('ann'))
        .thenReturn(annDatasource);
    when(accounts.cloudDriveDatasourceForAccount('bob'))
        .thenReturn(bobDatasource);
    when(annDatasource.fetchDocument(driveLink)).thenThrow(
        const ServerException(message: 'File not found', statusCode: 404));
    when(bobDatasource.fetchDocument(driveLink))
        .thenAnswer((_) async => document);

    final result = await repository.fetchDocument(driveLink);

    expect(result.toNullable(), document);
  });

  test('being offline stops the walk instead of exhausting every account',
      () async {
    final annDatasource = MockCloudDriveDatasource();
    final bobDatasource = MockCloudDriveDatasource();
    when(accounts.cloudDriveCandidates(CloudDriveProvider.google))
        .thenReturn([gmail('ann'), gmail('bob')]);
    when(accounts.hasCloudDriveAccess(any)).thenAnswer((_) async => true);
    when(accounts.cloudDriveDatasourceForAccount('ann'))
        .thenReturn(annDatasource);
    when(accounts.cloudDriveDatasourceForAccount('bob'))
        .thenReturn(bobDatasource);
    when(annDatasource.fetchDocument(driveLink))
        .thenThrow(const NetworkException(message: 'No route to host'));

    final result = await repository.fetchDocument(driveLink);

    // Reported as offline, not as "cannot preview this link" — and the second
    // account is never asked, because it would fail the same way.
    expect(result.getLeft().toNullable(), isA<NetworkFailure>());
    verifyNever(bobDatasource.fetchDocument(any));
  });

  test('a server error that is not about access is reported as it stands',
      () async {
    final annDatasource = MockCloudDriveDatasource();
    final bobDatasource = MockCloudDriveDatasource();
    when(accounts.cloudDriveCandidates(CloudDriveProvider.google))
        .thenReturn([gmail('ann'), gmail('bob')]);
    when(accounts.hasCloudDriveAccess(any)).thenAnswer((_) async => true);
    when(accounts.cloudDriveDatasourceForAccount('ann'))
        .thenReturn(annDatasource);
    when(accounts.cloudDriveDatasourceForAccount('bob'))
        .thenReturn(bobDatasource);
    when(annDatasource.fetchDocument(driveLink)).thenThrow(
        const ServerException(message: 'Internal error', statusCode: 500));

    final result = await repository.fetchDocument(driveLink);

    expect(result.getLeft().toNullable(), isA<ServerFailure>());
    verifyNever(bobDatasource.fetchDocument(any));
  });

  test('a document nothing can draw is not retried elsewhere', () async {
    final annDatasource = MockCloudDriveDatasource();
    final bobDatasource = MockCloudDriveDatasource();
    when(accounts.cloudDriveCandidates(CloudDriveProvider.google))
        .thenReturn([gmail('ann'), gmail('bob')]);
    when(accounts.hasCloudDriveAccess(any)).thenAnswer((_) async => true);
    when(accounts.cloudDriveDatasourceForAccount('ann'))
        .thenReturn(annDatasource);
    when(accounts.cloudDriveDatasourceForAccount('bob'))
        .thenReturn(bobDatasource);
    when(annDatasource.fetchDocument(driveLink)).thenThrow(
        const CloudDocumentNotPreviewableException(message: 'It is a zip'));

    final result = await repository.fetchDocument(driveLink);

    expect(result.getLeft().toNullable(), isA<CloudDriveUnavailable>());
    verifyNever(bobDatasource.fetchDocument(any));
  });

  test('every granted account refused, but one unasked, offers the unasked one',
      () async {
    final annDatasource = MockCloudDriveDatasource();
    when(accounts.cloudDriveCandidates(CloudDriveProvider.google))
        .thenReturn([gmail('ann'), gmail('bob')]);
    when(accounts.hasCloudDriveAccess('ann')).thenAnswer((_) async => true);
    when(accounts.hasCloudDriveAccess('bob')).thenAnswer((_) async => false);
    when(accounts.accountById('bob')).thenReturn(gmail('bob'));
    when(accounts.cloudDriveDatasourceForAccount('ann'))
        .thenReturn(annDatasource);
    when(annDatasource.fetchDocument(driveLink)).thenThrow(
        const ServerException(message: 'Forbidden', statusCode: 403));

    final result = await repository.fetchDocument(driveLink);

    final failure = result.getLeft().toNullable();
    expect(failure, isA<CloudDriveAccessNotGranted>());
    expect((failure as CloudDriveAccessNotGranted).accountId, 'bob');
  });
}
