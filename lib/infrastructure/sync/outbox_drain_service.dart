import 'dart:convert';

import '../../data/datasources/local/email_local_datasource.dart';
import '../../data/datasources/local/pending_operations_datasource.dart';
import '../accounts/account.dart';
import '../accounts/account_manager.dart';

/// Replays queued mutations (see [PendingOperationsDatasource]) against the
/// server so an offline/optimistic mutation eventually reaches the mailbox.
///
/// Operations for an account are drained strictly in the order they were
/// queued, one at a time. This is deliberate, not just simple: a move
/// followed by another op on the same message (e.g. mark-read-then-move)
/// must see the first op's outcome — including a possible id change — before
/// the second is sent. Draining out of order, or in parallel, risks sending
/// a later op against an id the server has already replaced. On a failure,
/// only the remaining queued ops *for that same message* are skipped this
/// pass (left queued, retried next call) — a single permanently-failing op
/// (e.g. a move to a folder that no longer exists) must not head-of-line
/// block every other message's unrelated mutations.
class OutboxDrainService {
  OutboxDrainService({
    required PendingOperationsDatasource pendingOperations,
    required EmailLocalDatasource localDatasource,
    required AccountManager accountManager,
  })  : _pendingOperations = pendingOperations,
        _localDatasource = localDatasource,
        _accountManager = accountManager;

  final PendingOperationsDatasource _pendingOperations;
  final EmailLocalDatasource _localDatasource;
  final AccountManager _accountManager;

  /// Drains every account's outbox. Safe to call opportunistically (app
  /// start, poll tick, network-restored) — accounts with an empty queue
  /// return immediately.
  Future<void> drainAll() async {
    for (final account in _accountManager.accounts) {
      await drainForAccount(account.id);
    }
  }

  Future<void> drainForAccount(String accountId) async {
    Account? account;
    for (final a in _accountManager.accounts) {
      if (a.id == accountId) {
        account = a;
        break;
      }
    }
    if (account == null) return;

    final ds = _accountManager.buildEmailDatasourceForAccount(account);
    final ops = await _pendingOperations.getPendingOperations(accountId);

    // The whole batch is fetched once up front, so a remap applied mid-loop
    // (op.emailId in the fetched list is a snapshot) wouldn't reach a later
    // op for the same message unless resolved through this map — it mirrors
    // the rewrite persisted to the DB via remapEmailId for anything not yet
    // drained this pass.
    final idRemap = <String, String>{};

    // Messages whose op chain hit a failure this pass — keyed by the
    // *original* queued emailId, same as [idRemap]. Remaining ops for that
    // message are skipped (left queued) without touching other messages.
    final quarantined = <String>{};

    for (final op in ops) {
      if (quarantined.contains(op.emailId)) continue;
      final emailId = idRemap[op.emailId] ?? op.emailId;
      try {
        switch (op.opType) {
          case PendingOperationType.delete:
            await ds.deleteEmail(emailId);

          case PendingOperationType.move:
            final payload = jsonDecode(op.payload) as Map<String, dynamic>;
            final destinationFolderId =
                payload['destinationFolderId'] as String;
            final newId = await ds.moveEmail(emailId, destinationFolderId);
            await _remapIfNeeded(accountId, emailId, newId, destinationFolderId);
            // Keyed by the *original* queued id (not the already-resolved
            // emailId) so a message remapped twice in one pass still
            // resolves to its final id via this single lookup.
            if (newId != null && newId != emailId) idRemap[op.emailId] = newId;

          case PendingOperationType.junk:
            final newId = await ds.reportJunk(emailId);
            await _remapIfNeeded(accountId, emailId, newId, 'junkemail');
            if (newId != null && newId != emailId) idRemap[op.emailId] = newId;

          case PendingOperationType.markRead:
            final payload = jsonDecode(op.payload) as Map<String, dynamic>;
            await ds.updateEmailReadStatus(
              id: emailId,
              isRead: payload['isRead'] as bool,
            );

          case PendingOperationType.emptyFolder:
            final payload = jsonDecode(op.payload) as Map<String, dynamic>;
            await ds.emptyFolder(
              op.folderId!,
              permanentDelete: payload['permanentDelete'] as bool? ?? false,
            );
        }
        await _pendingOperations.removeOperation(op.id);
      } catch (e) {
        await _pendingOperations.recordFailure(id: op.id, error: e.toString());
        quarantined.add(op.emailId);
      }
    }
  }

  Future<void> _remapIfNeeded(
    String accountId,
    String oldId,
    String? newId,
    String newFolderId,
  ) async {
    // Unknown new id (e.g. IMAP, which doesn't currently report the UID a
    // move assigns) — leave the cache row and any queued ops alone rather
    // than guess. The next full folder sync will reconcile it.
    if (newId == null) return;
    if (newId != oldId) {
      await _pendingOperations.remapEmailId(
        accountId: accountId,
        oldEmailId: oldId,
        newEmailId: newId,
      );
    }
    // Still relocate the cache row to the new folder even when the id is
    // unchanged (Gmail: a label change keeps the same message id).
    await _localDatasource.renameCachedEmailId(
      accountId: accountId,
      oldEmailId: oldId,
      newEmailId: newId,
      newFolderId: newFolderId,
    );
  }
}
