import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/local/delta_token_datasource.dart';
import 'package:nightmail/data/datasources/local/email_local_datasource.dart';
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

  @override
  Future<int> restoreFolderMemberships({required String accountId}) async {
    if (throwFor.contains(accountId)) throw StateError('cache unreadable');
    repaired.add(accountId);
    return 1;
  }
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
  late _FakeTokens tokens;

  CacheMembershipRepairService serviceFor(List<Account> accounts) =>
      CacheMembershipRepairService(
        accountManager: _FakeAccounts(accounts),
        emailLocalDatasource: local,
        deltaTokens: tokens,
      );

  setUp(() {
    local = _FakeLocal();
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
