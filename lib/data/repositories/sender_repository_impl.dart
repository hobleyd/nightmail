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
}
