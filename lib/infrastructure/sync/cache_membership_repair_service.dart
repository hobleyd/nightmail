import 'package:flutter/foundation.dart';

import '../../data/datasources/local/delta_token_datasource.dart';
import '../../data/datasources/local/email_local_datasource.dart';
import '../../data/datasources/local/folder_local_datasource.dart';
import '../accounts/account_manager.dart';

/// Repairs what earlier builds left in the message cache, once per account.
///
/// Two passes, each with its own marker so adding one does not re-run the
/// other, and each best-effort: the only thing at stake is how quickly a
/// folder's cache is right, and a failure is left for the next launch.
///
/// **Restoring folder memberships.** Puts back the memberships lost by caches
/// written before a message could be filed under more than one folder.
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
///
/// **Pruning foreign folder rows.** Drops rows filed under a folder id
/// belonging to *another account*, which an account switch used to let through:
/// `AccountManager.activeAccount` flips before `AccountCubit` emits, so a fetch
/// in that window addressed the arriving account with the departing one's
/// folder id and cached the answer under it. Nothing lists those rows — but
/// `EmailListBloc._repaintFromCache` could still *find* them, which is what
/// made the write worth undoing rather than leaving inert. Fixed at the source;
/// this is the residue.
///
/// That pass needs an authority on which folders an account really has, and the
/// cached folder tree is it. An account whose tree has not been cached yet is
/// skipped **without** its marker, because a pass that pruned nothing against
/// an unknown tree has not run — marking it would make "we could not tell" look
/// like "there was nothing to do", for good.
class CacheMembershipRepairService {
  CacheMembershipRepairService({
    required AccountManager accountManager,
    required EmailLocalDatasource emailLocalDatasource,
    required FolderLocalDatasource folderLocalDatasource,
    required DeltaTokenDatasource deltaTokens,
  })  : _accountManager = accountManager,
        _local = emailLocalDatasource,
        _folders = folderLocalDatasource,
        _deltaTokens = deltaTokens;

  final AccountManager _accountManager;
  final EmailLocalDatasource _local;
  final FolderLocalDatasource _folders;
  final DeltaTokenDatasource _deltaTokens;

  /// Sentinel account id the "already repaired" markers are filed under, with
  /// the real account id as the key.
  ///
  /// Deliberately *not* the account's own id: `clearDeltaTokensForAccount`
  /// drops every row an account owns whenever a delta stream has to be
  /// re-bootstrapped, which would take the marker with it and make the pass run
  /// again on the next launch. No account id can collide with this one.
  static const _markerAccountId = '__cache_membership_repair__';

  /// The same, for the foreign-folder prune. Its own sentinel: the two passes
  /// arrived in different releases, so an install that has run one has not
  /// necessarily run the other.
  static const _pruneMarkerAccountId = '__foreign_folder_prune__';

  /// Marker value. Recorded per account rather than once for the app, so an
  /// account added later is repaired too — its cache may have been written by
  /// an older build.
  static const _done = 'done';

  /// Runs both passes over every configured account that has not had them yet.
  ///
  /// Best-effort: a failure is logged and left for the next launch, because the
  /// only thing at stake is how quickly a folder's cache is right. Each pass is
  /// caught separately, so one failing does not cost the account the other.
  Future<void> repairAll() async {
    for (final account in _accountManager.accounts) {
      try {
        await repairAccount(account.id);
      } catch (e) {
        debugPrint('[CacheRepair] ${account.id}: skipped — $e');
      }
      try {
        await pruneForeignFoldersForAccount(account.id);
      } catch (e) {
        debugPrint('[CacheRepair] ${account.id}: prune skipped — $e');
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

  /// Drops one account's rows filed under another account's folder id, or does
  /// nothing if it has been pruned already — or if this account has no cached
  /// folder tree to judge them against.
  Future<void> pruneForeignFoldersForAccount(String accountId) async {
    final marker =
        await _deltaTokens.loadDeltaToken(_pruneMarkerAccountId, accountId);
    if (marker == _done) return;

    final folders = await _folders.getCachedFolders(accountId);
    if (folders.isEmpty) {
      // Not marked: see the class doc. The next launch, by which point the
      // folder list will have been cached, tries again.
      debugPrint('[CacheRepair] $accountId: prune deferred — '
          'no cached folder list to compare against');
      return;
    }

    final removed = await _local.pruneForeignFolderRows(
      accountId: accountId,
      knownFolderIds: {for (final folder in folders) folder.id},
    );
    // After the rows, for the same reason the marker above is: it is a receipt
    // for work that has landed.
    await _deltaTokens.saveDeltaToken(_pruneMarkerAccountId, accountId, _done);
    if (removed > 0) {
      debugPrint('[CacheRepair] $accountId: dropped $removed cached row(s) '
          'filed under another account\'s folder');
    }
  }
}
