import 'dart:convert';

import '../../data/datasources/local/pending_operations_datasource.dart';
import '../../data/datasources/remote/spam_db_sync_datasource.dart';
import '../../domain/repositories/spam_filter_repository.dart';

/// Sentinel emailId for queued [PendingOperationType.spamDbPush] ops — the
/// push isn't tied to a real message, but the pending-operations schema
/// requires an emailId.
const _spamDbSentinelId = '__spamdb__';

/// Syncs the client-side Bayesian spam filter (see [SpamFilterRepository])
/// across IMAP clients via the SPAMDB folder (see [SpamDbSyncDatasource]).
///
/// Conflict resolution is last-write-wins: [pullForAccount] replaces local
/// state wholesale with whatever is newest on the server, and
/// [pushForAccount] always reads the server's current version fresh (not a
/// cached one) before writing, so a stale in-memory cache after an app
/// restart can't regress the version number.
///
/// [pushForAccount] is only ever called by [OutboxDrainService] — never
/// directly by callers — because it shares the one live IMAP connection
/// (`ImapDatasourceImpl`) with every other queued mutation. That connection
/// has no per-operation locking, so a SELECT+operate pair for SPAMDB running
/// unawaited alongside another flow's SELECT+operate for INBOX could apply
/// the wrong operation to the wrong mailbox. Routing the push through
/// [enqueuePush] and the outbox's strictly-sequential per-account drain is
/// what keeps it from ever overlapping another mutation on that connection.
class SpamDbSyncService {
  SpamDbSyncService({
    required SpamFilterRepository spamFilterRepository,
    required PendingOperationsDatasource pendingOperations,
  })  : _spamFilterRepository = spamFilterRepository,
        _pendingOperations = pendingOperations;

  final SpamFilterRepository _spamFilterRepository;
  final PendingOperationsDatasource _pendingOperations;

  /// Queues a push of the local spam filter for [accountId], to be drained
  /// (via [pushForAccount]) by [OutboxDrainService] alongside this account's
  /// other pending mutations. No-ops if a push is already queued — only the
  /// latest local state matters, so there's no point stacking more than one.
  Future<void> enqueuePush(String accountId) async {
    final pending = await _pendingOperations.getPendingOperations(accountId);
    if (pending.any((op) => op.opType == PendingOperationType.spamDbPush)) {
      return;
    }
    await _pendingOperations.enqueue(
      accountId: accountId,
      emailId: _spamDbSentinelId,
      opType: PendingOperationType.spamDbPush,
      payload: '{}',
    );
  }

  /// The last remote version successfully pulled per account — purely an
  /// optimization to skip a redundant download when nothing changed since
  /// the last poll. Resetting on app restart just costs one extra download,
  /// not a correctness issue.
  final Map<String, int> _lastAppliedVersion = {};

  /// Pulls the remote spam DB for [accountId] if it's newer than what was
  /// last applied. Safe to call every poll tick — errors are swallowed so a
  /// sync hiccup never breaks the poll loop.
  Future<void> pullForAccount(String accountId, SpamDbSyncDatasource ds) async {
    try {
      final remoteVersion = await ds.peekSpamDbVersion();
      if (remoteVersion == null) return;
      if (remoteVersion == _lastAppliedVersion[accountId]) return;

      final payload = await ds.downloadSpamDbPayload();
      if (payload == null) return;

      // MIME transport (line-folding, a trailing newline the server or a
      // relay adds) can introduce whitespace into the body text; base64
      // decoding throws on anything but the alphabet, so strip it first
      // rather than let a cosmetic transport artifact silently break sync.
      final clean = payload.replaceAll(RegExp(r'\s'), '');
      final json = jsonDecode(utf8.decode(base64.decode(clean)))
          as Map<String, dynamic>;
      await _spamFilterRepository.importState(accountId, json);
      _lastAppliedVersion[accountId] = remoteVersion;
    } catch (_) {
      // Retried on the next poll tick.
    }
  }

  /// Pushes the local spam filter for [accountId] up to the server,
  /// superseding whatever version is currently there. Call after training
  /// has actually written the new state (e.g. after a junk report) — not
  /// concurrently with it, or this can push a stale export.
  Future<void> pushForAccount(String accountId, SpamDbSyncDatasource ds) async {
    try {
      final serverVersion = await ds.peekSpamDbVersion() ?? 0;
      final newVersion = serverVersion + 1;

      final state = await _spamFilterRepository.exportState(accountId);
      final payload = base64.encode(utf8.encode(jsonEncode(state)));

      await ds.pushSpamDb(version: newVersion, payload: payload);
      _lastAppliedVersion[accountId] = newVersion;
    } catch (_) {
      // A future push (next junk report) will retry with a fresh server
      // version, so a transient failure here is not fatal.
    }
  }
}
