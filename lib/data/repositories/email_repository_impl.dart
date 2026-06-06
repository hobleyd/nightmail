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
    try {
      final topLevel = await _remote.getMailFolders();
      final all = <EmailFolder>[...topLevel];

      List<EmailFolder> toExpand =
          topLevel.where((f) => f.childFolderCount > 0).toList();
      while (toExpand.isNotEmpty) {
        final nextLevel = <EmailFolder>[];
        final childResults = await Future.wait(
          toExpand.map((f) => _remote.getChildFolders(f.id)),
        );
        for (final children in childResults) {
          all.addAll(children);
          nextLevel.addAll(children.where((f) => f.childFolderCount > 0));
        }
        toExpand = nextLevel;
      }

      return Right(all);
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
