import '../entities/cached_contact.dart';

/// Read access to the locally cached address book that backs the recipient
/// typeahead. Writes are the sync service's job, not the typeahead's.
abstract interface class ContactCacheRepository {
  /// Ranked match over [accountId]'s cached contacts plus the OS address book.
  /// [query] must already be lower-cased and trimmed.
  Future<List<CachedContact>> search({
    required String accountId,
    required String query,
    int limit,
  });

  /// True once a refresh has been attempted for [accountId] — even one that
  /// found nothing. The typeahead uses this to decide whether the cache can be
  /// trusted yet, or whether it still has to fall back to a live lookup.
  Future<bool> hasSyncedAccount(String accountId);
}
