import '../../../domain/entities/cached_contact.dart';

/// Outcome of the last address-book refresh for one account.
class ContactSyncStatus {
  const ContactSyncStatus({
    required this.syncedAt,
    required this.contactCount,
    required this.status,
    this.detail,
  });

  final DateTime syncedAt;
  final int contactCount;

  /// `ok` | `partial` | `error`.
  final String status;

  /// Human-readable note about what failed, for `partial` and `error`.
  final String? detail;

  bool get isClean => status == 'ok';
}

abstract interface class ContactCacheLocalDatasource {
  /// Atomically swaps this account's slice of the cache for [contacts] and
  /// records the sync outcome. A failed fetch must NOT call this with an empty
  /// list — that would wipe a good cache; leave the previous rows in place and
  /// record the failure with [markSyncFailed] instead.
  Future<void> replaceForAccount({
    required String accountId,
    required List<CachedContact> contacts,
    required String status,
    String? detail,
  });

  /// Records a failed refresh without touching the cached rows, so the next
  /// staleness check can retry sooner than the full TTL.
  Future<void> markSyncFailed({
    required String accountId,
    required String detail,
  });

  /// Ranked prefix/substring match over [accountId]'s contacts plus the
  /// account-independent OS address book. [query] must already be lower-cased
  /// and trimmed.
  Future<List<CachedContact>> search({
    required String accountId,
    required String query,
    int limit = 60,
  });

  Future<ContactSyncStatus?> syncStatus(String accountId);

  /// True once [accountId] has at least one cached row — the signal the
  /// typeahead uses to decide whether it can trust the cache yet.
  Future<bool> hasContacts(String accountId);

  /// Every account id that currently has a sync-state row, so the sync service
  /// can drop slices belonging to accounts the user has since removed.
  Future<List<String>> cachedAccountIds();

  Future<void> clearAccount(String accountId);
}
