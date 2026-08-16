import 'dart:async';

import 'package:equatable/equatable.dart';

import '../../core/error/exceptions.dart';
import '../../core/utils/special_folder_kind.dart';
import '../../data/datasources/local/migration_local_datasource.dart';
import '../../data/datasources/remote/email_remote_datasource.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_folder.dart';
import '../accounts/account.dart';
import '../accounts/account_manager.dart';
import '../network/connectivity_service.dart';
import '../sync/imap_connection_gate.dart';

/// Live, in-memory progress for a running job's current folder — what the
/// status dialog's spinner shows while a job is actually running. Not
/// persisted: resumability is the ledger's job (see [MigrationLocalDatasource]
/// ), this is just UI feedback, so it's fine for an app restart to lose it —
/// a resumed job re-derives it as soon as its first folder starts.
class MigrationProgress extends Equatable {
  const MigrationProgress({
    required this.folderName,
    required this.processedCount,
    required this.totalCount,
  });

  final String folderName;

  /// Messages this folder pass has reached so far — every message the
  /// pass has looked at, whether it needed copying or was already
  /// ledgered done/failed from a prior run.
  final int processedCount;

  /// The folder's own item count at the time this pass started, or null
  /// when the provider didn't supply one (Gmail's virtual path-segment
  /// folders stay at 0, which reads as "unknown" here rather than a bogus
  /// "12 / 0"). Not a promise of an exact message count — some of those
  /// items are typically already ledgered done and count as processed
  /// instantly.
  final int? totalCount;

  @override
  List<Object?> get props => [folderName, processedCount, totalCount];
}

/// Copies every email from one account's mailboxes into the matching
/// mailboxes of another account — see the Migrate Account feature. Copy
/// only: the source is never modified, so the user can keep using it
/// (including deleting mail) for the whole, possibly multi-hour, run.
///
/// Modeled on [OutboxDrainService]: a per-(source,target) in-flight chain so
/// concurrent start/resume calls serialize rather than race each other, and
/// a persisted per-message ledger ([MigrationLocalDatasource]) that is both
/// the resume checkpoint and the duplicate-copy guard. Runs as a plain async
/// loop on the main isolate — not a spawned `Isolate` — because a multi-hour
/// job needs working token refresh, and that lives in this isolate's `get_it`
/// graph; a spawned isolate gets its own service locator and cannot reach it.
class AccountMigrationService {
  AccountMigrationService({
    required AccountManager accountManager,
    required MigrationLocalDatasource localDatasource,
    required ImapConnectionGate imapConnectionGate,
    required ConnectivityService connectivityService,
  })  : _accountManager = accountManager,
        _localDatasource = localDatasource,
        _imapConnectionGate = imapConnectionGate,
        _connectivityService = connectivityService;

  final AccountManager _accountManager;
  final MigrationLocalDatasource _localDatasource;
  final ImapConnectionGate _imapConnectionGate;
  final ConnectivityService _connectivityService;

  /// Total attempts (including ones recorded on a previous run) before a
  /// message is marked permanently failed — "retried, but if it fails again
  /// reported on" reads as a small fixed cap, not indefinite retry.
  static const _maxMessageAttempts = 3;
  static const _pageSize = 50;

  /// Chains concurrent [startOrResume] calls for the same account pair —
  /// same reasoning as `OutboxDrainService._inFlight`: callers (the account
  /// menu, [resumeAll] at startup) don't coordinate with each other.
  final Map<String, Future<void>> _inFlight = {};

  /// Keyed the same as [_inFlight] — see [MigrationProgress].
  final Map<String, MigrationProgress> _progress = {};

  static String jobIdFor(String sourceAccountId, String targetAccountId) =>
      '$sourceAccountId|$targetAccountId';

  /// The current folder and how far through it a running job's latest pass
  /// has reached — null before the first folder of a run has started.
  MigrationProgress? getProgress(
          String sourceAccountId, String targetAccountId) =>
      _progress[jobIdFor(sourceAccountId, targetAccountId)];

  /// Starts a new migration or resumes an existing one for this account
  /// pair. Safe to call repeatedly: a job already `running`/`paused` just
  /// gets its worker re-kicked; a `completed` job re-scans for source mail
  /// added since and retries any prior failures against the same ledger.
  Future<void> startOrResume(String sourceAccountId, String targetAccountId) {
    final id = jobIdFor(sourceAccountId, targetAccountId);
    final prior = _inFlight[id] ?? Future.value();
    final next = prior
        .then((_) => _run(sourceAccountId, targetAccountId))
        .catchError((_) {});
    _inFlight[id] = next;
    return next;
  }

  bool _resumedOnce = false;

  /// Resumes every job left `running`/`paused` from a prior session. Called
  /// from `HomePage.build` (main window only), which rebuilds more than
  /// once — guarded so only the first call actually queries and kicks off
  /// resumable jobs.
  Future<void> resumeAll() async {
    if (_resumedOnce) return;
    _resumedOnce = true;
    final jobs = await _localDatasource.getResumableJobs();
    for (final job in jobs) {
      unawaited(startOrResume(job.sourceAccountId, job.targetAccountId));
    }
  }

  Future<MigrationJobRecord?> getJob(
          String sourceAccountId, String targetAccountId) =>
      _localDatasource.getJob(jobIdFor(sourceAccountId, targetAccountId));

  /// The one job currently `running` or `paused` for [sourceAccountId], if
  /// any — lets the account menu offer "Migration Status" in place of
  /// "Migrate Account…" without the caller needing to already know which
  /// target it's running against. [sourceAccountId] can have more than one
  /// simultaneous migration (a distinct job per target is allowed); this
  /// returns whichever [getResumableJobs] happens to list first rather than
  /// offering a chooser for that rare case.
  Future<MigrationJobRecord?> getActiveJobForSource(
      String sourceAccountId) async {
    final jobs = await _localDatasource.getResumableJobs();
    for (final job in jobs) {
      if (job.sourceAccountId == sourceAccountId) return job;
    }
    return null;
  }

  /// Permanently-failed messages for this pair — the migration status
  /// dialog's failure list ("reported on").
  Future<List<MigrationLedgerRecord>> getFailures(
          String sourceAccountId, String targetAccountId) =>
      _localDatasource.getFailedRows(jobIdFor(sourceAccountId, targetAccountId));

  Future<void> _run(String sourceAccountId, String targetAccountId) async {
    final id = jobIdFor(sourceAccountId, targetAccountId);

    // Not treated as a failure — connectivity coming back is exactly what
    // the next explicit startOrResume/resumeAll call is for.
    if (!await _connectivityService.isOnline) return;

    Account? source;
    Account? target;
    for (final a in _accountManager.accounts) {
      if (a.id == sourceAccountId) source = a;
      if (a.id == targetAccountId) target = a;
    }
    if (source == null || target == null) {
      await _localDatasource.upsertJob(
        jobId: id,
        sourceAccountId: sourceAccountId,
        targetAccountId: targetAccountId,
        status: MigrationJobStatus.failed,
      );
      await _localDatasource.setJobStatus(
        jobId: id,
        status: MigrationJobStatus.failed,
        lastError: 'One of the two accounts is no longer set up',
      );
      return;
    }

    await _localDatasource.upsertJob(
      jobId: id,
      sourceAccountId: sourceAccountId,
      targetAccountId: targetAccountId,
      status: MigrationJobStatus.running,
    );

    final sourceDs = _accountManager.buildEmailDatasourceForAccount(source);
    final targetDs = _accountManager.buildEmailDatasourceForAccount(target);
    // A Gmail message can carry more than one label, so a straightforward
    // folder-by-folder walk would otherwise see (and re-copy) the same
    // message once per folder it belongs to.
    final dedupeAcrossFolders = source is GmailAccount;
    final sourceIsImap = source is ImapAccount;
    final targetIsImap = target is ImapAccount;

    try {
      final sourceFolders =
          await _allFolders(sourceDs, sourceIsImap, sourceAccountId);
      final sourceSpecialIds =
          await _guarded(sourceIsImap, sourceAccountId, sourceDs.getSpecialFolderIds);
      final targetSpecialIds =
          await _guarded(targetIsImap, targetAccountId, targetDs.getSpecialFolderIds);

      final sourceFolderKind = <String, SpecialFolderKind>{
        for (final e in sourceSpecialIds.entries) e.value: e.key,
      };

      // Built in the same breadth-first, parent-before-child order
      // _allFolders enumerated them in, so a child's parent has already been
      // resolved (or skipped) by the time this loop reaches it. A folder
      // nested under a \Noselect/hidden container (skipped below, so never
      // added here) falls back to the destination's root rather than being
      // dropped — a narrow structural edge case, not a data-loss one: the
      // mail still gets copied, just not re-nested under an equivalent
      // container that may not even have a destination counterpart.
      final destFolderIdFor = <String, String>{};

      for (final folder in sourceFolders) {
        if (folder.isHidden || _isDraftsFolder(folder)) continue;

        final kind = sourceFolderKind[folder.id];
        String destFolderId;
        if (kind != null && targetSpecialIds.containsKey(kind)) {
          destFolderId = targetSpecialIds[kind]!;
        } else {
          final destParentId = folder.parentFolderId == null
              ? ''
              : (destFolderIdFor[folder.parentFolderId] ?? '');
          destFolderId = await _guarded(
            targetIsImap,
            targetAccountId,
            () => targetDs.createFolder(
              parentFolderId: destParentId,
              displayName: folder.displayName,
            ),
          );
        }
        destFolderIdFor[folder.id] = destFolderId;

        final shouldContinue = await _copyFolder(
          jobId: id,
          sourceDs: sourceDs,
          targetDs: targetDs,
          sourceAccountId: sourceAccountId,
          targetAccountId: targetAccountId,
          sourceIsImap: sourceIsImap,
          targetIsImap: targetIsImap,
          dedupeAcrossFolders: dedupeAcrossFolders,
          sourceFolder: folder,
          destFolderId: destFolderId,
        );
        if (!shouldContinue) return; // offline mid-run; next call resumes
      }

      await _localDatasource.setJobStatus(
          jobId: id, status: MigrationJobStatus.completed);
    } on AuthException catch (e) {
      // A silently-expired token mid-job pauses rather than fails — nothing
      // here is a permanent per-message error, so it must not surface as a
      // wall of them. The next explicit startOrResume (after re-auth, or the
      // next app start's resumeAll) continues from exactly where the ledger
      // left off. There is no automatic resume-on-reauth listener wired in
      // this version; the job simply waits for that next call.
      await _localDatasource.setJobStatus(
        jobId: id,
        status: MigrationJobStatus.paused,
        lastError: e.message,
      );
    } catch (e) {
      await _localDatasource.setJobStatus(
        jobId: id,
        status: MigrationJobStatus.failed,
        lastError: e.toString(),
      );
    }
  }

  /// Runs [body] as the sole holder of [accountId]'s IMAP connection when
  /// [isImap] — a no-op wrapper otherwise, since Gmail/Graph build a fresh,
  /// stateless datasource per call and share no connection to serialize.
  Future<T> _guarded<T>(
    bool isImap,
    String accountId,
    Future<T> Function() body,
  ) {
    if (!isImap) return body();
    return _imapConnectionGate.runExclusive(accountId, body);
  }

  /// The full folder tree, not just the root level [EmailRemoteDatasource
  /// .getMailFolders] returns — a real mailbox routinely nests folders
  /// ("Projects/Q1"), and "iterate over the mailboxes in the account" means
  /// all of them, not only the top-level ones.
  Future<List<EmailFolder>> _allFolders(
    EmailRemoteDatasource ds,
    bool isImap,
    String accountId,
  ) async {
    final roots = await _guarded(isImap, accountId, ds.getMailFolders);
    final all = <EmailFolder>[...roots];
    final queue = <EmailFolder>[
      for (final f in roots)
        if (f.childFolderCount > 0) f,
    ];
    while (queue.isNotEmpty) {
      final parent = queue.removeAt(0);
      final children = await _guarded(
          isImap, accountId, () => ds.getChildFolders(parent.id));
      all.addAll(children);
      queue.addAll(children.where((f) => f.childFolderCount > 0));
    }
    return all;
  }

  /// Drafts is deliberately out of scope for this feature: a copied draft
  /// would carry the source account's identity into a mailbox someone could
  /// accidentally send from, and "insert this raw message" has no way to
  /// preserve draft-ness in the first place. [SpecialFolderKind] has no
  /// `drafts` entry for the same reason, so this is a plain name/id check
  /// rather than something [getSpecialFolderIds] already answers.
  bool _isDraftsFolder(EmailFolder folder) {
    final id = folder.id.toUpperCase();
    if (id == 'DRAFT' || id == 'DRAFTS') return true;
    final name = folder.displayName.trim().toLowerCase();
    return name == 'drafts' || name == 'draft';
  }

  /// Copies every not-yet-resolved message in [sourceFolder] into
  /// [destFolderId]. Returns false when the run should stop entirely
  /// (connectivity dropped mid-folder) rather than continue to the next
  /// folder; true once this folder is fully resolved (every message done or
  /// permanently failed).
  Future<bool> _copyFolder({
    required String jobId,
    required EmailRemoteDatasource sourceDs,
    required EmailRemoteDatasource targetDs,
    required String sourceAccountId,
    required String targetAccountId,
    required bool sourceIsImap,
    required bool targetIsImap,
    required bool dedupeAcrossFolders,
    required EmailFolder sourceFolder,
    required String destFolderId,
  }) async {
    // Always walks the whole folder from skip:0, every run — not from a
    // saved cursor. Two providers rule out seeding `skip` from anywhere but
    // zero: IMAP's getEmails ignores `orderBy` entirely and returns
    // newest-first, so an ascending cursor's "new mail lands after the
    // window" assumption is backwards there; and Gmail's `skip>0` only works
    // as "load more from the token this same datasource instance's last
    // skip:0 call stored" (`_pageTokens` in gmail_datasource_impl.dart) — a
    // fresh instance on resume has no stored token, so a nonzero starting
    // skip silently re-fetches page one forever and this loop would never
    // terminate. Starting at zero and letting the ledger lookup below skip
    // already-`done`/`failed` rows makes re-enumeration cheap (list-metadata
    // calls only, no body fetches) and correct regardless of provider
    // ordering or mid-run source-side changes.
    var skip = 0;
    // Graph and IMAP terminate this loop on an empty page. Gmail cannot:
    // once its own `_pageTokens` entry for this folder runs out (see above),
    // a further nonzero-skip call silently re-serves page one instead of
    // answering empty — so every message on it looks "new" again and
    // `skip` would climb forever without this page ever coming back empty.
    // Tracking which ids this pass has already seen turns that repeat into
    // the actual termination signal: a page with no id this pass hasn't
    // already processed means the provider wrapped, not that there's more
    // to see.
    final seenThisPass = <String>{};
    var processed = 0;
    final totalCount = sourceFolder.totalItemCount > 0
        ? sourceFolder.totalItemCount
        : null;
    void publishProgress() {
      _progress[jobId] = MigrationProgress(
        folderName: sourceFolder.displayName,
        processedCount: processed,
        totalCount: totalCount,
      );
    }

    publishProgress();

    while (true) {
      if (!await _connectivityService.isOnline) return false;

      final page = await _guarded(
        sourceIsImap,
        sourceAccountId,
        () => sourceDs.getEmails(
          folderId: sourceFolder.id,
          top: _pageSize,
          skip: skip,
        ),
      );
      if (page.isEmpty) break;
      final freshPage = page.where((e) => seenThisPass.add(e.id)).toList();
      if (freshPage.isEmpty) break;
      skip += page.length;

      for (final email in freshPage) {
        final existing = await _localDatasource.findLedgerRow(
          jobId: jobId,
          sourceFolderId: sourceFolder.id,
          sourceMessageId: email.id,
          matchSourceFolderId: !dedupeAcrossFolders,
        );
        if (existing != null) {
          if (existing.status == MigrationMessageStatus.done ||
              existing.status == MigrationMessageStatus.failed) {
            processed++;
            publishProgress();
            continue;
          }
          if (existing.status == MigrationMessageStatus.written) {
            // Crash landed between the provider call succeeding and the
            // 'done' write — the message already exists at the
            // destination (destMessageId is already on the row), so just
            // finish the transition rather than risk a second copy.
            await _localDatasource.upsertLedgerRow(
              jobId: jobId,
              sourceFolderId: sourceFolder.id,
              sourceMessageId: email.id,
              status: MigrationMessageStatus.done,
            );
            processed++;
            publishProgress();
            continue;
          }
        }

        try {
          await _copyOneMessage(
            jobId: jobId,
            sourceDs: sourceDs,
            targetDs: targetDs,
            sourceAccountId: sourceAccountId,
            targetAccountId: targetAccountId,
            sourceIsImap: sourceIsImap,
            targetIsImap: targetIsImap,
            sourceFolderId: sourceFolder.id,
            destFolderId: destFolderId,
            email: email,
            existingRetryCount: existing?.retryCount ?? 0,
          );
        } on AuthException {
          rethrow; // handled by _run — pauses the whole job
        } catch (_) {
          // Already recorded by _copyOneMessage (pending-for-retry or
          // permanently failed) — move on to the next message in this
          // page rather than let one bad message stall the folder.
        }
        processed++;
        publishProgress();
      }
    }
    return true;
  }

  /// Copies one message, retrying transient failures up to
  /// [_maxMessageAttempts] total attempts (across this call and any prior
  /// run's recorded [existingRetryCount]) before recording it permanently
  /// failed and rethrowing to the caller, which quarantines only this
  /// message and continues.
  Future<void> _copyOneMessage({
    required String jobId,
    required EmailRemoteDatasource sourceDs,
    required EmailRemoteDatasource targetDs,
    required String sourceAccountId,
    required String targetAccountId,
    required bool sourceIsImap,
    required bool targetIsImap,
    required String sourceFolderId,
    required String destFolderId,
    required Email email,
    required int existingRetryCount,
  }) async {
    await _localDatasource.upsertLedgerRow(
      jobId: jobId,
      sourceFolderId: sourceFolderId,
      sourceMessageId: email.id,
      status: MigrationMessageStatus.inProgress,
    );

    var attempt = existingRetryCount;
    while (true) {
      try {
        final rawBytes = await _guarded(sourceIsImap, sourceAccountId,
            () => sourceDs.getRawEmailBytes(email.id));

        final destMessageId = await _guarded(
          targetIsImap,
          targetAccountId,
          () => targetDs.insertRawMessage(
            folderId: destFolderId,
            rawBytes: rawBytes,
            receivedAt: email.receivedDateTime,
            isRead: email.isRead,
          ),
        );

        // Persisted the instant the provider call returns success, before
        // anything else — the actual crash-recovery guard. A crash between
        // this write and the 'done' one below leaves a 'written' row that
        // resume recognises (see _copyFolder) instead of a gap that looks
        // unattempted and gets silently re-copied.
        await _localDatasource.upsertLedgerRow(
          jobId: jobId,
          sourceFolderId: sourceFolderId,
          sourceMessageId: email.id,
          status: MigrationMessageStatus.written,
          destFolderId: destFolderId,
          destMessageId: destMessageId,
        );
        await _localDatasource.upsertLedgerRow(
          jobId: jobId,
          sourceFolderId: sourceFolderId,
          sourceMessageId: email.id,
          status: MigrationMessageStatus.done,
        );
        return;
      } on AuthException {
        rethrow;
      } catch (e) {
        attempt++;
        if (attempt >= _maxMessageAttempts) {
          await _localDatasource.upsertLedgerRow(
            jobId: jobId,
            sourceFolderId: sourceFolderId,
            sourceMessageId: email.id,
            status: MigrationMessageStatus.failed,
            lastError: e.toString(),
            incrementRetry: true,
          );
          rethrow;
        }
        await _localDatasource.upsertLedgerRow(
          jobId: jobId,
          sourceFolderId: sourceFolderId,
          sourceMessageId: email.id,
          status: MigrationMessageStatus.pending,
          lastError: e.toString(),
          incrementRetry: true,
        );
        // A short fixed delay between this one message's own attempts —
        // not a general adaptive/token-bucket throttle. RetryInterceptor
        // already backs off 429/503 at the HTTP layer; this just keeps a
        // hard-failing single message from hammering the server three
        // times back to back.
        await Future.delayed(Duration(seconds: 2 * attempt));
      }
    }
  }
}
