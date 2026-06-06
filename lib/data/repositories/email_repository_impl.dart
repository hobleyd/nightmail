import 'package:fpdart/fpdart.dart';

import '../../core/error/exceptions.dart';
import '../../core/error/failures.dart';
import '../../data/datasources/remote/graph_api_remote_datasource.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_folder.dart';
import '../../domain/repositories/email_repository.dart';

class EmailRepositoryImpl implements EmailRepository {
  const EmailRepositoryImpl({
    required GraphApiRemoteDatasource remoteDatasource,
  }) : _remote = remoteDatasource;

  final GraphApiRemoteDatasource _remote;

  @override
  Future<Either<Failure, List<Email>>> getEmails({
    String? folderId,
    int top = 25,
    int skip = 0,
    String? filter,
    String orderBy = 'receivedDateTime desc',
  }) async {
    return _execute(() => _remote.getEmails(
          folderId: folderId,
          top: top,
          skip: skip,
          filter: filter,
          orderBy: orderBy,
        ));
  }

  @override
  Future<Either<Failure, Email>> getEmail(String id) async {
    return _execute(() => _remote.getEmail(id));
  }

  @override
  Future<Either<Failure, Email>> markAsRead({
    required String id,
    required bool isRead,
  }) async {
    return _execute(
        () => _remote.updateEmailReadStatus(id: id, isRead: isRead));
  }

  @override
  Future<Either<Failure, List<EmailFolder>>> getMailFolders() async {
    return _execute(() => _remote.getMailFolders());
  }

  @override
  Future<Either<Failure, List<EmailFolder>>> getChildFolders(
      String parentFolderId) async {
    return _execute(() => _remote.getChildFolders(parentFolderId));
  }

  Future<Either<Failure, T>> _execute<T>(Future<T> Function() fn) async {
    try {
      return Right(await fn());
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } on CacheException catch (e) {
      return Left(CacheFailure(message: e.message));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }
}
