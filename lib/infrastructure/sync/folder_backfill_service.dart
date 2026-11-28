import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/settings/app_settings.dart';
import '../../domain/entities/folder_listing.dart';
import '../../domain/repositories/email_repository.dart';
import '../accounts/account.dart';
import '../accounts/account_manager.dart';
import '../network/connectivity_service.dart';

/// Settings > General > "Keep opened folders offline": downloads every message
/// of each folder the cache keeps (the folders the user has opened, and the
/// Inbox), a page at a time in the background, so the list scrolls from the
/// cache to the folder's last message without waiting on the network — and
/// re-walks each folder from the top once a month to drop what was deleted or
/// moved elsewhere deep in it, which no listing near the top ever sees.
///
/// Every page goes through `EmailRepository.syncFolderPage`, so it is
/// reconciled against the outbox and replaces the stretch of the folder it
/// answers for, exactly like the list's own Load More (see
/// `lib/presentation/blocs/email_list/CLAUDE.md`, "A Folder's Cache Is
/// Replaced a Window at a Time"). Its position is persisted per folder
/// ([FolderWalk]), so a walk survives a restart.
///
/// One page at a time across every account, paced per provider so the walk
/// never competes with the poller for quota:
///
/// - **Gmail**: a page is `threads.list` (10 units) plus `threads.get` per
///   thread (40 units), 1,010 units for 25 threads. One every
///   [gmailInterval] is ~2,000 units a minute, a third of the 6,000/min
///   per-user quota (`docs/claude/gmail-quota.md`). A 5,000-thread folder is
///   200 pages, ~200,000 units over about an hour and forty minutes — the
///   first time, and again at each monthly re-check.
/// - **Microsoft Graph**: a page is 1 listing plus the expansion's 2 batched
///   conversation requests. Graph throttles at 10,000 requests per 10 minutes
///   per mailbox; one page every [graphInterval] is ~45 requests a minute. A
///   10,000-message folder is 400 pages, about 27 minutes.
/// - **IMAP** folders are never walked: an IMAP listing is in UID order, not
///   date order, so the cache keeps no coverage for them and they are not in
///   [EmailRepository.getCoveredFolderIds] (see `ListingWindow.dateOrdered`).
///   The pacing below is there only so the switch over account types stays
///   exhaustive.
class FolderBackfillService {
  FolderBackfillService({
    required this._repository,
    required this._accountManager,
    required this._settings,
    required this._connectivity,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final EmailRepository _repository;
  final AccountManager _accountManager;
  final AppSettings _settings;
  final ConnectivityService _connectivity;
  final DateTime Function() _clock;

  static const pageSize = 25;
  static const fullPassInterval = Duration(days: 30);
  static const gmailInterval = Duration(seconds: 30);
  static const graphInterval = Duration(seconds: 4);
  static const imapInterval = Duration(seconds: 2);

  /// How long to wait when there is nothing to do, or the network is down.
  static const idleInterval = Duration(minutes: 15);
  static const offlineInterval = Duration(minutes: 5);

  /// After a page fails — throttled, signed out, a server hiccup.
  static const failureInterval = Duration(minutes: 2);

  bool _enabled = false;
  bool _running = false;
  bool _disposed = false;
  Completer<void>? _wake;

  /// Reads the setting and, when it is on, starts walking. Main window only:
  /// a sub-window is its own engine with its own service locator, and two
  /// walkers would page the same folders twice.
  Future<void> start() async {
    _enabled = await _settings.loadKeepFoldersOffline();
    if (_enabled) _ensureLoop();
  }

  /// The setting changed. Turning it off stops the walk after the page in
  /// flight; what was downloaded stays cached.
  void setEnabled(bool enabled) {
    _enabled = enabled;
    if (enabled) {
      _ensureLoop();
    } else {
      _wakeUp();
    }
  }

  void dispose() {
    _disposed = true;
    _wakeUp();
  }

  void _ensureLoop() {
    if (_running || _disposed) return;
    _running = true;
    unawaited(_loop());
  }

  Future<void> _loop() async {
    try {
      while (_enabled && !_disposed) {
        Duration wait;
        try {
          wait = await runOnce();
        } catch (e) {
          debugPrint('[FolderBackfill] step failed: $e');
          wait = failureInterval;
        }
        if (!_enabled || _disposed) break;
        await _sleep(wait);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _sleep(Duration wait) {
    final wake = _wake = Completer<void>();
    final timer = Timer(wait, () {
      if (!wake.isCompleted) wake.complete();
    });
    return wake.future.whenComplete(timer.cancel);
  }

  void _wakeUp() {
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// Fetches one page for the first folder that has work, and returns how
  /// long to wait before the next. Public for tests.
  @visibleForTesting
  Future<Duration> runOnce() async {
    if (!await _connectivity.isOnline) return offlineInterval;
    for (final account in List.of(_accountManager.accounts)) {
      final folders = (await _repository.getCoveredFolderIds(account.id))
          .getOrElse((_) => const []);
      for (final folderId in folders) {
        if (folderId == _defaultFolderKey) continue;
        final walk = await _walkFor(account.id, folderId);
        if (walk == null) continue;
        return await _step(account, folderId, walk);
      }
    }
    return idleInterval;
  }

  static const _defaultFolderKey = '__DEFAULT__';

  /// The walk [folderId] has under way, or the one it is due: a backfill of
  /// the stretch below its coverage, or the monthly re-check from the top.
  /// Null when the folder is cached end to end and checked recently.
  Future<FolderWalk?> _walkFor(String accountId, String folderId) async {
    final existing = (await _repository.getFolderWalk(
            accountId: accountId, folderId: folderId))
        .getOrElse((_) => null);
    if (existing != null) return existing;

    final coverage = (await _repository.getFolderCoverage(
            accountId: accountId, folderId: folderId))
        .getOrElse((_) => const FolderCoverage());
    final now = _clock();
    if (!coverage.complete && coverage.coveredFrom != null) {
      // The cache vouches for everything down to coveredFrom: walk on from
      // there. The cutoff is the edge itself, inclusive, so nothing at it is
      // skipped.
      final edge = coverage.coveredFrom!;
      return FolderWalk(before: edge, offset: 0, windowEnd: edge, full: false);
    }
    final lastPass = coverage.lastFullPassAt;
    if (coverage.complete &&
        lastPass != null &&
        now.difference(lastPass) < fullPassInterval) {
      return null;
    }
    // The re-check (or a folder that has never been walked and vouches for
    // nothing): everything from now down, a window at a time, replacing
    // each stretch's cached rows with what the server lists for it. Mail that
    // arrives meanwhile lands above the cutoff, where the poller has it.
    return FolderWalk(before: now, offset: 0, windowEnd: now, full: true);
  }

  Future<Duration> _step(Account account, String folderId, FolderWalk walk) async {
    final result = await _repository.syncFolderPage(
      accountId: account.id,
      folderId: folderId,
      top: pageSize,
      skip: walk.offset,
      olderThan: walk.before,
      windowEnd: walk.windowEnd,
    );
    return result.fold(
      (failure) {
        debugPrint('[FolderBackfill] ${account.id}/$folderId page at '
            '${walk.offset} failed: ${failure.message}');
        return failureInterval;
      },
      (page) async {
        if (page.reachedEnd) {
          debugPrint('[FolderBackfill] ${account.id}/$folderId: '
              '${walk.full ? 'monthly re-check' : 'backfill'} done after '
              '${walk.offset ~/ pageSize + 1} pages');
          await _repository.saveFolderWalk(
            accountId: account.id,
            folderId: folderId,
            finishedFullPass: _clock(),
          );
        } else {
          await _repository.saveFolderWalk(
            accountId: account.id,
            folderId: folderId,
            walk: FolderWalk(
              before: walk.before,
              offset: walk.offset + pageSize,
              windowEnd: page.windowStart!,
              full: walk.full,
            ),
          );
        }
        return intervalFor(account);
      },
    );
  }

  /// The pause after a page of [account]'s — see the class comment.
  static Duration intervalFor(Account account) => switch (account) {
        GmailAccount() => gmailInterval,
        MicrosoftAccount() => graphInterval,
        ImapAccount() => imapInterval,
      };
}
