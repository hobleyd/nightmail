import '../../domain/repositories/sender_repository.dart';
import '../datasources/local/sender_local_datasource.dart';

class SenderRepositoryImpl implements SenderRepository {
  const SenderRepositoryImpl({required SenderLocalDatasource localDatasource})
      : _localDatasource = localDatasource;

  final SenderLocalDatasource _localDatasource;

  @override
  Future<void> recordSender({
    required String accountId,
    required String address,
    required String name,
  }) =>
      _localDatasource.upsertSender(
        accountId: accountId,
        address: address,
        name: name,
      );

  @override
  Future<List<KnownSenderEntry>> getSendersForAccount(String accountId) =>
      _localDatasource.getSendersForAccount(accountId);

  @override
  Future<void> clearSendersForAccount(String accountId) =>
      _localDatasource.clearSendersForAccount(accountId);

  @override
  Future<void> mergeSenders({
    required String accountId,
    required String address1,
    required String address2,
  }) {
    final a = address1.toLowerCase();
    final b = address2.toLowerCase();
    final lo = a.compareTo(b) <= 0 ? a : b;
    final hi = a.compareTo(b) <= 0 ? b : a;
    return _localDatasource.upsertAlias(
        accountId: accountId, address1: lo, address2: hi);
  }

  @override
  Future<Set<(String, String)>> getAliasesForAccount(String accountId) =>
      _localDatasource.getAliasesForAccount(accountId);
}
