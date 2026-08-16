import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/exceptions.dart';
import '../../../core/platform/window_utils.dart';
import '../../../core/settings/app_settings.dart';
import '../../../data/datasources/local/delta_token_datasource.dart';
import '../../../data/datasources/local/email_local_datasource.dart';
import '../../../data/datasources/local/folder_local_datasource.dart';
import '../../../data/datasources/local/pending_operations_datasource.dart';
import '../../../data/datasources/remote/email_remote_datasource.dart';
import '../../../data/datasources/remote/imap_datasource_impl.dart';
import '../../../data/datasources/remote/mail_delta_datasource.dart';
import '../../../data/datasources/remote/spam_db_sync_datasource.dart';
import '../../../data/models/mail_delta_result.dart';
import '../../../domain/entities/email.dart';
import '../../../domain/entities/email_folder.dart';
import '../../../domain/usecases/get_cached_folders.dart';
import '../../../infrastructure/accounts/account.dart';
import '../../../infrastructure/accounts/account_manager.dart';
import '../../../infrastructure/badge/badge_service.dart';
import '../../../infrastructure/network/connectivity_service.dart';
import '../../../infrastructure/notifications/notification_service.dart';
import '../../../infrastructure/sync/body_prefetch_service.dart';
import '../../../infrastructure/sync/imap_connection_gate.dart';
import '../../../infrastructure/sync/outbox_drain_service.dart';
import '../../../infrastructure/sync/removal_tombstone_store.dart';
import '../../../infrastructure/sync/spam_db_sync_service.dart';
import 'mail_poller_state.dart';

class MailPollerCubit extends Cubit<MailPollerState> with WidgetsBindingObserver {
  MailPollerCubit({
    required AccountManager accountManager,
    required AppSettings appSettings,
    required BadgeService badgeService,
    required BodyPrefetchService bodyPrefetchService,
    required ConnectivityService connectivityService,
    required DeltaTokenDatasource database,
    required EmailLocalDatasource emailLocalDatasource,
    required FolderLocalDatasource folderLocalDatasource,
    required GetCachedFolders getCachedFolders,
    required ImapConnectionGate imapConnectionGate,
    required NotificationService notificationService,
    required OutboxDrainService outboxDrainService,
    required PendingOperationsDatasource pendingOperations,
    required RemovalTombstoneStore removalTombstones,
    required SpamDbSyncService spamDbSyncService,
  })  : _accountManager = accountManager,
        _appSettings = appSettings,
        _badgeService = badgeService,
        _bodyPrefetch = bodyPrefetchService,
        _connectivityService = connectivityService,
        _database = database,
        _emailLocalDatasource = emailLocalDatasource,
        _folderLocalDatasource = folderLocalDatasource,
        _getCachedFolders = getCachedFolders,
        _imapConnectionGate = imapConnectionGate,
        _notificationService = notificationService,
        _outboxDrainService = outboxDrainService,
        _pendingOperations = pendingOperations,
        _removalTombstones = removalTombstones,
        _spamDbSyncService = spamDbSyncService,
        super(const MailPollerState(
          accountsWithNewMail: {},
          pollIntervalSeconds: AppSettings.defaultPollIntervalSeconds,
        ));

  final AccountManager _accountManager;
  final AppSettings _appSettings;
  final BadgeService _badgeService;
  final BodyPrefetchService _bodyPrefetch;
  final ConnectivityService _connectivityService;
  final DeltaTokenDatasource _database;
  final EmailLocalDatasource _emailLocalDatasource;
  final FolderLocalDatasource _folderLocalDatasource;
  final GetCachedFolders _getCachedFolders;
  final ImapConnectionGate _imapConnectionGate;
  final NotificationService _notificationService;
  final OutboxDrainService _outboxDrainService;
  final PendingOperationsDatasource _pendingOperations;
  final RemovalTombstoneStore _removalTombstones;
  final SpamDbSyncService _spamDbSyncService;

  Timer? _timer;
  bool _polling = false;
  bool _initialized = false;
  final Map<String, int> _baselineUnread = {};
  final Map<String, int> _baselineTotal = {};
  final Map<String, int> _latestPolledUnread = {};
  final Set<String> _newMailAccounts = {};
  final Set<String> _bootstrapping = {};
  final Set<String> _reauthAccounts = {};
  StreamSubscription<void>? _reconnectSub;

  /// Consecutive delta failures per [_folderKey]. A delta stream that keeps
  /// failing has its token dropped so the next cycle re-bootstraps — see
  /// [_maxDeltaFailuresBeforeReset].
  final Map<String, int> _deltaFailures = {};

  /// Consecutive delta *bootstrap* failures per account. Counted here because
  /// the bootstrap runs unawaited, so its throw never reaches the poll loop's
  /// per-account handlers.
  final Map<String, int> _bootstrapFailures = {};

  /// One subscription per IMAP account to its datasource's change stream, so a
  /// server push turns into a poll. Kept for the cubit's lifetime — the stream
  /// belongs to the datasource, which AccountManager caches per account.
  final Map<String, StreamSubscription<String>> _idleSubs = {};

  /// The Inbox's real folder id per account, as last resolved by a cycle that
  /// fetched folders.
  ///
  /// Remembered across cycles rather than rebuilt by each one, because a delta
  /// that reports no changes deliberately fetches no folders — so a per-cycle
  /// map was empty exactly when the mailbox was quiet, and the watched-folder
  /// step below could not tell "the user is on the Inbox" (already synced, or in
  /// this case nothing to sync) from a second folder. It re-fetched and
  /// re-cached the whole Inbox page on every quiet cycle, which is also what
  /// made [_samePage] the only thing standing between a quiet mailbox and a
  /// full UI reload every interval.
  ///
  /// An Inbox does not change its id, and any cycle that does fetch folders
  /// overwrites this, so a remembered value is never staler than the account.
  final Map<String, String> _inboxIds = {};

  /// Per-account failure from the current cycle, published on the state.
  final Map<String, String> _errors = {};

  /// The folder the user is looking at on the active account, or null when it is
  /// the Inbox (or nothing). Set by the UI — the poller has no route to the
  /// email list's state, and syncing only the Inbox is why a machine parked on
  /// another folder never updated.
  String? _watchedFolderId;

  static const _systemEventsChannel =
      MethodChannel('au.com.sharpblue.nightmail/system_events');

  /// Ceiling on one whole cycle. Nothing here can be cancelled — the timeout
  /// only stops us *awaiting* — so this is deliberately generous: its job is to
  /// unlatch [_polling] after a genuine wedge, not to police slow networks.
  /// Overlapping cycles are the lesser evil against polling stopping for the
  /// lifetime of the process.
  static const _cycleDeadline = Duration(minutes: 5);

  // There is deliberately no *per-account* deadline here. Bounding one
  // account's turn means wrapping the loop body in a closure, which the body's
  // `continue`s cannot cross; and the right place for that bound is the
  // transport anyway, where a timeout can actually abort the request instead of
  // merely stopping us awaiting it. Each client owns its own timeouts;
  // [_cycleDeadline] is the backstop for anything that slips past them.

  /// After this many consecutive failures on one folder's delta stream, drop the
  /// token and re-bootstrap. A stored delta link the server rejects is otherwise
  /// permanent: it survives restart in [DeltaSyncTokens], and only a 410 used to
  /// clear it.
  static const _maxDeltaFailuresBeforeReset = 3;

  /// How much of a folder a poll re-fetches. Matches EmailListBloc's page size,
  /// so the cache the list repaints from holds exactly one page.
  static const _watchedPageSize = 25;

  /// Graph's well-known name for the Inbox, which it resolves itself. Used as
  /// the delta path segment and the delta-token key — deliberately not the
  /// folder's real id, so tokens issued before per-folder watching stay valid
  /// instead of forcing every account to re-bootstrap on upgrade.
  static const _inboxWellKnownName = 'inbox';

  /// Appended to a folder id to key its persisted IMAP UIDVALIDITY in the
  /// delta-token store, so it cannot be mistaken for a delta cursor. `#` cannot
  /// appear in a Graph folder id or an IMAP mailbox path.
  static const _uidValiditySuffix = '#uidvalidity';

  static String _folderKey(String accountId, String folderId) =>
      '$accountId|$folderId';

  // Keys in [_errors] for failures that belong to the cycle rather than to one
  // account. Prefixed so they cannot collide with a real account id.
  static const _cycleKey = '__cycle__';
  static const _outboxKey = '__outbox__';
  static const _offlineKey = '__offline__';

  /// Tells the poller which folder is on screen for the active account, so the
  /// cycle syncs it as well as the Inbox.
  ///
  /// Pass the Inbox's own id (or null) when the Inbox is showing — it is always
  /// synced anyway. Changing folders re-polls straight away rather than leaving
  /// the user on a cache that may be a full interval old.
  void setWatchedFolder(String? folderId) {
    if (_watchedFolderId == folderId) return;
    _watchedFolderId = folderId;
    if (folderId != null) _poll();
  }

  Future<void> initialize() async {
    // Remove before add to guard against multiple initialize() calls (e.g.
    // BlocProvider.value rebuilds) registering duplicate observers.
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb && Platform.isMacOS) {
      _systemEventsChannel.setMethodCallHandler((call) async {
        if (call.method == 'systemDidWake') _poll();
      });
    }
    final interval = await _appSettings.loadPollIntervalSeconds();
    if (!isClosed) emit(state.copyWith(pollIntervalSeconds: interval));
    await _primeBadgeFromCache();
    _startTimer(interval);

    // Drains the outbox (and refreshes) the moment connectivity returns,
    // rather than waiting up to a full poll interval — the poll-tick drain
    // in _poll() is the correctness baseline, this is the responsiveness
    // improvement on top of it.
    _reconnectSub?.cancel();
    _reconnectSub = _connectivityService.onReconnected.listen((_) {
      // _poll() already drains the outbox at its top — no need to also call
      // it directly here.
      _poll();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _poll();
  }

  Future<void> _primeBadgeFromCache() async {
    int total = 0;
    for (final account in _accountManager.accounts) {
      final result = await _getCachedFolders(account.id);
      result.fold((_) {}, (folders) {
        final inbox = folders.where(
          (f) => f.displayName.toLowerCase() == 'inbox',
        );
        if (inbox.isNotEmpty) {
          final count = inbox.first.unreadItemCount;
          _latestPolledUnread[account.id] = count;
          // Seeded here as well as from a live fetch, because this is the case
          // where no cycle may ever fetch folders: priming the count from cache
          // is what lets a quiet delta skip the folder request entirely, and
          // without the id from the same rows the Inbox then looks like a second
          // folder to the watched-folder step. See [_inboxIds].
          _inboxIds[account.id] = inbox.first.id;
          // Both baselines are primed, not just the badge's unread count:
          // they are what the first poll compares the server against to work
          // out whether the counts already on screen are stale. See
          // [_shouldPrimeBaseline].
          _baselineUnread[account.id] = count;
          _baselineTotal[account.id] = inbox.first.totalItemCount;
          total += count;
        }
      });
    }
    if (total > 0) await _badgeService.setBadgeCount(total);
  }

  /// Whether this cycle should merely *establish* the account's baseline
  /// rather than report a change against it.
  ///
  /// The first cycle normally primes, so unread mail that already existed
  /// before NightMail was opened doesn't announce itself as newly arrived.
  /// The active account is the exception, and deliberately so: it already has
  /// a baseline from the folder cache ([_primeBadgeFromCache]), and comparing
  /// against that is the only thing that catches a cold-start folder fetch
  /// which failed *silently* — an OAuth refresh that raced the machine's
  /// network coming up, or the connectivity probe fast-failing before the
  /// route settled. Both leave [FolderListBloc] showing yesterday's cached
  /// counts with no error and nothing queued to re-request them.
  ///
  /// Priming over that baseline instead would notice the discrepancy exactly
  /// once, overwrite it, and then agree with the server on every later cycle —
  /// so the stale count sat on screen until the user refreshed by hand. The
  /// active account never raises a notification, so comparing it on the first
  /// cycle cannot produce a spurious alert; the worst case is one redundant
  /// refresh of a folder list that was already correct.
  bool _shouldPrimeBaseline(String accountId, String? activeAccountId) {
    if (!_baselineUnread.containsKey(accountId)) return true;
    return !_initialized && accountId != activeAccountId;
  }

  void _startTimer(int seconds) {
    _timer?.cancel();
    _timer = null;
    if (seconds <= 0) return;
    _poll();
    _timer = Timer.periodic(Duration(seconds: seconds), (_) => _poll());
  }

  Future<void> _poll() async {
    if (_polling || isClosed) return;
    // Skip the cycle outright while offline rather than let each account's
    // network call run out its connect timeout (tens of seconds) in turn —
    // there's nothing to sync, and onReconnected already triggers a poll the
    // moment connectivity returns.
    if (!await _connectivityService.isOnline) {
      // Reported rather than silent: a probe stuck on offline (a captive
      // portal, a VPN, a fast-failing route) looks exactly like a quiet
      // mailbox otherwise, and onReconnected needs a false→true edge that a
      // stuck probe never produces.
      debugPrint('[MailPoller] cycle skipped — connectivity reports offline');
      _errors
        ..clear()
        ..[_offlineKey] = 'connectivity reports offline';
      if (!isClosed) {
        emit(state.copyWith(
          lastPollAt: DateTime.now(),
          lastPollErrors: Map.of(_errors),
        ));
      }
      return;
    }
    _polling = true;
    try {
      await _runCycle().timeout(_cycleDeadline);
    } on TimeoutException {
      // Nothing here is cancellable, so the abandoned work may still land. That
      // is accepted: the alternative was _polling latched true forever, which
      // stopped polling for *every* account for the lifetime of the process.
      debugPrint('[MailPoller] cycle abandoned after '
          '${_cycleDeadline.inMinutes} min — something never completed');
      _errors[_cycleKey] = 'poll cycle timed out';
    } catch (e) {
      // _runCycle reports per-account failures itself; this is the backstop
      // that keeps an unexpected throw from escaping the timer callback.
      debugPrint('[MailPoller] cycle failed: $e');
      _errors[_cycleKey] = '$e';
    } finally {
      _polling = false;
      if (!isClosed) {
        emit(state.copyWith(
          lastPollAt: DateTime.now(),
          lastPollErrors: Map.of(_errors),
        ));
      }
    }
  }

  Future<void> _runCycle() async {
    // Captured so we can notify only for accounts that newly gained unread
    // mail *this cycle* — not ones already flagged from a previous poll, and
    // not the very first poll, which just establishes the baseline from
    // whatever unread mail already existed before NightMail was opened.
    final wasInitialized = _initialized;
    final previousNewMailAccounts = Set<String>.of(_newMailAccounts);
    _errors.clear();

    // Accounts that took the delta branch this cycle. The aggregate new-mail
    // toast at the tail must skip them, because the delta branch already raised
    // a notification per message with a real subject and sender. This used to be
    // an `is MicrosoftAccount` test, which became silently wrong the moment
    // Gmail gained a delta path of its own.
    final deltaSyncedAccounts = <String>{};

    // Replays any queued offline mutations, and awaits it before syncing
    // server state below — draining first means a locally-queued delete or
    // mark-read has already reached the server by the time the delta/list
    // fetch below asks "what changed", so the fetch naturally reflects our
    // own mutations instead of racing them. This is the baseline sync
    // trigger for the outbox — it guarantees a queued mutation reaches the
    // server within one poll interval regardless of network state when it
    // was made; a connectivity-triggered drain (faster than waiting for the
    // next tick) is a responsiveness improvement on top of this, not a
    // correctness dependency.
    //
    // Guarded: this used to sit *outside* the try whose finally cleared
    // _polling, so a throw here latched the flag and killed polling for good.
    try {
      await _outboxDrainService.drainAll();
    } catch (e) {
      debugPrint('[MailPoller] outbox drain failed: $e');
      _errors[_outboxKey] = 'outbox drain failed: $e';
    }

    {
      final accounts = _accountManager.accounts;
      if (accounts.isEmpty) return;

      final activeId = _accountManager.activeAccount?.id;
      bool changed = false;
      bool activeInboxChanged = false;

      /// The active account's folders this cycle actually wrote cache for. The
      /// UI can only repaint from cache for a folder in here; anything else has
      /// to go to the network.
      final syncedForActive = <String>{};

      /// The resolved Inbox id per account, so the watched-folder step can tell
      /// "the user is on the Inbox" (already synced) from a real second folder.
      /// Kept on the cubit, not this cycle — see [_inboxIds].
      final inboxIdByAccount = _inboxIds;


      // Full-body prefetch jobs collected as new mail is cached this cycle,
      // then run after the UI-refresh emit below (see the tail of the try).
      // Deferred rather than run inline so the list still repaints from the
      // envelope cache immediately; the bodies fill in a beat later so a tap
      // opens instantly instead of blocking on a per-message fetch.
      final prefetchJobs = <
          ({
            String accountId,
            EmailRemoteDatasource datasource,
            List<Email> emails,
          })>[];

      for (final account in accounts) {
        try {
          // Optimistically assume this round will succeed; the AuthException
          // handler below re-flags the account if it doesn't.
          if (_reauthAccounts.remove(account.id)) changed = true;
          final ds = _accountManager.buildEmailDatasourceForAccount(account);

          // Any provider that can answer "what changed" takes the delta path —
          // Graph via its delta link, Gmail via users.history.list. Both store
          // their cursor under the same ('inbox') key: the Gmail datasource
          // resolves that name to the INBOX label itself, so there is no
          // per-provider key logic and no migration.
          if (ds is MailDeltaDatasource) {
            final deltaDs = ds as MailDeltaDatasource;
            deltaSyncedAccounts.add(account.id);
            final savedToken =
                await _database.loadDeltaToken(account.id, 'inbox');

            if (savedToken == null) {
              // No token yet: use folder polling for unread count and kick off
              // an async bootstrap to fetch the initial delta token.
              final folders = await ds.getMailFolders();
              final inboxes = folders
                  .where((f) => f.displayName.toLowerCase() == 'inbox');
              if (inboxes.isEmpty) continue;
              inboxIdByAccount[account.id] = inboxes.first.id;
              await _persistFolderCounts(account.id, folders);
              final unreadCount = inboxes.first.unreadItemCount;
              final totalCount = inboxes.first.totalItemCount;
              _latestPolledUnread[account.id] = unreadCount;

              if (_shouldPrimeBaseline(account.id, activeId)) {
                _baselineUnread[account.id] = unreadCount;
                _baselineTotal[account.id] = totalCount;
                if (account.id != activeId && unreadCount > 0) {
                  if (_newMailAccounts.add(account.id)) changed = true;
                }
              } else {
                if (account.id == activeId) {
                  final prevUnread = _baselineUnread[account.id];
                  final prevTotal = _baselineTotal[account.id];
                  // Mirror Gmail/IMAP: any change (increase or decrease) must
                  // refresh the UI. A decrease means mail was deleted or read
                  // on another client and would otherwise never self-heal.
                  if ((prevUnread != null && unreadCount != prevUnread) ||
                      (prevTotal != null && totalCount != prevTotal)) {
                    activeInboxChanged = true;
                  }
                  _baselineUnread[account.id] = unreadCount;
                  _baselineTotal[account.id] = totalCount;
                  if (_newMailAccounts.remove(account.id)) changed = true;
                } else if (unreadCount > 0) {
                  if (_newMailAccounts.add(account.id)) changed = true;
                } else {
                  if (_newMailAccounts.remove(account.id)) changed = true;
                }
              }

              unawaited(_bootstrapDeltaToken(account.id, deltaDs));
            } else {
              // Incremental delta sync — only fetch changes since last call.
              final result = await deltaDs.syncMailDelta('inbox',
                  deltaLink: savedToken);
              // The stream answered, so whatever streak of failures it was on
              // is over.
              _deltaFailures.remove(_folderKey(account.id, 'inbox'));

              if (result.hasChanges) {
                // Mirror the delta straight into the cache so the message
                // list can repaint from disk without waiting on a second,
                // separate network round-trip. Awaited: pollGeneration bumps
                // right after this loop and the list repaints from cache, so
                // the write must land first.
                await _cacheUpserted(
                  account.id,
                  result.upserted,
                  inboxFolderId: inboxIdByAccount[account.id],
                );
                // Awaited for the same reason as the writes either side of it:
                // the list repaints from cache as soon as this loop ends.
                await _applyFieldUpdates(account.id, result.fieldUpdates);
                if (result.upserted.isNotEmpty) {
                  // Newly-arrived delta messages carry only bodyPreview — queue
                  // a background body fetch so opening them is instant. Not
                  // done in the null-token bootstrap path, whose first pass can
                  // run to a page budget and would flood the network.
                  prefetchJobs.add((
                    accountId: account.id,
                    datasource: ds,
                    emails: result.upserted,
                  ));
                }
                // Awaited, not fire-and-forget: pollGeneration bumps right
                // after this loop and the list repaints from cache, so a
                // removal still in flight would let a message the user deleted
                // elsewhere survive the repaint and reappear.
                for (final removedId in result.removedIds) {
                  await _emailLocalDatasource.deleteEmailFromCache(
                    accountId: account.id,
                    emailId: removedId,
                  );
                }
                // A move, not a delete: the message is still in the mailbox, so
                // its cached inline images stay put rather than being downloaded
                // again the first time the destination folder is opened.
                for (final movedId in result.movedOutIds) {
                  await _emailLocalDatasource.deleteEmailFromCache(
                    accountId: account.id,
                    emailId: movedId,
                    evictInlineAttachments: false,
                  );
                }

                // Refresh unread count only when something actually changed.
                final folders = await ds.getMailFolders();
                final inboxes = folders
                    .where((f) => f.displayName.toLowerCase() == 'inbox');
                if (inboxes.isEmpty) continue;
                inboxIdByAccount[account.id] = inboxes.first.id;
                await _persistFolderCounts(account.id, folders);
                final unreadCount = inboxes.first.unreadItemCount;
                _latestPolledUnread[account.id] = unreadCount;

                final hasNewUnread = result.upserted.any((e) => !e.isRead);

                if (account.id == activeId) {
                  _baselineUnread[account.id] = unreadCount;
                  if (_newMailAccounts.remove(account.id)) changed = true;
                  activeInboxChanged = true;
                  // _cacheUpserted files each message under its own
                  // parentFolderId, which for an inbox delta is this id — so a
                  // repaint from the Inbox's cache is valid.
                  syncedForActive.add(inboxes.first.id);
                } else if (hasNewUnread) {
                  if (_newMailAccounts.add(account.id)) changed = true;
                  // Send one notification per new unread email (capped at 5).
                  final newEmails =
                      result.upserted.where((e) => !e.isRead).take(5);
                  for (final email in newEmails) {
                    unawaited(_notificationService.showEmailNotification(
                      emailId: email.id,
                      accountId: account.id,
                      subject: email.subject,
                      senderName: email.from.displayName,
                      accountLabel: account.displayName,
                    ));
                  }
                } else if (unreadCount == 0) {
                  if (_newMailAccounts.remove(account.id)) changed = true;
                }
              } else if (!_latestPolledUnread.containsKey(account.id)) {
                // No changes and no cached count yet (first poll after startup).
                // Fetch folders once to prime the badge count.
                final folders = await ds.getMailFolders();
                final inboxes = folders
                    .where((f) => f.displayName.toLowerCase() == 'inbox');
                if (inboxes.isEmpty) continue;
                inboxIdByAccount[account.id] = inboxes.first.id;
                await _persistFolderCounts(account.id, folders);
                final unreadCount = inboxes.first.unreadItemCount;
                _latestPolledUnread[account.id] = unreadCount;
                _baselineUnread[account.id] = unreadCount;
              }
              // No changes and count already known → badge count is unchanged.

              // Persisted only now that every change the page carried has been
              // applied. A delta link is a one-shot receipt: advancing it first
              // meant a failed cache write lost those changes permanently,
              // because the next cycle asked from the *new* link and was told
              // hasChanges == false. Replaying a page is harmless by contrast —
              // cacheEmails upserts and deleteEmailFromCache no-ops on a row
              // that has already gone.
              await _database.saveDeltaToken(
                  account.id, 'inbox', result.deltaLink);
            }
          } else {
            // Non-delta path: Gmail / IMAP — existing unread-count polling.
            // Gated: an IMAP account's datasource holds one stateful
            // connection shared with OutboxDrainService and account
            // migration, which serialize themselves against the same gate —
            // without it here, a migration fetch could land mid-SELECT from
            // this poll and corrupt the session. A no-op for Gmail/Graph,
            // which don't share connection state this way.
            final folders = await _imapConnectionGate.runExclusive(
              account.id,
              () => ds.getMailFolders(),
            );

            // IMAP-only: pull the shared spam filter DB from the SPAMDB
            // folder if another client has pushed a newer version. Awaited,
            // not fire-and-forget: ImapDatasourceImpl holds one connection
            // with one selected mailbox, so a SPAMDB SELECT left running
            // unawaited could still be in flight when the getEmails() call
            // below selects INBOX, racing the two mailbox selections against
            // each other on the same connection. Errors are swallowed
            // inside the service itself, so this can't fail unread polling.
            if (account is ImapAccount && ds is SpamDbSyncDatasource) {
              final spamDbDs = ds as SpamDbSyncDatasource;
              await _imapConnectionGate.runExclusive(
                account.id,
                () => _spamDbSyncService.pullForAccount(account.id, spamDbDs),
              );
            }

            final inboxes =
                folders.where((f) => f.displayName.toLowerCase() == 'inbox');
            if (inboxes.isEmpty) continue;
            inboxIdByAccount[account.id] = inboxes.first.id;
            await _persistFolderCounts(account.id, folders);
            // Before anything reads or writes this account's cache: the
            // getMailFolders above is what supplies the UIDVALIDITY readings.
            await _dropCacheForRebuiltImapFolders(account.id, ds);
            final unreadCount = inboxes.first.unreadItemCount;
            _latestPolledUnread[account.id] = unreadCount;

            final totalCount = inboxes.first.totalItemCount;

            if (_shouldPrimeBaseline(account.id, activeId)) {
              _baselineUnread[account.id] = unreadCount;
              _baselineTotal[account.id] = totalCount;
              if (account.id != activeId && unreadCount > 0) {
                if (_newMailAccounts.add(account.id)) changed = true;
              }
              continue;
            }

            final prevUnread = _baselineUnread[account.id];
            final prevTotal = _baselineTotal[account.id];
            // Any change — not just an increase — must refresh: a decrease can
            // come from reading/deleting mail on another client, or from an
            // in-app action whose optimistic local update was missed, and would
            // otherwise never self-heal.
            final countsChanged =
                (prevUnread != null && unreadCount != prevUnread) ||
                    (prevTotal != null && totalCount != prevTotal);

            if (countsChanged && account.id == activeId) {
              // Flagged as soon as the *counts* disagree, before the fetch
              // below: "something changed" is knowledge worth acting on even if
              // our own attempt to cache the new page then fails, and the UI's
              // refresh can go to the network itself. Only syncedForActive is
              // conditional on the write landing.
              activeInboxChanged = true;
            }

            if (countsChanged) {
              // Gmail/IMAP have no delta feed, so unlike the Graph branch
              // above there's no upserted-message list — fetch the inbox
              // page directly and cache it (awaited: pollGeneration bumps
              // right after this loop and the list repaints from cache,
              // so the write must land first) instead of showing stale
              // data until a manual refresh.
              //
              // Done for EVERY account, not just the active one. A non-active
              // account used to have nothing but a boolean "has new mail" flag
              // toggled, so switching to it showed a cache frozen at whenever
              // it was last selected until a manual refresh landed.
              //
              // Guarded on its own so a failure here still leaves the baselines
              // below updated and the other accounts polled — this is a cache
              // warm, not the cycle's purpose.
              try {
                final freshEmails = await ds.getEmails(
                    folderId: inboxes.first.id, top: _watchedPageSize);
                final reconciled =
                    await _reconcileAgainstPendingOps(account.id, freshEmails);
                // Replace the folder's rows rather than merge into them, the
                // same way EmailListBloc's refresh does. A plain cacheEmails is
                // an upsert, so it can only ever *add* — a thread that has left
                // this folder is never returned again and its rows would sit in
                // the cache untouched, and since the list repaints from cache
                // right after this poll, a just-filed thread reappears in the
                // Inbox and stays there until a manual folder refresh.
                //
                // `replaceFolder` rather than clearCacheForFolder then write:
                // the drop runs inside the same transaction and *after*
                // cacheEmails' body-preservation lookups, so a poll no longer
                // discards every cached body in the Inbox (and make
                // BodyPrefetchService re-download them). An empty page is a
                // no-op inside cacheEmails, which is also where the "never
                // clear on an empty result" rule now lives.
                await _emailLocalDatasource.cacheEmails(
                  accountId: account.id,
                  folderId: inboxes.first.id,
                  emails: reconciled,
                  replaceFolder: true,
                );
                if (account.id == activeId) {
                  // Only now that the write has landed: this is what tells the
                  // UI a repaint from this folder's cache is valid.
                  syncedForActive.add(inboxes.first.id);
                  // Warm the body cache for the page we just synced so tapping a
                  // message opens instantly instead of fetching on demand.
                  // Active account only — 20 body fetches per background
                  // account per change is bandwidth spent on mail nobody is
                  // looking at.
                  prefetchJobs.add((
                    accountId: account.id,
                    datasource: ds,
                    emails: reconciled,
                  ));
                }
              } catch (e) {
                debugPrint('[MailPoller] ${account.id}: inbox page sync failed '
                    'after a count change: $e');
                _errors[account.id] = 'inbox page sync failed: $e';
              }
            }

            _baselineUnread[account.id] = unreadCount;
            _baselineTotal[account.id] = totalCount;

            if (account.id == activeId) {
              if (_newMailAccounts.remove(account.id)) changed = true;
            } else if (unreadCount > 0) {
              if (_newMailAccounts.add(account.id)) changed = true;
            } else {
              if (_newMailAccounts.remove(account.id)) changed = true;
            }
          }

          // Sync the folder on screen as well as the Inbox.
          //
          // This is the whole of the reported bug on any provider: the list
          // repaints from the cache of the folder *showing*, and the poll only
          // ever wrote the Inbox — so a machine parked on Archive, Sent, Junk, a
          // subfolder or a Gmail label re-read its own untouched cache and never
          // changed, with no other automatic refresh anywhere on desktop.
          if (account.id == activeId) {
            final watched = _watchedFolderId;
            if (watched != null && watched != inboxIdByAccount[account.id]) {
              if (await _syncWatchedFolder(
                account: account,
                ds: ds,
                folderId: watched,
                prefetchJobs: prefetchJobs,
              )) {
                activeInboxChanged = true;
              }
              syncedForActive.add(watched);
            }
          }
        } on ServerException catch (e) {
          // 410 is the documented "delta token expired" (tokens live 7 days).
          // 400 and 404 are the undocumented but real equivalents: Graph
          // escapes its own separators inside a delta link, so a link the app
          // stored and replayed verbatim can be rejected outright — and
          // graph_message_parser's unescaping only covers some of them. A
          // statusCode of null is the "delta query completed without returning
          // a delta link" case. All three used to leave the bad token on disk
          // in the persistent DeltaSyncTokens table, so the account did nothing
          // at all on every cycle for the rest of the install's life.
          final fatal = e.statusCode == null ||
              e.statusCode == 410 ||
              e.statusCode == 400 ||
              e.statusCode == 404;
          if (fatal) {
            debugPrint('[MailPoller] ${account.id}: delta token rejected '
                '(status ${e.statusCode}) — clearing so the next cycle '
                'bootstraps: ${e.message}');
            await _database.clearDeltaTokensForAccount(account.id);
            _deltaFailures.remove(_folderKey(account.id, 'inbox'));
          } else {
            await _noteDeltaFailure(account.id, 'inbox',
                'HTTP ${e.statusCode}: ${e.message}');
          }
          _errors[account.id] = 'HTTP ${e.statusCode}: ${e.message}';
        } on AuthException catch (e) {
          // Refresh token rejected/revoked — surface this account as needing
          // re-authentication instead of silently freezing its counts forever.
          if (_reauthAccounts.add(account.id)) changed = true;
          _errors[account.id] = 'authentication failed: ${e.message}';
        } on TimeoutException {
          // Raised by a client's own transport timeout. Reported so a provider
          // that is reachable but never answers is distinguishable from one
          // with nothing to say, and counted so a delta stream that only ever
          // times out eventually gets re-bootstrapped.
          debugPrint('[MailPoller] ${account.id}: request timed out — '
              'moving on to the next account');
          _errors[account.id] = 'timed out';
          await _noteDeltaFailure(account.id, 'inbox', 'timed out');
        } catch (e) {
          // Other accounts still get their turn and the next cycle retries —
          // but it is *reported* now. Every one of these was silent, which is
          // how a deterministic failure came to look like a quiet mailbox.
          debugPrint('[MailPoller] ${account.id}: poll failed: $e');
          _errors[account.id] = '$e';
          await _noteDeltaFailure(account.id, 'inbox', '$e');
        }
      }

      _initialized = true;
      final totalUnread =
          _latestPolledUnread.values.fold(0, (sum, n) => sum + n);
      await _badgeService.setBadgeCount(totalUnread);
      if (activeInboxChanged) {
        // On the first cycle this is the report that the counts and list the
        // app opened with were stale — i.e. that the cold-start fetch failed
        // and this poll is what repaired it. See [_shouldPrimeBaseline].
        debugPrint('[MailPoller] active account changed in '
            '${syncedForActive.join(', ')} — reloading folders and list'
            '${wasInitialized ? '' : ' (first cycle: what the app '
                'opened with was stale)'}');
      }
      // syncedFolderIds is published on every cycle, not only a changed one:
      // it tells the UI which folders a *repaint from cache* is valid for, and
      // that answer is just as true when nothing changed.
      if ((changed || activeInboxChanged) && !isClosed) {
        emit(state.copyWith(
          accountsWithNewMail: Set.of(_newMailAccounts),
          pollGeneration: activeInboxChanged
              ? state.pollGeneration + 1
              : state.pollGeneration,
          accountsNeedingReauth: Set.of(_reauthAccounts),
          syncedFolderIds: Set.of(syncedForActive),
        ));
      } else if (!isClosed && !setEquals(state.syncedFolderIds, syncedForActive)) {
        emit(state.copyWith(syncedFolderIds: Set.of(syncedForActive)));
      }

      // Prefetch full bodies for the mail synced this cycle. Runs here — after
      // the repaint emit, but while _polling is still true so the guard at the
      // top of _poll() defers the next tick — because an IMAP account's fetch
      // and this prefetch share one connection with a single selected mailbox;
      // letting them overlap would race that selection. Best-effort: the
      // service swallows per-message errors, and this guard keeps an
      // unexpected throw from escaping the timer callback.
      if (!isClosed) {
        for (final job in prefetchJobs) {
          try {
            await _bodyPrefetch.prefetchBodies(
              accountId: job.accountId,
              datasource: job.datasource,
              emails: job.emails,
            );
          } catch (_) {
            // Ignore — prefetch is an optimisation, never a poll failure.
          }
        }
      }

      // Last, so nothing in the cycle has to wait for IDLE to hand the
      // connection back.
      _startIdleWatches(inboxIdByAccount);
    }

    // Windows/Linux have no OS-level badge/dock affordance for background
    // accounts the way macOS (dock badge) and mobile (background isolate +
    // WorkManager notification) do, so the foreground poller raises a toast
    // itself here. Skips any account that took the delta branch this cycle:
    // that branch already called showEmailNotification with real message
    // detail, so this aggregate fallback would double-notify.
    if (wasInitialized && (Platform.isWindows || Platform.isLinux)) {
      final newlyFlagged = _newMailAccounts.difference(previousNewMailAccounts);
      for (final accountId in newlyFlagged) {
        if (deltaSyncedAccounts.contains(accountId)) continue;
        Account? account;
        for (final a in _accountManager.accounts) {
          if (a.id == accountId) {
            account = a;
            break;
          }
        }
        if (account == null) continue;
        unawaited(_notifyNewMail(account));
      }
    }
  }

  /// Gmail/IMAP have no delta sync, so unlike the Graph path above this has
  /// no upserted-message list to read a real subject/sender from — only an
  /// aggregate unread count. Fetches the inbox's most recent unread message
  /// for real notification content, falling back to the generic aggregate
  /// alert if that fails (no inbox, empty result, network error, etc.).
  Future<void> _notifyNewMail(Account account) async {
    final newCount = _latestPolledUnread[account.id] ?? 0;
    try {
      final ds = _accountManager.buildEmailDatasourceForAccount(account);
      final folders = await _imapConnectionGate.runExclusive(
        account.id,
        () => ds.getMailFolders(),
      );
      final inbox = folders
          .where((f) => f.displayName.toLowerCase() == 'inbox')
          .firstOrNull;
      if (inbox == null) throw StateError('no inbox folder');
      final emails = await _imapConnectionGate.runExclusive(
        account.id,
        () => ds.getEmails(folderId: inbox.id, top: 10),
      );
      unawaited(
        _reconcileAgainstPendingOps(account.id, emails).then((reconciled) =>
            _emailLocalDatasource.cacheEmails(
              accountId: account.id,
              folderId: inbox.id,
              emails: reconciled,
            )),
      );
      final latestUnread = emails.where((e) => !e.isRead).firstOrNull;
      if (latestUnread == null) throw StateError('no unread message found');
      final senderName = newCount > 1
          ? '${latestUnread.from.displayName} and ${newCount - 1} more'
          : latestUnread.from.displayName;
      await _notificationService.showEmailNotification(
        emailId: latestUnread.id,
        accountId: account.id,
        subject: latestUnread.subject,
        senderName: senderName,
        accountLabel: account.displayName,
      );
    } catch (_) {
      await _notificationService.showNewMailNotification(
        accountLabel: account.emailAddress,
        newCount: newCount,
      );
    }
  }

  /// Writes the freshly-fetched folder rows into the folder cache.
  ///
  /// The poll fetches counts from the *datasource* on every cycle and used to
  /// throw them away — only `EmailRepositoryImpl.getMailFolders` (i.e. the UI
  /// asking) and the mobile background isolate ever wrote `cached_folders`. So a
  /// background account's on-disk counts were frozen at whenever it was last
  /// selected, and [_primeBadgeFromCache] seeded the next cold start from them.
  ///
  /// Merged, never cleared: the poll only sees top-level folders, so replacing
  /// the cache wholesale would drop every known subfolder. `cacheFolders` is an
  /// upsert, which is exactly the merge wanted.
  Future<void> _persistFolderCounts(
    String accountId,
    List<EmailFolder> folders,
  ) async {
    if (folders.isEmpty) return;
    try {
      await _folderLocalDatasource.cacheFolders(
        accountId: accountId,
        folders: folders,
      );
    } catch (e) {
      // Never fail a poll over the folder cache — the counts are still correct
      // in memory for the badge, and the next cycle retries.
      debugPrint('[MailPoller] $accountId: folder count cache write failed: $e');
    }
  }

  /// Puts every IMAP account's connection into IDLE on the folder being watched,
  /// so a change made elsewhere arrives in seconds instead of at the next tick.
  ///
  /// Called at the end of a cycle rather than the start: IDLE holds the
  /// connection, and although the datasource yields it the moment another caller
  /// queues, there is no reason to make the cycle's own fetches wait behind that
  /// handover. The watcher stops itself on any failure, so calling this every
  /// cycle *is* the recovery path — it is idempotent and re-selects when the
  /// folder changes.
  ///
  /// Main window only, and that is enforced inside `startIdleWatch` too: a
  /// sub-window must not own a long-lived connection (see the sub-window rules
  /// in CLAUDE.md).
  void _startIdleWatches(Map<String, String> inboxIdByAccount) {
    if (!AppWindow.isMain) return;
    final activeId = _accountManager.activeAccount?.id;
    for (final account in _accountManager.accounts) {
      if (account is! ImapAccount) continue;
      final EmailRemoteDatasource ds;
      try {
        ds = _accountManager.buildEmailDatasourceForAccount(account);
      } catch (_) {
        continue;
      }
      if (ds is! ImapDatasourceImpl) continue;
      // Captured into its own local because the promotion above does not reach
      // inside the closure below.
      final imapDs = ds;

      // Watch what the user is looking at, falling back to the Inbox — the same
      // choice the cycle itself makes about which folders to sync.
      final watched = account.id == activeId ? _watchedFolderId : null;
      final path = watched ?? inboxIdByAccount[account.id];
      if (path == null) continue;

      _idleSubs.putIfAbsent(
        account.id,
        () => imapDs.mailboxChanges.listen(
          (changedPath) {
            debugPrint('[MailPoller] ${account.id}: IMAP reported a change in '
                '$changedPath — polling now');
            _poll();
          },
          onError: (Object e) => debugPrint(
              '[MailPoller] ${account.id}: IMAP change stream failed: $e'),
        ),
      );
      imapDs.startIdleWatch(path);
    }
  }

  /// Drops the cached rows of any IMAP folder the server has rebuilt.
  ///
  /// An IMAP message's identity here is `'$folderId:$uid'`, and a UID is only
  /// unique within one *incarnation* of a mailbox. When a server rebuilds one it
  /// issues a new UIDVALIDITY and starts UIDs again, so every cached row for
  /// that folder now names a different message — the same id, silently pointing
  /// somewhere else. Nothing detected that before: the STATUS reply carried
  /// UIDVALIDITY and it was discarded.
  ///
  /// The reading is persisted rather than kept in memory because the cache
  /// outlives the process: a rebuild while NightMail was closed is exactly the
  /// case an in-memory comparison cannot see. It goes in the delta-token store,
  /// which is already a keyed string of "where this folder's sync got to", under
  /// a suffixed key so it cannot collide with a real delta cursor.
  Future<void> _dropCacheForRebuiltImapFolders(
    String accountId,
    EmailRemoteDatasource ds,
  ) async {
    if (ds is! ImapDatasourceImpl) return;
    for (final entry in ds.folderStatuses.entries) {
      final uidValidity = entry.value.uidValidity;
      if (uidValidity == null) continue;
      final key = '${entry.key}$_uidValiditySuffix';
      final current = '$uidValidity';
      try {
        final stored = await _database.loadDeltaToken(accountId, key);
        if (stored == current) continue;
        if (stored != null) {
          debugPrint('[MailPoller] $accountId/${entry.key}: UIDVALIDITY '
              '$stored -> $current, mailbox was rebuilt — dropping its cache');
          await _emailLocalDatasource.clearCacheForFolder(
            accountId: accountId,
            folderId: entry.key,
          );
        }
        await _database.saveDeltaToken(accountId, key, current);
      } catch (e) {
        // Never fail a poll over this. Leaving the stored value alone means the
        // next cycle tries again rather than concluding all is well.
        debugPrint('[MailPoller] $accountId/${entry.key}: UIDVALIDITY check '
            'failed: $e');
      }
    }
  }

  /// Syncs one non-Inbox folder for the active account and returns whether
  /// anything about it changed.
  ///
  /// Deliberately count-driven rather than delta-driven even on Graph: this runs
  /// for whichever folder the user happens to be looking at, and minting a delta
  /// token per browsed folder would leave a growing pile of tokens to expire and
  /// recover. The Inbox — the one folder that is synced every cycle whether or
  /// not it is on screen — keeps the delta stream.
  Future<bool> _syncWatchedFolder({
    required Account account,
    required EmailRemoteDatasource ds,
    required String folderId,
    required List<
            ({
              String accountId,
              EmailRemoteDatasource datasource,
              List<Email> emails,
            })>
        prefetchJobs,
  }) async {
    final fresh =
        await ds.getEmails(folderId: folderId, top: _watchedPageSize);
    final reconciled = await _reconcileAgainstPendingOps(account.id, fresh);

    // Compared against the *cache* rather than a count, because there is no
    // per-folder count to compare for an arbitrary folder on every provider —
    // and because the page is already in hand, so the comparison is free.
    // Equality is Email's own, which now includes isFlagged, so a flag or
    // read-state change on another machine registers as a change.
    final cached = await _emailLocalDatasource.getCachedEmails(
      accountId: account.id,
      folderId: folderId,
    );
    final changed = !_samePage(cached, reconciled);

    await _emailLocalDatasource.cacheEmails(
      accountId: account.id,
      folderId: folderId,
      emails: reconciled,
      replaceFolder: true,
    );
    if (changed) {
      prefetchJobs.add((
        accountId: account.id,
        datasource: ds,
        emails: reconciled,
      ));
    }
    return changed;
  }

  /// Whether two pages are the same mail in the same state.
  ///
  /// Matched **by id, not by position**: the two lists do not arrive in the same
  /// order. A cached page comes back newest-first, while a provider's own listing
  /// is grouped by thread (Gmail returns each thread's messages together; Graph
  /// appends the cross-folder expansion after the folder's own rows). Comparing
  /// index against index therefore reported a change on every cycle for any
  /// folder holding a multi-message thread — i.e. every real mailbox.
  ///
  /// Compared on what a row *shows* rather than with `Email`'s own equality, for
  /// a second version of the same mistake: a cached row whose body has since
  /// been fetched carries the attachments that came with it, and a list
  /// projection carries none, so full equality also disagreed for ever — on
  /// precisely the messages the user reads most.
  static bool _samePage(List<Email> cached, List<Email> fresh) {
    if (cached.length < fresh.length) return false;
    final cachedRows = {for (final email in cached) email.id: _rowState(email)};
    for (final email in fresh) {
      if (cachedRows[email.id] != _rowState(email)) return false;
    }
    // The fetch is a full page but the cache holds fewer rows than a page —
    // nothing was dropped, so this is the same folder seen twice.
    return cached.length == fresh.length || fresh.length == _watchedPageSize;
  }

  /// Everything about a message a folder row draws, and nothing a list fetch
  /// cannot answer for. Records compare by value, so this is the comparison.
  ///
  /// Read state and the flag are in here deliberately: changing either on
  /// another machine has to register as a change, or the row would keep drawing
  /// the state this machine last saw.
  static (bool, bool, bool, int, String, String) _rowState(Email email) => (
        email.isRead,
        email.isFlagged,
        email.hasAttachments,
        email.receivedDateTime.millisecondsSinceEpoch,
        email.subject,
        email.from.address,
      );

  /// Counts a delta failure for one folder and, once the streak reaches
  /// [_maxDeltaFailuresBeforeReset], drops the account's tokens so the next
  /// cycle bootstraps from scratch.
  ///
  /// The status-coded cases are handled directly by the caller; this catches
  /// everything else — a parse that keeps failing, a repeated timeout, a
  /// transport error that always reproduces. Without it, any failure the
  /// status-code check does not recognise is permanent, because nothing else in
  /// the app ever clears a stored delta token.
  Future<void> _noteDeltaFailure(
    String accountId,
    String folderId,
    String reason,
  ) async {
    final key = _folderKey(accountId, folderId);
    final count = (_deltaFailures[key] ?? 0) + 1;
    _deltaFailures[key] = count;
    if (count < _maxDeltaFailuresBeforeReset) return;
    debugPrint('[MailPoller] $accountId/$folderId: $count consecutive delta '
        'failures ($reason) — dropping the token to force a re-bootstrap');
    _deltaFailures.remove(key);
    try {
      await _database.clearDeltaTokensForAccount(accountId);
    } catch (e) {
      debugPrint('[MailPoller] $accountId: could not clear delta tokens: $e');
    }
  }

  /// Performs the initial full delta sync for [accountId] to establish a delta
  /// token. Runs in the background so it does not block the poll cycle.
  Future<void> _bootstrapDeltaToken(
    String accountId,
    MailDeltaDatasource ds,
  ) async {
    if (_bootstrapping.contains(accountId)) return;
    _bootstrapping.add(accountId);
    try {
      final result = await ds.syncMailDelta('inbox');
      // The bootstrap fetch already pulled a first window of messages to
      // establish the delta token — cache them now instead of discarding,
      // so a fresh account is usable offline without a separate fetch.
      //
      // Before the token, for the same reason as the steady-state path: the
      // token is a receipt for changes we have applied, so persisting it ahead
      // of the write would lose them if the write failed.
      await _cacheUpserted(accountId, result.upserted);
      await _database.saveDeltaToken(accountId, 'inbox', result.deltaLink);
      _bootstrapFailures.remove(accountId);
      // The fresh delta snapshot reflects the inbox at this moment. The email
      // list cache may be stale (e.g. emails deleted before/during bootstrap),
      // so force a UI refresh now that we have a reliable baseline.
      if (!isClosed && accountId == _accountManager.activeAccount?.id) {
        emit(state.copyWith(pollGeneration: state.pollGeneration + 1));
      }
    } catch (e) {
      // The next cycle retries, because savedToken stays null. Counted and
      // logged because this runs unawaited from the poll loop, so its throw
      // never reaches the per-account handlers there — a bootstrap that fails
      // every time left the account in the no-token branch for good, where the
      // badge and folder counts moved but the message list never did.
      final count = (_bootstrapFailures[accountId] ?? 0) + 1;
      _bootstrapFailures[accountId] = count;
      debugPrint('[MailPoller] $accountId: delta bootstrap failed '
          '($count consecutive): $e');
      _errors[accountId] = 'delta bootstrap failed ($count consecutive): $e';
    } finally {
      _bootstrapping.remove(accountId);
    }
  }

  /// Groups [upserted] by their real server folder id (Graph messages carry
  /// `parentFolderId`) and writes each group into the cache. Delta syncs are
  /// scoped to a single well-known folder name (e.g. 'inbox'), which is not
  /// the same string as that folder's actual id used elsewhere for cache
  /// lookups/UI navigation — grouping by parentFolderId keeps cache keys
  /// consistent with what the email list reads.
  Future<void> _cacheUpserted(
    String accountId,
    List<Email> upserted, {
    String? inboxFolderId,
  }) async {
    if (upserted.isEmpty) return;
    final reconciled = await _reconcileAgainstPendingOps(accountId, upserted);
    final byFolder = <String, List<Email>>{};
    for (final email in reconciled) {
      // A delta item with no parentFolderId belongs to the folder the delta was
      // scoped to. Falling back to the literal 'inbox' filed it under a key the
      // email list never reads, so the row was cached and then invisible.
      final folderId =
          email.parentFolderId ?? inboxFolderId ?? _inboxWellKnownName;
      byFolder.putIfAbsent(folderId, () => []).add(email);
    }
    for (final entry in byFolder.entries) {
      await _emailLocalDatasource.cacheEmails(
        accountId: accountId,
        folderId: entry.key,
        emails: entry.value,
      );
    }
  }

  /// Applies delta items that named only the properties that changed to the
  /// cached rows they belong to — see [MailDeltaFieldUpdate] for why they must
  /// not travel with the upserts.
  ///
  /// An update for a message that is not cached is dropped: there is no row to
  /// change, and a partial item never carries enough to build one. The next
  /// full fetch of that folder brings the message down whole.
  Future<void> _applyFieldUpdates(
    String accountId,
    List<MailDeltaFieldUpdate> updates,
  ) async {
    if (updates.isEmpty) return;
    final pending = await _pendingMutations(accountId);

    for (final update in updates) {
      if (pending.tombstoned.contains(update.id)) continue;
      await _emailLocalDatasource.updateCachedEmailFields(
        accountId: accountId,
        emailId: update.id,
        // A queued markRead has not reached the server yet, so the server's
        // isRead is the value this app is about to replace — applying it would
        // flip the row back to what the user just changed it from.
        isRead: pending.pendingReadIds.contains(update.id) ? null : update.isRead,
        isFlagged: update.isFlagged,
      );
    }
  }

  /// The ids this account has mutations queued against: [tombstoned] is being
  /// removed from view (delete/move/junk, plus removals that have drained but
  /// whose tombstone is still live), [pendingReadIds] has a read-state change
  /// the server has not been told about yet.
  ///
  /// Shared by both reconciliation paths here so they cannot drift apart.
  Future<({Set<String> tombstoned, Set<String> pendingReadIds})>
      _pendingMutations(String accountId) async {
    final pendingOps = await _pendingOperations.getPendingOperations(accountId);
    // Recently-removed tombstones outlive op dequeue, closing the race where a
    // server snapshot built before the mutation propagated resolves after the
    // outbox drain removed the pending op. Shared with EmailRepositoryImpl so
    // both reconciliation paths agree; matters most for a multi-message action
    // like deleting a whole thread, whose ops drain one at a time.
    final recentlyRemovedIds = _removalTombstones.activeIds(accountId);

    return (
      tombstoned: <String>{
        for (final op in pendingOps)
          if (op.opType == PendingOperationType.delete ||
              op.opType == PendingOperationType.move ||
              op.opType == PendingOperationType.junk)
            op.emailId,
        ...recentlyRemovedIds,
      },
      pendingReadIds: <String>{
        for (final op in pendingOps)
          if (op.opType == PendingOperationType.markRead) op.emailId,
      },
    );
  }

  /// Reconciles freshly-synced server data against mutations still sitting
  /// in the outbox for this account. drainAll() runs before every poll
  /// cycle, so this mainly guards a narrow window — a mutation queued after
  /// that drain but before this fetch completed — rather than the common
  /// case, but a stale server snapshot winning that race would otherwise
  /// resurrect a message the user just deleted/moved, or flip a just-marked
  /// -read message back to unread, until the next poll tick papers over it.
  ///
  /// - A message with a pending delete/move/junk op is dropped outright
  ///   (tombstoned) — it's being removed from this view and re-caching it
  ///   would put it right back.
  /// - A message with a pending markRead op keeps whatever isRead value is
  ///   already in the cache rather than the server's (not-yet-updated) one.
  Future<List<Email>> _reconcileAgainstPendingOps(
    String accountId,
    List<Email> emails,
  ) async {
    final (:tombstoned, :pendingReadIds) = await _pendingMutations(accountId);
    if (tombstoned.isEmpty && pendingReadIds.isEmpty) return emails;

    final reconciled = <Email>[];
    for (final email in emails) {
      if (tombstoned.contains(email.id)) continue;
      if (pendingReadIds.contains(email.id)) {
        final cached = await _emailLocalDatasource.getCachedEmailById(
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

  void decrementUnreadCount() {
    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null) return;
    final current = _latestPolledUnread[accountId] ?? 0;
    if (current > 0) _latestPolledUnread[accountId] = current - 1;
    final total = _latestPolledUnread.values.fold(0, (sum, n) => sum + n);
    unawaited(_badgeService.setBadgeCount(total));
  }

  void incrementUnreadCount() {
    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null) return;
    final current = _latestPolledUnread[accountId] ?? 0;
    _latestPolledUnread[accountId] = current + 1;
    final total = _latestPolledUnread.values.fold(0, (sum, n) => sum + n);
    unawaited(_badgeService.setBadgeCount(total));
  }

  void updateBadgeFromFolders(int inboxUnreadCount) {
    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null) return;
    _latestPolledUnread[accountId] = inboxUnreadCount;
    final total = _latestPolledUnread.values.fold(0, (sum, n) => sum + n);
    unawaited(_badgeService.setBadgeCount(total));
  }

  void markAccountViewed(String accountId) {
    _newMailAccounts.remove(accountId);
    _baselineUnread[accountId] = _latestPolledUnread[accountId] ?? 0;
    if (!isClosed) {
      emit(state.copyWith(accountsWithNewMail: Set.of(_newMailAccounts)));
    }
  }

  Future<void> updatePollInterval(int seconds) async {
    await _appSettings.savePollIntervalSeconds(seconds);
    if (!isClosed) emit(state.copyWith(pollIntervalSeconds: seconds));
    _startTimer(seconds);
  }

  @override
  Future<void> close() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _reconnectSub?.cancel();
    for (final sub in _idleSubs.values) {
      sub.cancel();
    }
    _idleSubs.clear();
    return super.close();
  }
}
