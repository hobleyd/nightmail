import '../../domain/entities/cached_contact.dart';
import '../../domain/repositories/contact_cache_repository.dart';
import '../datasources/local/contact_cache_local_datasource.dart';

class ContactCacheRepositoryImpl implements ContactCacheRepository {
  const ContactCacheRepositoryImpl({
    required ContactCacheLocalDatasource localDatasource,
  }) : _localDatasource = localDatasource;

  final ContactCacheLocalDatasource _localDatasource;

  @override
  Future<List<CachedContact>> search({
    required String accountId,
    required String query,
    int limit = 60,
  }) =>
      _localDatasource.search(
        accountId: accountId,
        query: query,
        limit: limit,
      );

  @override
  Future<bool> hasSyncedAccount(String accountId) async =>
      await _localDatasource.syncStatus(accountId) != null;
}
