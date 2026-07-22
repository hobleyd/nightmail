import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fpdart/fpdart.dart';

import '../../core/error/exceptions.dart';
import '../../core/error/failures.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_folder.dart';
import '../../domain/entities/local_attachment.dart';
import '../../domain/repositories/email_repository.dart';
import '../../infrastructure/accounts/account.dart';
import '../../infrastructure/accounts/account_manager.dart';
import '../../infrastructure/network/connectivity_service.dart';
import '../../infrastructure/sync/outbox_drain_service.dart';
import '../../infrastructure/sync/removal_tombstone_store.dart';
import '../datasources/local/email_local_datasource.dart';
import '../datasources/local/folder_local_datasource.dart';
import '../datasources/local/pending_operations_datasource.dart';
import '../datasources/remote/email_remote_datasource.dart';

class EmailRepositoryImpl implements EmailRepository {
  EmailRepositoryImpl({
    required this._accountManager,
    required this._localDatasource,
    required this._folderLocalDatasource,
    required this._pendingOperations,
    required this._outboxDrainService,
    required this._connectivityService,
    required this._removalTombstones,
  });

  final AccountManager _accountManager;
  final EmailLocalDatasource _localDatasource;
  final FolderLocalDatasource _folderLocalDatasource;
  final PendingOperationsDatasource _pendingOperations;
  final OutboxDrainService _outboxDrainService;
  final ConnectivityService _connectivityService;
  final RemovalTombstoneStore _removalTombstones;

  static const _defaultFolderKey = '__DEFAULT__';

  void _tombstoneRemoval(String accountId, String emailId) {
    _removalTombstones.record(accountId, emailId);
  }

  /// Returns the datasource to send through for [accountId]. Falls back to
  /// the active account's datasource when [accountId] is null, matches the
  /// active account, or doesn't resolve to a configured account.
  EmailRemoteDatasource _datasourceFor(String? accountId) {
    if (accountId == null || accountId == _accountManager.activeAccount?.id) {
      return _accountManager.emailDatasource;
    }
    final account = _accountManager.accounts
        .cast<Account?>()
        .firstWhere((a) => a?.id == accountId, orElse: () => null);
    return account == null
        ? _accountManager.emailDatasource
        : _accountManager.buildEmailDatasourceForAccount(account);
  }

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

    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null) return result;

    return result.fold(
      (failure) async => Left<Failure, List<Email>>(failure),
      (emails) async {
        // Reconcile against still-queued outbox mutations before caching *or*
        // returning: a server snapshot taken before the outbox drain committed
        // the delete/move/junk would otherwise resurrect the just-removed
        // message into the cache, and the next poll's cache repaint would
        // put it back on screen. Mirrors MailPollerCubit's reconciliation.
        final reconciled = await _reconcileAgainstPendingOps(accountId, emails);
        if (reconciled.isNotEmpty) {
          final effectiveFolderId = folderId ?? _defaultFolderKey;
          unawaited(_localDatasource.cacheEmails(
            accountId: accountId,
            folderId: effectiveFolderId,
            emails: reconciled,
          ));
        }
        return Right<Failure, List<Email>>(reconciled);
      },
    );
  }

  /// Drops server results that still carry a pending delete/move/junk op, and
  /// preserves the cached read-state for a message with a pending markRead —
  /// the same reconciliation [MailPollerCubit] applies to its sync results.
  ///
  /// The outbox drain fires asynchronously after an optimistic mutation, so a
  /// [getEmails] fetch can overlap that window and return a stale snapshot
  /// still listing the deleted/moved message. Writing that snapshot to the
  /// cache un-reconciled is what makes a just-deleted email reappear until the
  /// drain finishes.
  Future<List<Email>> _reconcileAgainstPendingOps(
    String accountId,
    List<Email> emails,
  ) async {
    final pendingOps = await _pendingOperations.getPendingOperations(accountId);

    // Recently-removed tombstones survive a short window past op dequeue,
    // closing the race where a server snapshot built before the mutation
    // propagated resolves after the outbox drain removed the pending op.
    final recentlyRemovedIds = _removalTombstones.activeIds(accountId);

    final tombstoned = <String>{
      for (final op in pendingOps)
        if (op.opType == PendingOperationType.delete ||
            op.opType == PendingOperationType.move ||
            op.opType == PendingOperationType.junk)
          op.emailId,
      ...recentlyRemovedIds,
    };
    final pendingReadIds = <String>{
      for (final op in pendingOps)
        if (op.opType == PendingOperationType.markRead) op.emailId,
    };
    if (tombstoned.isEmpty && pendingReadIds.isEmpty) return emails;

    final reconciled = <Email>[];
    for (final email in emails) {
      if (tombstoned.contains(email.id)) continue;
      if (pendingReadIds.contains(email.id)) {
        final cached = await _localDatasource.getCachedEmailById(
          accountId: accountId,
          emailId: email.id,
        );
        if (cached != null && cached.isRead != email.isRead) {
          reconciled.add(email.copyWith(isRead: cached.isRead));
          continue;
        }
      }
      reconciled.add(email);
    }
    return reconciled;
  }

  @override
  Future<Either<Failure, Email>> getEmail(String id) async {
    final accountId = _accountManager.activeAccount?.id;
    if (accountId != null) {
      final cached = await _localDatasource.getCachedEmailById(
        accountId: accountId,
        emailId: id,
      );
      // List/delta fetches only request a preview select (bodyPreview, no
      // attachment payloads) to keep folder loads and polling cheap, so a
      // row cached from one of those has an empty body — not a real message
      // with a blank body (vanishingly rare in practice). Only trust the
      // cache for rows a prior single-message fetch actually filled in;
      // otherwise fall through to network below, which will also upgrade
      // the cached row to a full copy.
      //
      // Also refetch when the cached body references inline images via cid:
      // but carries no inline attachments — either an older cache written
      // before inline attachments were persisted, or a row whose inline parts
      // were misclassified. The network fetch resolves and re-caches them.
      if (cached != null &&
          cached.body.isNotEmpty &&
          !_needsInlineRefetch(cached)) {
        return Right(cached);
      }
    }

    final result =
        await _execute(() => _accountManager.emailDatasource.getEmail(id));
    if (accountId == null) return result;

    return result.fold(
      (failure) async => Left<Failure, Email>(failure),
      (email) async {
        // Same reconciliation as getEmails: don't let a fetch that overlaps
        // the outbox drain window write a just-deleted/moved message back into
        // the cache. Still return the fetched copy to the caller that
        // explicitly requested this id — we just skip the cache write when the
        // message is tombstoned by a pending delete/move/junk op.
        final reconciled = await _reconcileAgainstPendingOps(accountId, [email]);
        if (reconciled.isEmpty) return Right<Failure, Email>(email);
        final effectiveEmail = reconciled.first;
        final effectiveFolderId =
            effectiveEmail.parentFolderId ?? _defaultFolderKey;
        unawaited(_localDatasource.cacheEmails(
          accountId: accountId,
          folderId: effectiveFolderId,
          emails: [effectiveEmail],
        ));
        return Right<Failure, Email>(effectiveEmail);
      },
    );
  }

  /// A cached full message still needs a network refetch when its body
  /// references inline images (`cid:`) but no inline attachment bytes are
  /// cached to satisfy them.
  bool _needsInlineRefetch(Email email) =>
      email.inlineAttachments.isEmpty && email.body.contains('cid:');

  @override
  Future<Either<Failure, Email>> markAsRead({
    required String id,
    required bool isRead,
  }) async {
    final accountId = _accountManager.activeAccount?.id;
    final cached = accountId == null
        ? null
        : await _localDatasource.getCachedEmailById(
            accountId: accountId, emailId: id);
    // No cached copy to update in place (e.g. acting on a search result that
    // was never cached) — fall back to the old network-first path rather
    // than fabricate a return value.
    if (accountId == null || cached == null) {
      return _execute(() => _accountManager.emailDatasource
          .updateEmailReadStatus(id: id, isRead: isRead));
    }

    return _executeLocal(() async {
      // Enqueue before mutating the cache: if the app dies in between, a
      // queued op with no local change just replays against server state
      // that already reflects it (server wins, harmless) — the reverse
      // (a cache change with nothing queued to replay) would silently lose
      // the mutation forever.
      await _pendingOperations.enqueue(
        accountId: accountId,
        emailId: id,
        opType: PendingOperationType.markRead,
        payload: jsonEncode({'isRead': isRead}),
      );
      final updated = cached.copyWith(isRead: isRead);
      await _localDatasource.updateEmailReadStatusInCache(
        accountId: accountId,
        emailId: id,
        isRead: isRead,
      );
      unawaited(_outboxDrainService.drainForAccount(accountId));
      return updated;
    });
  }

  @override
  Future<Either<Failure, List<EmailFolder>>> getMailFolders() async {
    if (!await _connectivityService.isOnline) {
      return const Left(NetworkFailure(message: 'No network connection'));
    }
    try {
      final remote = _accountManager.emailDatasource;
      // SPAMDB is an app-managed folder holding the synced spam filter
      // database (see SpamDbSyncDatasource) — it must never appear as a
      // browsable folder (folder tree, move-to dialogs, etc.).
      final topLevel = (await remote.getMailFolders())
          .where((f) => f.displayName.toLowerCase() != 'spamdb')
          .toList();
      final all = <EmailFolder>[...topLevel];

      List<EmailFolder> toExpand =
          topLevel.where((f) => f.childFolderCount > 0).toList();
      while (toExpand.isNotEmpty) {
        final nextLevel = <EmailFolder>[];
        final childResults = await Future.wait(
          toExpand.map((f) => remote.getChildFolders(f.id)),
        );
        for (final rawChildren in childResults) {
          // SPAMDB can land here instead of topLevel on abbreviated-
          // namespace servers, where it's created as e.g. INBOX.SPAMDB —
          // a child of INBOX rather than a root-level folder.
          final children = rawChildren
              .where((f) => f.displayName.toLowerCase() != 'spamdb')
              .toList();
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
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
    String? accountId,
  }) async {
    return _execute(() async {
      await _datasourceFor(accountId).sendEmail(
        toAddresses: toAddresses,
        ccAddresses: ccAddresses,
        subject: subject,
        body: body,
        bodyType: bodyType,
        newAttachments: newAttachments,
      );
      return unit;
    });
  }

  @override
  Future<Either<Failure, Unit>> replyToEmail({
    required String messageId,
    required String comment,
    bool replyAll = false,
    List<String> toAddresses = const [],
    List<String> ccAddresses = const [],
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
    String? accountId,
  }) async {
    return _execute(() async {
      await _datasourceFor(accountId).replyToEmail(
        messageId: messageId,
        comment: comment,
        replyAll: replyAll,
        toAddresses: toAddresses,
        ccAddresses: ccAddresses,
        bodyType: bodyType,
        newAttachments: newAttachments,
      );
      return unit;
    });
  }

  @override
  Future<Either<Failure, Unit>> forwardEmail({
    required String messageId,
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String comment,
    List<String> excludedAttachmentIds = const [],
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
    String? accountId,
  }) async {
    return _execute(() async {
      await _datasourceFor(accountId).forwardEmail(
        messageId: messageId,
        toAddresses: toAddresses,
        ccAddresses: ccAddresses,
        comment: comment,
        excludedAttachmentIds: excludedAttachmentIds,
        bodyType: bodyType,
        newAttachments: newAttachments,
      );
      return unit;
    });
  }

  @override
  Future<Either<Failure, Unit>> moveEmail(
      String id, String destinationFolderId) async {
    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null) {
      return _execute(() async {
        await _accountManager.emailDatasource.moveEmail(id, destinationFolderId);
        return unit;
      });
    }
    return _executeLocal(() async {
      await _pendingOperations.enqueue(
        accountId: accountId,
        emailId: id,
        opType: PendingOperationType.move,
        payload: jsonEncode({'destinationFolderId': destinationFolderId}),
      );
      _tombstoneRemoval(accountId, id);
      // The message leaves the folder currently being viewed; the drain
      // engine re-files it into the destination folder's cache once the
      // server confirms (and learns its possibly-new id in the process).
      await _localDatasource.deleteEmailFromCache(
        accountId: accountId,
        emailId: id,
      );
      unawaited(_outboxDrainService.drainForAccount(accountId));
      return unit;
    });
  }

  @override
  Future<Either<Failure, Unit>> reportJunk(String id) async {
    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null) {
      return _execute(() async {
        await _accountManager.emailDatasource.reportJunk(id);
        return unit;
      });
    }
    return _executeLocal(() async {
      await _pendingOperations.enqueue(
        accountId: accountId,
        emailId: id,
        opType: PendingOperationType.junk,
        payload: '{}',
      );
      _tombstoneRemoval(accountId, id);
      await _localDatasource.deleteEmailFromCache(
        accountId: accountId,
        emailId: id,
      );
      unawaited(_outboxDrainService.drainForAccount(accountId));
      return unit;
    });
  }

  @override
  Future<Either<Failure, Unit>> deleteEmail(String id) async {
    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null) {
      return _execute(() async {
        await _accountManager.emailDatasource.deleteEmail(id);
        return unit;
      });
    }
    return _executeLocal(() async {
      await _pendingOperations.enqueue(
        accountId: accountId,
        emailId: id,
        opType: PendingOperationType.delete,
        payload: '{}',
      );
      _tombstoneRemoval(accountId, id);
      await _localDatasource.deleteEmailFromCache(
        accountId: accountId,
        emailId: id,
      );
      unawaited(_outboxDrainService.drainForAccount(accountId));
      return unit;
    });
  }

  @override
  // Deliberately NOT outbox-first, unlike the other mutations above.
  // Emptying a folder can touch hundreds of messages server-side and has no
  // partial-progress visibility; going optimistic here would make the
  // "Delete All" shimmer always report success immediately and silently
  // strand a failed drain with no way for the UI to notice or recover — the
  // exact class of bug commit 7d29563 fixed on the network-first path
  // (re-fetch and restore on failure). Revisit once the outbox has failure
  // surfacing (see the delta-reconciliation/tombstone work), not before.
  Future<Either<Failure, Unit>> emptyFolder(
    String folderId, {
    bool permanentDelete = false,
  }) async {
    final result = await _execute(() async {
      await _accountManager.emailDatasource
          .emptyFolder(folderId, permanentDelete: permanentDelete);
      return unit;
    });
    result.fold((_) {}, (_) {
      final accountId = _accountManager.activeAccount?.id;
      if (accountId != null) {
        unawaited(_localDatasource.clearCacheForFolder(
          accountId: accountId,
          folderId: folderId,
        ));
      }
    });
    return result;
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
  Future<Either<Failure, Unit>> clearCacheForFolder({
    required String accountId,
    required String folderId,
  }) async {
    try {
      await _localDatasource.clearCacheForFolder(
        accountId: accountId,
        folderId: folderId,
      );
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

  @override
  Future<Either<Failure, Unit>> renameFolder({
    required String folderId,
    required String newDisplayName,
  }) async {
    return _execute(() async {
      await _accountManager.emailDatasource.renameFolder(
        folderId: folderId,
        newDisplayName: newDisplayName,
      );
      return unit;
    });
  }

  @override
  Future<Either<Failure, Unit>> moveFolder({
    required String folderId,
    required String newParentFolderId,
  }) async {
    return _execute(() async {
      await _accountManager.emailDatasource.moveFolder(
        folderId: folderId,
        newParentFolderId: newParentFolderId,
      );
      return unit;
    });
  }

  @override
  Future<Either<Failure, List<Email>>> searchEmails({
    String? folderId,
    required String query,
    int top = 50,
  }) {
    return _execute(() => _accountManager.emailDatasource.searchEmails(
          folderId: folderId,
          query: query,
          top: top,
        ));
  }

  @override
  Future<Either<Failure, String>> createServerDraft({
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) {
    return _execute(() => _accountManager.emailDatasource.createServerDraft(
          toAddresses: toAddresses,
          ccAddresses: ccAddresses,
          subject: subject,
          body: body,
          bodyType: bodyType,
          newAttachments: newAttachments,
        ));
  }

  @override
  Future<Either<Failure, String>> updateServerDraft({
    required String draftId,
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) {
    return _execute(() => _accountManager.emailDatasource.updateServerDraft(
          draftId: draftId,
          toAddresses: toAddresses,
          ccAddresses: ccAddresses,
          subject: subject,
          body: body,
          bodyType: bodyType,
          newAttachments: newAttachments,
        ));
  }

  @override
  Future<Either<Failure, Unit>> deleteServerDraft({required String draftId}) {
    return _execute(() async {
      await _accountManager.emailDatasource.deleteServerDraft(draftId: draftId);
      return unit;
    });
  }

  /// Wraps a call that actually reaches the network. Fails fast instead of
  /// waiting on an HTTP client's connect timeout (tens of seconds) before
  /// the caller can fall back to the cache.
  Future<Either<Failure, T>> _execute<T>(Future<T> Function() fn) async {
    if (!await _connectivityService.isOnline) {
      return const Left(NetworkFailure(message: 'No network connection'));
    }
    return _executeLocal(fn);
  }

  /// Same exception-to-Failure mapping as [_execute], but for bodies that
  /// only touch the outbox/cache (no network call) — an offline gate here
  /// would wrongly block the very thing that's supposed to work offline.
  Future<Either<Failure, T>> _executeLocal<T>(Future<T> Function() fn) async {
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
