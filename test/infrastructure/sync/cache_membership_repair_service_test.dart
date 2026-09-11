import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/local/delta_token_datasource.dart';
import 'package:nightmail/data/datasources/local/email_local_datasource.dart';
import 'package:nightmail/data/datasources/local/folder_local_datasource.dart';
import 'package:nightmail/domain/entities/email_folder.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/sync/cache_membership_repair_service.dart';

MicrosoftAccount _account(String id) => MicrosoftAccount(
      id: id,
      displayName: id,
      emailAddress: '$id@example.com',
      tenantId: 'tenant',
    );

class _FakeAccounts extends Fake implements AccountManager {
  _FakeAccounts(this._accounts);
  final List<Account> _accounts;

  @override
  List<Account> get accounts => _accounts;
}

class _FakeLocal extends Fake implements EmailLocalDatasource {
  final List<String> repaired = [];
  final Set<String> throwFor = {};

  /// Account id -> the folder ids the prune was told to trust.
  final List<({String accountId, Set<String> knownFolderIds})> pruned = [];
  final Set<String> throwPruneFor = {};

  @override
  Future<int> restoreFolderMemberships({required String accountId}) async {
    if (throwFor.contains(accountId)) throw StateError('cache unreadable');
    repaired.add(accountId);
    return 1;
  }

  @override
  Future<int> pruneForeignFolderRows({
    required String accountId,
    required Set<String> knownFolderIds,
  }) async {
    if (throwPruneFor.contains(accountId)) throw StateError('cache unreadable');
    pruned.add((accountId: accountId, knownFolderIds: knownFolderIds));
    return 1;
  }
}

class _FakeFolders extends Fake implements FolderLocalDatasource {
  /// Account id -> its cached folder ids. An absent account has no cached tree.
  final Map<String, List<String>> byAccount = {};

  @override
  Future<List<EmailFolder>> getCachedFolders(String accountId) async => [
        for (final id in byAccount[accountId] ?? const <String>[])
          EmailFolder(
            id: id,
            displayName: id,
            totalItemCount: 0,
            unreadItemCount: 0,
          ),
      ];
}

/// The delta-token table doubles as the marker store; this is that table.
class _FakeTokens extends Fake implements DeltaTokenDatasource {
  final Map<String, String> stored = {};

  String _key(String accountId, String folderId) => '$accountId|$folderId';

  @override
  Future<String?> loadDeltaToken(String accountId, String folderId) async =>
      stored[_key(accountId, folderId)];

  @override
  Future<void> saveDeltaToken(
          String accountId, String folderId, String deltaLink) async =>
      stored[_key(accountId, folderId)] = deltaLink;

  @override
  Future<void> clearDeltaTokensForAccount(String accountId) async =>
      stored.removeWhere((k, _) => k.startsWith('$accountId|'));
}

void main() {
  late _FakeLocal local;
  late _FakeFolders folders;
  late _FakeTokens tokens;

  CacheMembershipRepairService serviceFor(List<Account> accounts) =>
      CacheMembershipRepairService(
        accountManager: _FakeAccounts(accounts),
        emailLocalDatasource: local,
        folderLocalDatasource: folders,
        deltaTokens: tokens,
      );

  setUp(() {
    local = _FakeLocal();
    folders = _FakeFolders();
    tokens = _FakeTokens();
  });

  test('repairs every account once', () async {
    final service = serviceFor([_account('a'), _account('b')]);

    await service.repairAll();
    await service.repairAll();

    expect(local.repaired, ['a', 'b']);
  });

  test('repairs an account added after the first pass', () async {
    await serviceFor([_account('a')]).repairAll();
    await serviceFor([_account('a'), _account('b')]).repairAll();

    expect(local.repaired, ['a', 'b']);
  });

  // The pass is best-effort: the only thing at stake is how quickly a folder's
  // cache fills in, so one unreadable account must not stop the others and must
  // be retried next launch.
  test('a failure leaves the account unmarked and the others repaired',
      () async {
    local.throwFor.add('a');
    final service = serviceFor([_account('a'), _account('b')]);

    await service.repairAll();
    expect(local.repaired, ['b']);

    local.throwFor.clear();
    await service.repairAll();
    expect(local.repaired, ['b', 'a']);
  });

  // ---------------------------------------------------------------------------
  // Pruning rows filed under another account's folder
  // ---------------------------------------------------------------------------

  group('the foreign-folder prune', () {
    test('runs once per account, against that account\'s own folders',
        () async {
      folders.byAccount['a'] = ['inbox-a', 'sent-a'];
      folders.byAccount['b'] = ['inbox-b'];
      final service = serviceFor([_account('a'), _account('b')]);

      await service.repairAll();
      await service.repairAll();

      expect(local.pruned.map((p) => p.accountId), ['a', 'b']);
      expect(local.pruned.first.knownFolderIds, {'inbox-a', 'sent-a'});
    });

    // "We could not tell" is not "there was nothing to do". Marking an account
    // whose folder tree has not been cached yet would skip the prune for good.
    test('defers, unmarked, while the account has no cached folder tree',
        () async {
      final service = serviceFor([_account('a')]);

      await service.repairAll();
      expect(local.pruned, isEmpty);

      folders.byAccount['a'] = ['inbox-a'];
      await service.repairAll();
      expect(local.pruned.map((p) => p.accountId), ['a']);
    });

    // Each pass is caught on its own: one failing must not cost the account the
    // other, and must leave itself to the next launch.
    test('a failure leaves the membership repair done and itself unmarked',
        () async {
      folders.byAccount['a'] = ['inbox-a'];
      local.throwPruneFor.add('a');
      final service = serviceFor([_account('a')]);

      await service.repairAll();
      expect(local.repaired, ['a']);
      expect(local.pruned, isEmpty);

      local.throwPruneFor.clear();
      await service.repairAll();
      expect(local.repaired, ['a'], reason: 'already marked, must not re-run');
      expect(local.pruned.map((p) => p.accountId), ['a']);
    });

    // Its marker is its own: an install that has run the older pass has not
    // necessarily run this one.
    test('runs on an account the membership repair has already marked',
        () async {
      folders.byAccount['a'] = ['inbox-a'];
      final service = serviceFor([_account('a')]);
      await service.repairAccount('a');

      await service.repairAll();

      expect(local.repaired, ['a']);
      expect(local.pruned.map((p) => p.accountId), ['a']);
    });
  });

  // Re-bootstrapping a delta stream drops every token an account owns, which is
  // why the marker is filed under a sentinel id instead of the account's own.
  test('a delta-token reset does not make the repair run again', () async {
    final service = serviceFor([_account('a')]);
    await service.repairAll();

    await tokens.clearDeltaTokensForAccount('a');
    await service.repairAll();

    expect(local.repaired, ['a']);
  });
}
