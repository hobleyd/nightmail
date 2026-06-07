import 'dart:async';
import 'dart:typed_data';

import 'package:fpdart/fpdart.dart';

import '../../core/error/exceptions.dart';
import '../../core/error/failures.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_folder.dart';
import '../../domain/repositories/email_repository.dart';
import '../../infrastructure/accounts/account_manager.dart';
import '../datasources/local/email_local_datasource.dart';

class EmailRepositoryImpl implements EmailRepository {
  const EmailRepositoryImpl({
    required this._accountManager,
    required this._localDatasource,
  });

  final AccountManager _accountManager;
  final EmailLocalDatasource _localDatasource;

  static const _defaultFolderKey = '__DEFAULT__';

  @override
  Future<Either<Failure, List<Email>>> getEmails({
    String? folderId,
    int top = 25,
    int skip = 0,
    String? filter,
    String orderBy = 'receivedDateTime desc',
  }) async {
    final result = await _execute(() => _accountManager.emailDatasource.getEmails(
          folderId: folderId,
          top: top,
          skip: skip,
          filter: filter,
          orderBy: orderBy,
        ));

    result.fold((_) {}, (emails) {
      final accountId = _accountManager.activeAccount?.id;
      if (accountId != null && emails.isNotEmpty) {
        unawaited(_localDatasource.cacheEmails(
          accountId: accountId,
          folderId: folderId ?? _defaultFolderKey,
          emails: emails,
        ));
      }
    });

    return result;
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
  Future<Either<Failure, Unit>> emptyFolder(
    String folderId, {
    bool permanentDelete = false,
  }) async {
    return _execute(() async {
      await _accountManager.emailDatasource
          .emptyFolder(folderId, permanentDelete: permanentDelete);
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

  @override
  Future<Either<Failure, List<Email>>> getCachedEmails({
    required String accountId,
    required String folderId,
  }) async {
    try {
      final emails = await _localDatasource.getCachedEmails(
        accountId: accountId,
        folderId: folderId,
      );
      return Right(emails);
    } on CacheException catch (e) {
      return Left(CacheFailure(message: e.message));
    } catch (e) {
      return Left(CacheFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, Unit>> cacheEmails({
    required String accountId,
    required String folderId,
    required List<Email> emails,
  }) async {
    try {
      await _localDatasource.cacheEmails(
        accountId: accountId,
        folderId: folderId,
        emails: emails,
      );
      return const Right(unit);
    } on CacheException catch (e) {
      return Left(CacheFailure(message: e.message));
    } catch (e) {
      return Left(CacheFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, Unit>> clearCacheForAccount(String accountId) async {
    try {
      await _localDatasource.clearCacheForAccount(accountId);
      return const Right(unit);
    } on CacheException catch (e) {
      return Left(CacheFailure(message: e.message));
    } catch (e) {
      return Left(CacheFailure(message: e.toString()));
    }
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
