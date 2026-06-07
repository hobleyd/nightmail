import 'dart:typed_data';

import 'package:fpdart/fpdart.dart';

import '../../core/error/exceptions.dart';
import '../../core/error/failures.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_folder.dart';
import '../../domain/repositories/email_repository.dart';
import '../../infrastructure/accounts/account_manager.dart';

class EmailRepositoryImpl implements EmailRepository {
  const EmailRepositoryImpl({required AccountManager accountManager})
      : _accountManager = accountManager;

  final AccountManager _accountManager;

  @override
  Future<Either<Failure, List<Email>>> getEmails({
    String? folderId,
    int top = 25,
    int skip = 0,
    String? filter,
    String orderBy = 'receivedDateTime desc',
  }) async {
    return _execute(() => _accountManager.emailDatasource.getEmails(
          folderId: folderId,
          top: top,
          skip: skip,
          filter: filter,
          orderBy: orderBy,
        ));
  }

  @override
  Future<Either<Failure, Email>> getEmail(String id) async {
    return _execute(() => _accountManager.emailDatasource.getEmail(id));
  }

  @override
  Future<Either<Failure, Email>> markAsRead({
    required String id,
    required bool isRead,
  }) async {
    return _execute(() => _accountManager.emailDatasource
        .updateEmailReadStatus(id: id, isRead: isRead));
  }

  @override
  Future<Either<Failure, List<EmailFolder>>> getMailFolders() async {
    try {
      final remote = _accountManager.emailDatasource;
      final topLevel = await remote.getMailFolders();
      final all = <EmailFolder>[...topLevel];

      List<EmailFolder> toExpand =
          topLevel.where((f) => f.childFolderCount > 0).toList();
      while (toExpand.isNotEmpty) {
        final nextLevel = <EmailFolder>[];
        final childResults = await Future.wait(
          toExpand.map((f) => remote.getChildFolders(f.id)),
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
    return _execute(
        () => _accountManager.emailDatasource.getChildFolders(parentFolderId));
  }

  @override
  Future<Either<Failure, Unit>> sendEmail({
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
  }) async {
    return _execute(() async {
      await _accountManager.emailDatasource.sendEmail(
        toAddresses: toAddresses,
        ccAddresses: ccAddresses,
        subject: subject,
        body: body,
      );
      return unit;
    });
  }

  @override
  Future<Either<Failure, Unit>> replyToEmail({
    required String messageId,
    required String comment,
    bool replyAll = false,
  }) async {
    return _execute(() async {
      await _accountManager.emailDatasource.replyToEmail(
        messageId: messageId,
        comment: comment,
        replyAll: replyAll,
      );
      return unit;
    });
  }

  @override
  Future<Either<Failure, Unit>> forwardEmail({
    required String messageId,
    required List<String> toAddresses,
    required String comment,
  }) async {
    return _execute(() async {
      await _accountManager.emailDatasource.forwardEmail(
        messageId: messageId,
        toAddresses: toAddresses,
        comment: comment,
      );
      return unit;
    });
  }

  @override
  Future<Either<Failure, Unit>> deleteEmail(String id) async {
    return _execute(() async {
      await _accountManager.emailDatasource.deleteEmail(id);
      return unit;
    });
  }

  @override
  Future<Either<Failure, Uint8List>> downloadAttachment({
    required String messageId,
    required String attachmentId,
  }) async {
    return _execute(() => _accountManager.emailDatasource
        .downloadAttachment(messageId, attachmentId));
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
    } on StateError catch (e) {
      return Left(AuthFailure(message: e.message));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }
}
