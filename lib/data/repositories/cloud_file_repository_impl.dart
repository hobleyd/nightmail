import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fpdart/fpdart.dart';

import '../../core/error/exceptions.dart';
import '../../core/error/failures.dart';
import '../../domain/entities/cloud_document.dart';
import '../../domain/entities/cloud_file.dart';
import '../../domain/repositories/cloud_file_repository.dart';
import '../../infrastructure/accounts/account_manager.dart';
import '../datasources/remote/cloud_drive_datasource.dart';

class CloudFileRepositoryImpl implements CloudFileRepository {
  const CloudFileRepositoryImpl({required this._accountManager});

  final AccountManager _accountManager;

  @override
  Future<Either<Failure, List<CloudFile>>> listFiles(
    String accountId, {
    CloudFile? folder,
    CloudFileCollection collection = CloudFileCollection.myFiles,
  }) =>
      _run(accountId, 'list',
          (ds) => ds.listFiles(folder: folder, collection: collection));

  @override
  Future<Either<Failure, List<CloudFile>>> searchFiles(
          String accountId, String query) =>
      _run(accountId, 'search', (ds) => ds.searchFiles(query));

  @override
  Future<Either<Failure, CloudDocument>> downloadFile(CloudFile file) =>
      _run(file.accountId, 'download', (ds) => ds.downloadFile(file));

  @override
  Future<Either<Failure, CloudFileAccess>> checkAccess(
      CloudFile file, List<String> recipients) {
    final own = _accountManager.accountById(file.accountId)?.allAddresses ??
        const <String>{};
    final others = [
      for (final r in recipients)
        if (!own.contains(r.trim().toLowerCase())) r,
    ];
    if (others.isEmpty) {
      return Future.value(const Right(CloudFileAccess.everyone));
    }
    return _run(
      file.accountId,
      'access',
      (ds) => ds.checkAccess(file, others,
          organizationDomains:
              _accountManager.organizationDomainsFor(file.accountId)),
    );
  }

  @override
  Future<Either<Failure, CloudShareResult>> shareFile(
          CloudFile file, List<String> recipients) =>
      _run(file.accountId, 'share', (ds) => ds.shareFile(file, recipients));

  Future<Either<Failure, T>> _run<T>(
    String accountId,
    String what,
    Future<T> Function(CloudDriveDatasource ds) body,
  ) async {
    final datasource = _accountManager.cloudDriveDatasourceForAccount(accountId);
    if (datasource == null) {
      return const Left(
          CloudDriveUnavailable(message: 'This account has no cloud files'));
    }
    try {
      return Right(await body(datasource));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on CloudDocumentNotPreviewableException catch (e) {
      return Left(CloudDriveUnavailable(message: e.message));
    } on ServerException catch (e) {
      debugPrint('[CloudFiles] $what for $accountId: HTTP ${e.statusCode}: '
          '${e.message}');
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    }
  }
}
