import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/core/settings/app_settings.dart';
import 'package:nightmail/domain/entities/folder_listing.dart';
import 'package:nightmail/domain/repositories/email_repository.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/network/connectivity_service.dart';
import 'package:nightmail/infrastructure/sync/folder_backfill_service.dart';

const _microsoft = MicrosoftAccount(
  id: 'ms',
  displayName: 'MS',
  emailAddress: 'a@example.com',
  tenantId: 'common',
);

const _gmail = GmailAccount(
  id: 'g',
  displayName: 'G',
  emailAddress: 'b@example.com',
);

class _Accounts extends Fake implements AccountManager {
  _Accounts(this.accounts);

  @override
  final List<Account> accounts;
}

class _Online implements ConnectivityService {
  bool online = true;

  @override
  Future<bool> get isOnline async => online;

  @override
  Stream<void> get onReconnected => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef _PageCall = ({
  String accountId,
  String folderId,
  int skip,
  DateTime? olderThan,
  DateTime? windowEnd,
});

/// Holds coverages and walks in memory, and answers each page from [pages].
class _Repo extends Fake implements EmailRepository {
  final folders = <String, List<String>>{};
  final coverage = <String, FolderCoverage>{};
  final walks = <String, FolderWalk>{};
  final calls = <_PageCall>[];
  final finished = <String, DateTime>{};
  Either<Failure, SyncedPage> Function(_PageCall call) pages =
      (_) => const Right(SyncedPage(rows: 0, windowStart: null));

  @override
  Future<Either<Failure, List<String>>> getCoveredFolderIds(
          String accountId) async =>
      Right(folders[accountId] ?? const []);

  @override
  Future<Either<Failure, FolderCoverage>> getFolderCoverage({
    required String accountId,
    required String folderId,
  }) async =>
      Right(coverage['$accountId/$folderId'] ?? const FolderCoverage());

  @override
  Future<Either<Failure, FolderWalk?>> getFolderWalk({
    required String accountId,
    required String folderId,
  }) async =>
      Right(walks['$accountId/$folderId']);

  @override
  Future<Either<Failure, Unit>> saveFolderWalk({
    required String accountId,
    required String folderId,
    FolderWalk? walk,
    DateTime? finishedFullPass,
  }) async {
    final key = '$accountId/$folderId';
    if (walk == null) {
      walks.remove(key);
    } else {
      walks[key] = walk;
    }
    if (finishedFullPass != null) finished[key] = finishedFullPass;
    return const Right(unit);
  }

  @override
  Future<Either<Failure, SyncedPage>> syncFolderPage({
    required String accountId,
    required String folderId,
    required int top,
    int skip = 0,
    DateTime? olderThan,
    DateTime? windowEnd,
  }) async {
    final call = (
      accountId: accountId,
      folderId: folderId,
      skip: skip,
      olderThan: olderThan,
      windowEnd: windowEnd,
    );
    calls.add(call);
    return pages(call);
  }
}

void main() {
  final now = DateTime(2026, 11, 28, 9);
  late _Repo repo;
  late _Online connectivity;

  FolderBackfillService service(List<Account> accounts) =>
      FolderBackfillService(
        repository: repo,
        accountManager: _Accounts(accounts),
        settings: AppSettings(),
        connectivity: connectivity,
        clock: () => now,
      );

  setUp(() {
    repo = _Repo();
    connectivity = _Online();
  });

  test('walks on from the coverage edge, a page at a time, with the cutoff '
      'fixed and each page\'s window ending where the last one started',
      () async {
    final edge = now.subtract(const Duration(days: 3));
    repo.folders['ms'] = ['inbox'];
    repo.coverage['ms/inbox'] = FolderCoverage(coveredFrom: edge);
    final starts = [
      now.subtract(const Duration(days: 5)),
      now.subtract(const Duration(days: 9)),
    ];
    repo.pages = (call) => Right(SyncedPage(
          rows: 25,
          windowStart: call.skip < 50 ? starts[call.skip ~/ 25] : null,
        ));
    final backfill = service([_microsoft]);

    expect(await backfill.runOnce(), FolderBackfillService.graphInterval);
    expect(await backfill.runOnce(), FolderBackfillService.graphInterval);
    expect(await backfill.runOnce(), FolderBackfillService.graphInterval);

    expect(repo.calls.map((c) => c.olderThan), [edge, edge, edge]);
    expect(repo.calls.map((c) => c.skip), [0, 25, 50]);
    expect(repo.calls.map((c) => c.windowEnd), [edge, ...starts]);
    expect(repo.walks, isEmpty, reason: 'the walk ended at the bottom');
    expect(repo.finished['ms/inbox'], now);
  });

  test('a complete folder checked within the month has nothing to do',
      () async {
    repo.folders['ms'] = ['inbox'];
    repo.coverage['ms/inbox'] = FolderCoverage(
      complete: true,
      lastFullPassAt: now.subtract(const Duration(days: 29)),
    );

    expect(await service([_microsoft]).runOnce(),
        FolderBackfillService.idleInterval);
    expect(repo.calls, isEmpty);
  });

  test('a month after its last full pass, a folder is re-walked from the top',
      () async {
    repo.folders['ms'] = ['inbox'];
    repo.coverage['ms/inbox'] = FolderCoverage(
      complete: true,
      lastFullPassAt: now.subtract(const Duration(days: 31)),
    );

    await service([_microsoft]).runOnce();

    expect(repo.calls.single.olderThan, now);
    expect(repo.calls.single.windowEnd, now);
  });

  test('a walk under way resumes where it was saved', () async {
    repo.folders['g'] = ['INBOX'];
    final walk = FolderWalk(
      before: now.subtract(const Duration(days: 1)),
      offset: 75,
      windowEnd: now.subtract(const Duration(days: 4)),
      full: true,
    );
    repo.walks['g/INBOX'] = walk;
    repo.pages = (_) => Right(SyncedPage(
        rows: 25, windowStart: now.subtract(const Duration(days: 6))));

    // Gmail pages are paced to a third of the per-user quota.
    expect(await service([_gmail]).runOnce(),
        FolderBackfillService.gmailInterval);

    expect(repo.calls.single.skip, 75);
    expect(repo.calls.single.olderThan, walk.before);
    expect(repo.walks['g/INBOX']!.offset, 100);
    expect(repo.walks['g/INBOX']!.full, isTrue);
  });

  test('a failed page keeps the walk where it was and backs off', () async {
    repo.folders['ms'] = ['inbox'];
    repo.coverage['ms/inbox'] = FolderCoverage(coveredFrom: now);
    repo.pages = (_) => const Left(ServerFailure(message: 'throttled'));

    expect(await service([_microsoft]).runOnce(),
        FolderBackfillService.failureInterval);
    expect(repo.walks, isEmpty);
  });

  test('offline, nothing is asked for', () async {
    connectivity.online = false;
    repo.folders['ms'] = ['inbox'];
    repo.coverage['ms/inbox'] = FolderCoverage(coveredFrom: now);

    expect(await service([_microsoft]).runOnce(),
        FolderBackfillService.offlineInterval);
    expect(repo.calls, isEmpty);
  });

  test('never walks the mailbox-wide default key', () async {
    repo.folders['ms'] = ['__DEFAULT__'];
    repo.coverage['ms/__DEFAULT__'] = FolderCoverage(coveredFrom: now);

    expect(await service([_microsoft]).runOnce(),
        FolderBackfillService.idleInterval);
  });
}
