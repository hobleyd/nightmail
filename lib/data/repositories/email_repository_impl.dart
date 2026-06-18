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
import '../datasources/local/folder_local_datasource.dart';

class EmailRepositoryImpl implements EmailRepository {
  const EmailRepositoryImpl({
    required this._accountManager,
    required this._localDatasource,
    required this._folderLocalDatasource,
  });

  final AccountManager _accountManager;
  final EmailLocalDatasource _localDatasource;
  final FolderLocalDatasource _folderLocalDatasource;

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
        final effectiveFolderId = folderId ?? _defaultFolderKey;
        unawaited(() async {
          if (skip == 0) {
            await _localDatasource.clearCacheForFolder(
              accountId: accountId,
              folderId: effectiveFolderId,
            );
          }
          await _localDatasource.cacheEmails(
            accountId: accountId,
            folderId: effectiveFolderId,
            emails: emails,
          );
        }());
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
    final result = await _execute(() => _accountManager.emailDatasource
        .updateEmailReadStatus(id: id, isRead: isRead));
    result.fold((_) {}, (_) {
      final accountId = _accountManager.activeAccount?.id;
      if (accountId != null) {
        unawaited(_localDatasource.updateEmailReadStatusInCache(
          accountId: accountId,
          emailId: id,
          isRead: isRead,
        ));
      }
    });
    return result;
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

      final accountId = _accountManager.activeAccount?.id;
      if (accountId != null) {
        unawaited(() async {
          await _folderLocalDatasource.clearFoldersForAccount(accountId);
          await _folderLocalDatasource.cacheFolders(
            accountId: accountId,
            folders: all,
          );
        }());
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
  Future<Either<Failure, List<EmailFolder>>> getCachedFolders(
      String accountId) async {
    try {
      final folders =
          await _folderLocalDatasource.getCachedFolders(accountId);
      return Right(folders);
    } on CacheException catch (e) {
      return Left(CacheFailure(message: e.message));
    } catch (e) {
      return Left(CacheFailure(message: e.toString()));
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
    List<String> excludedAttachmentIds = const [],
  }) async {
    return _execute(() async {
      await _accountManager.emailDatasource.forwardEmail(
        messageId: messageId,
        toAddresses: toAddresses,
        comment: comment,
        excludedAttachmentIds: excludedAttachmentIds,
      );
      return unit;
    });
  }

  @override
  Future<Either<Failure, Unit>> moveEmail(
      String id, String destinationFolderId) async {
    return _execute(() async {
      await _accountManager.emailDatasource
          .moveEmail(id, destinationFolderId);
      final accountId = _accountManager.activeAccount?.id;
      if (accountId != null) {
        unawaited(_localDatasource.deleteEmailFromCache(
          accountId: accountId,
          emailId: id,
        ));
      }
      return unit;
    });
  }

  @override
  Future<Either<Failure, Unit>> reportJunk(String id) async {
    return _execute(() async {
      await _accountManager.emailDatasource.reportJunk(id);
      final accountId = _accountManager.activeAccount?.id;
      if (accountId != null) {
        unawaited(_localDatasource.deleteEmailFromCache(
          accountId: accountId,
          emailId: id,
        ));
      }
      return unit;
    });
  }

  @override
  Future<Either<Failure, Unit>> deleteEmail(String id) async {
    return _execute(() async {
      await _accountManager.emailDatasource.deleteEmail(id);
      final accountId = _accountManager.activeAccount?.id;
      if (accountId != null) {
        unawaited(_localDatasource.deleteEmailFromCache(
          accountId: accountId,
          emailId: id,
        ));
      }
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

  @override
  Future<Either<Failure, Uint8List>> getRawEmailBytes(String id) async {
    return _execute(() => _accountManager.emailDatasource.getRawEmailBytes(id));
  }

  @override
  Future<Either<Failure, Unit>> createFolder({
    required String parentFolderId,
    required String displayName,
  }) async {
    return _execute(() async {
      await _accountManager.emailDatasource.createFolder(
        parentFolderId: parentFolderId,
        displayName: displayName,
      );
      return unit;
    });
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
