import 'package:flutter/foundation.dart';

import '../../data/datasources/local/delta_token_datasource.dart';
import '../../data/datasources/local/email_local_datasource.dart';
import '../accounts/account_manager.dart';

/// Puts back the folder memberships lost by caches written before a message
/// could be filed under more than one folder.
///
/// Both providers expand a folder page with the same thread's copies from other
/// folders, and the whole page is cached under the folder being listed. While a
/// cached message could only be in one folder, that write *moved* those copies —
/// so listing any folder emptied every other folder's cache of the mail they
/// shared a thread with, and an Inbox of a dozen long-running threads could
/// drain to whatever the last delta had added.
///
/// The rows were never lost, only misfiled, and each one carries its own folder
/// inside the encrypted payload. This runs once per account to file them back.
/// Without it a folder repairs itself the first time it is listed from the
/// network — which is the same "it filled in after a refresh" the misfiling
/// caused, once per folder.
class CacheMembershipRepairService {
  CacheMembershipRepairService({
    required AccountManager accountManager,
    required EmailLocalDatasource emailLocalDatasource,
    required DeltaTokenDatasource deltaTokens,
  })  : _accountManager = accountManager,
        _local = emailLocalDatasource,
        _deltaTokens = deltaTokens;

  final AccountManager _accountManager;
  final EmailLocalDatasource _local;
  final DeltaTokenDatasource _deltaTokens;

  /// Sentinel account id the "already repaired" markers are filed under, with
  /// the real account id as the key.
  ///
  /// Deliberately *not* the account's own id: `clearDeltaTokensForAccount`
  /// drops every row an account owns whenever a delta stream has to be
  /// re-bootstrapped, which would take the marker with it and make the pass run
  /// again on the next launch. No account id can collide with this one.
  static const _markerAccountId = '__cache_membership_repair__';

  /// Marker value. Recorded per account rather than once for the app, so an
  /// account added later is repaired too — its cache may have been written by
  /// an older build.
  static const _done = 'done';

  /// Repairs every configured account that has not been repaired yet.
  ///
  /// Best-effort: a failure is logged and left for the next launch, because the
  /// only thing at stake is how quickly a folder's cache fills in.
  Future<void> repairAll() async {
    for (final account in _accountManager.accounts) {
      try {
        await repairAccount(account.id);
      } catch (e) {
        debugPrint('[CacheRepair] ${account.id}: skipped — $e');
      }
    }
  }

  /// Repairs one account, or does nothing if it has been repaired already.
  Future<void> repairAccount(String accountId) async {
    final marker = await _deltaTokens.loadDeltaToken(_markerAccountId, accountId);
    if (marker == _done) return;

    final added = await _local.restoreFolderMemberships(accountId: accountId);
    // Written after the rows, for the same reason a delta link is: the marker
    // is a receipt for work that has landed, and saving it first would skip the
    // repair for good if the write below never happened.
    await _deltaTokens.saveDeltaToken(_markerAccountId, accountId, _done);
    if (added > 0) {
      debugPrint('[CacheRepair] $accountId: filed $added cached '
          'message(s) back under their own folder');
    }
  }
}
