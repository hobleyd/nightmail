import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/datasources/local/contact_cache_local_datasource.dart';
import '../../data/datasources/local/contact_cache_local_datasource_impl.dart'
    show systemContactsAccountId;
import '../../data/datasources/remote/contact_bulk_parser.dart';
import '../../domain/entities/cached_contact.dart';
import '../../domain/repositories/system_contacts_repository.dart';
import '../accounts/account.dart';
import '../accounts/account_manager.dart';

/// Keeps the local address-book cache that backs the recipient typeahead
/// up to date.
///
/// The typeahead used to hit the provider's contact APIs and the OS address
/// book on every keystroke, which made the dropdown slow. Instead the whole
/// address book for every account is pulled down at most once a day and
/// queried locally from an indexed SQLite table.
///
/// Where the work happens:
///  * Network I/O runs on the calling isolate but is pure async socket
///    work — it never occupies the UI thread.
///  * JSON decoding and normalising, which is the part that actually janks
///    (a large tenant directory is tens of thousands of people), is handed to
///    `compute()`.
///  * The SQL writes go to drift, which `drift_flutter` already hosts on its
///    own background isolate via `NativeDatabase.createBackgroundConnection`.
class ContactCacheSyncService {
  ContactCacheSyncService({
    required AccountManager accountManager,
    required ContactCacheLocalDatasource cache,
    required SystemContactsRepository systemContacts,
  })  : _accountManager = accountManager,
        _cache = cache,
        _systemContacts = systemContacts;

  final AccountManager _accountManager;
  final ContactCacheLocalDatasource _cache;
  final SystemContactsRepository _systemContacts;

  /// How long a clean sync stays fresh — the "once per day" refresh.
  static const refreshInterval = Duration(hours: 24);

  /// Retry delay after a failed or partial sync. Shorter than
  /// [refreshInterval] so a transient outage or a token that was refreshed in
  /// the meantime doesn't leave the cache thin for a whole day.
  static const retryInterval = Duration(hours: 1);

  /// How often a long-running desktop session re-checks staleness. The app can
  /// stay open for days, so relying on the startup sync alone would never hit
  /// the daily refresh.
  static const _tickInterval = Duration(hours: 6);

  Timer? _timer;

  /// One entry per in-flight account sync, so overlapping triggers (startup +
  /// timer + an account being re-authenticated) collapse into a single fetch
  /// instead of hammering the provider.
  final Map<String, Future<void>> _inFlight = {};

  /// Refreshes every account whose cache is stale, plus the OS address book,
  /// and drops slices for accounts that have since been removed.
  ///
  /// Never throws: a failure in one account is recorded against that account
  /// and the rest continue.
  Future<void> syncAll({bool force = false}) async {
    final accounts = _accountManager.accounts;
    await Future.wait([
      for (final account in accounts) syncAccount(account.id, force: force),
      syncSystemContacts(force: force),
    ]);
    await _pruneRemovedAccounts(accounts);
  }

  /// Refreshes one account's contacts if stale (or [force]d). Safe to call
  /// concurrently with itself — the second caller awaits the first.
  Future<void> syncAccount(String accountId, {bool force = false}) {
    final existing = _inFlight[accountId];
    if (existing != null) return existing;
    final run = _syncAccount(accountId, force: force)
        .whenComplete(() => _inFlight.remove(accountId));
    _inFlight[accountId] = run;
    return run;
  }

  /// Refreshes the OS address book, which is shared across accounts and so is
  /// cached under its own sentinel id.
  Future<void> syncSystemContacts({bool force = false}) {
    final existing = _inFlight[systemContactsAccountId];
    if (existing != null) return existing;
    final run = _syncSystemContacts(force: force)
        .whenComplete(() => _inFlight.remove(systemContactsAccountId));
    _inFlight[systemContactsAccountId] = run;
    return run;
  }

  /// Discards an account's cached contacts and refetches them now. Called
  /// after a re-authentication, where the point is usually that newly granted
  /// scopes have opened up a source that was 403ing.
  Future<void> invalidateAccount(String accountId) async {
    await _cache.clearAccount(accountId);
    await syncAccount(accountId, force: true);
  }

  /// Drops an account's contacts without refetching — for an account the user
  /// has removed.
  Future<void> clearAccount(String accountId) => _cache.clearAccount(accountId);

  /// Starts the staleness re-check for long-running sessions. Idempotent.
  void startPeriodicRefresh() {
    _timer ??= Timer.periodic(_tickInterval, (_) {
      unawaited(syncAll().catchError(
        (Object e) => debugPrint('[Contacts] periodic sync failed: $e'),
      ));
    });
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  // --- internals ------------------------------------------------------------

  Future<void> _syncAccount(String accountId, {required bool force}) async {
    if (!force && !await _isStale(accountId)) return;

    final account = _accountManager.accountById(accountId);
    if (account == null) return;

    try {
      switch (account) {
        case GmailAccount():
          await _syncGmail(accountId);
        case MicrosoftAccount():
          await _syncMicrosoft(accountId);
        case ImapAccount():
          // Plain IMAP exposes no directory or address book. Recording a clean,
          // empty sync (rather than leaving the account unsynced) is what stops
          // the typeahead from retrying a live lookup on every keystroke —
          // suggestions for these accounts come from known senders, which are
          // queried separately and are always current.
          await _cache.replaceForAccount(
            accountId: accountId,
            contacts: const [],
            status: 'ok',
            detail: 'IMAP has no server-side address book; '
                'suggestions come from previously seen senders',
          );
      }
    } catch (e) {
      debugPrint('[Contacts] sync failed for $accountId: $e');
      await _cache.markSyncFailed(accountId: accountId, detail: e.toString());
    }
  }

  Future<void> _syncGmail(String accountId) async {
    final ds = _accountManager.contactsDatasourceForAccount(accountId);
    if (ds == null) {
      await _cache.markSyncFailed(
        accountId: accountId,
        detail: 'no People API datasource for account',
      );
      return;
    }
    final fetched = await ds.fetchAllContacts();
    final contacts =
        await compute(parseGooglePeoplePages, fetched.data);
    await _store(accountId, contacts, fetched);
  }

  Future<void> _syncMicrosoft(String accountId) async {
    final ds = _accountManager.directoryDatasourceForAccount(accountId);
    if (ds == null) {
      await _cache.markSyncFailed(
        accountId: accountId,
        detail: 'no Graph datasource for account',
      );
      return;
    }
    final fetched = await ds.fetchAllContacts();
    final contacts = await compute(parseGraphContactPages, fetched.data);
    await _store(accountId, contacts, fetched);
  }

  Future<void> _syncSystemContacts({required bool force}) async {
    if (!await _systemContacts.isAvailable()) return;
    if (!force && !await _isStale(systemContactsAccountId)) return;

    try {
      final raw = await _systemContacts.fetchAll();
      final contacts = await compute(
        parseSystemContacts,
        [
          for (final c in raw)
            {'address': c.address, 'name': c.name ?? ''},
        ],
      );
      if (contacts.isEmpty) {
        // An address book that enumerates to nothing is far more likely to be a
        // permissions or TCC problem than a genuinely empty one, so don't let
        // it overwrite contacts cached from an earlier, working run.
        await _cache.markSyncFailed(
          accountId: systemContactsAccountId,
          detail: 'OS address book returned no contacts',
        );
        return;
      }
      await _cache.replaceForAccount(
        accountId: systemContactsAccountId,
        contacts: contacts,
        status: 'ok',
      );
      debugPrint('[Contacts] cached ${contacts.length} OS contacts');
    } catch (e) {
      debugPrint('[Contacts] system contacts sync failed: $e');
      await _cache.markSyncFailed(
        accountId: systemContactsAccountId,
        detail: e.toString(),
      );
    }
  }

  /// Writes a fetched address book, unless the fetch produced nothing *and*
  /// something went wrong — in that case the previous, better cache is kept
  /// and the failure recorded for a retry on the shorter [retryInterval].
  Future<void> _store(
    String accountId,
    List<CachedContact> contacts,
    BulkFetchResult<Object?> fetched,
  ) async {
    if (contacts.isEmpty && !fetched.isComplete) {
      await _cache.markSyncFailed(
        accountId: accountId,
        detail: fetched.detail ?? 'all contact sources failed',
      );
      return;
    }
    await _cache.replaceForAccount(
      accountId: accountId,
      contacts: contacts,
      status: fetched.isComplete ? 'ok' : 'partial',
      detail: fetched.detail,
    );
    final note = fetched.detail;
    debugPrint(
      '[Contacts] cached ${contacts.length} contacts for $accountId'
      '${note == null ? '' : ' (partial — $note)'}',
    );
  }

  Future<bool> _isStale(String accountId) async {
    final status = await _cache.syncStatus(accountId);
    if (status == null) return true;
    final age = DateTime.now().difference(status.syncedAt);
    // A clock that jumped backwards would otherwise make a stale cache look
    // fresh forever, so treat a negative age as stale.
    if (age.isNegative) return true;
    return age >= (status.isClean ? refreshInterval : retryInterval);
  }

  Future<void> _pruneRemovedAccounts(List<Account> accounts) async {
    try {
      final live = {
        for (final a in accounts) a.id,
        systemContactsAccountId,
      };
      final cached = await _cache.cachedAccountIds();
      for (final id in cached.where((id) => !live.contains(id))) {
        await _cache.clearAccount(id);
        debugPrint('[Contacts] dropped cache for removed account $id');
      }
    } catch (e) {
      debugPrint('[Contacts] prune failed: $e');
    }
  }
}
