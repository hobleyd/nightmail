import 'package:flutter/foundation.dart';

import '../entities/cached_contact.dart';
import '../entities/contact_suggestion.dart';
import '../repositories/contact_cache_repository.dart';
import '../repositories/directory_contacts_repository.dart';
import '../repositories/sender_repository.dart';
import '../repositories/system_contacts_repository.dart';

/// Builds the recipient typeahead's dropdown.
///
/// Reads two local, indexed tables — the address-book cache that
/// `ContactCacheSyncService` refreshes daily (provider directory, personal
/// contacts, OS address book) and `known_senders` (people who have emailed
/// this account) — and merges them. Neither touches the network, so the
/// dropdown appears at typing speed.
///
/// The live provider lookup only runs as a fallback for an account whose cache
/// has never been populated, i.e. between first launch and the first sync
/// completing.
class SearchContacts {
  const SearchContacts({
    required this.senderRepository,
    required this.contactCacheRepository,
    required this.systemContactsRepository,
    required this.directoryContactsRepository,
  });

  final SenderRepository senderRepository;
  final ContactCacheRepository contactCacheRepository;
  final SystemContactsRepository systemContactsRepository;
  final DirectoryContactsRepository directoryContactsRepository;

  /// How many candidates each local source contributes before ranking. Well
  /// above the eight that are shown so that a lower-ranked source can still
  /// win a slot on relevance.
  static const _perSourceLimit = 60;

  static const _maxSuggestions = 8;

  Future<List<ContactSuggestion>> call({
    required String query,
    required String accountId,
    String? accountDomain,
  }) async {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return [];

    final candidates = <CachedContact>[];

    // Known senders live in their own table, written continuously as mail
    // arrives, so they are always current and are queried separately from the
    // once-a-day cache rather than folded into it.
    final results = await Future.wait([
      _senders(accountId, q),
      _cached(accountId, q),
    ]);
    candidates
      ..addAll(results[0])
      ..addAll(results[1]);

    if (!await _cacheIsUsable(accountId)) {
      candidates.addAll(await _liveFallback(accountId, q));
    }

    return _rank(candidates, query: q, accountDomain: accountDomain);
  }

  Future<List<CachedContact>> _senders(String accountId, String q) async {
    try {
      final senders = await senderRepository.searchSendersForAccount(
        accountId: accountId,
        query: q,
        limit: _perSourceLimit,
      );
      return [
        for (final s in senders)
          CachedContact(
            address: s.address.toLowerCase(),
            name: s.name,
            source: ContactSource.sender,
          ),
      ];
    } catch (e) {
      debugPrint('[NightMail] known-senders search error: $e');
      return const [];
    }
  }

  Future<List<CachedContact>> _cached(String accountId, String q) async {
    try {
      return await contactCacheRepository.search(
        accountId: accountId,
        query: q,
        limit: _perSourceLimit,
      );
    } catch (e) {
      debugPrint('[NightMail] contact-cache search error: $e');
      return const [];
    }
  }

  Future<bool> _cacheIsUsable(String accountId) async {
    try {
      return await contactCacheRepository.hasSyncedAccount(accountId);
    } catch (e) {
      debugPrint('[NightMail] contact-cache status error: $e');
      return false;
    }
  }

  /// The pre-cache path: hit the provider directory and the OS address book
  /// directly. Slow (this is what the cache exists to avoid) but it keeps the
  /// dropdown working on the very first compose after install.
  Future<List<CachedContact>> _liveFallback(String accountId, String q) async {
    final live = <CachedContact>[];
    await Future.wait([
      systemContactsRepository.search(q).then((contacts) {
        live.addAll(_asCached(contacts, ContactSource.system));
      }).catchError((Object e) {
        debugPrint('[NightMail] system-contacts search error: $e');
      }),
      directoryContactsRepository
          .search(q, accountId: accountId)
          .then((contacts) {
        live.addAll(_asCached(contacts, ContactSource.directory));
      }).catchError((Object e) {
        debugPrint('[NightMail] directory-contacts search error: $e');
      }),
    ]);
    return live;
  }

  Iterable<CachedContact> _asCached(
    List<ContactSuggestion> suggestions,
    ContactSource source,
  ) =>
      suggestions.map((c) => CachedContact(
            address: c.address.toLowerCase(),
            name: c.name ?? '',
            source: source,
          ));

  /// Orders the merged candidates and trims to what the dropdown shows.
  ///
  /// Ordering, most significant first:
  ///  1. how well the text matched — a prefix beats a match buried mid-string;
  ///  2. colleagues on the account's own domain;
  ///  3. how much the source is worth (see [ContactSource.rank]) — someone you
  ///     have corresponded with outranks a directory entry;
  ///  4. named entries over bare addresses, then alphabetically, so the list
  ///     is stable between keystrokes.
  List<ContactSuggestion> _rank(
    List<CachedContact> candidates, {
    required String query,
    required String? accountDomain,
  }) {
    final domain = accountDomain?.toLowerCase();
    final domainSuffix =
        (domain == null || domain.isEmpty) ? null : '@$domain';

    // Deduplicate before sorting: the same person legitimately arrives from
    // several sources, and mergeContacts keeps the best-ranked copy.
    final unique = <String, CachedContact>{};
    for (final c in candidates) {
      final existing = unique[c.address];
      if (existing == null ||
          c.source.rank < existing.source.rank ||
          (c.source.rank == existing.source.rank &&
              c.name.length > existing.name.length)) {
        unique[c.address] = c;
      }
    }

    final scored = [
      for (final c in unique.values)
        (
          contact: c,
          tier: _matchTier(c, query),
          domainRank:
              domainSuffix != null && c.address.endsWith(domainSuffix) ? 0 : 1,
        ),
    ]..sort((a, b) {
        final byTier = a.tier.compareTo(b.tier);
        if (byTier != 0) return byTier;
        final byDomain = a.domainRank.compareTo(b.domainRank);
        if (byDomain != 0) return byDomain;
        final bySource =
            a.contact.source.rank.compareTo(b.contact.source.rank);
        if (bySource != 0) return bySource;
        final byNamed = (a.contact.name.isEmpty ? 1 : 0)
            .compareTo(b.contact.name.isEmpty ? 1 : 0);
        if (byNamed != 0) return byNamed;
        final byName = a.contact.name
            .toLowerCase()
            .compareTo(b.contact.name.toLowerCase());
        if (byName != 0) return byName;
        return a.contact.address.compareTo(b.contact.address);
      });

    return [
      for (final s in scored.take(_maxSuggestions))
        ContactSuggestion(
          address: s.contact.address,
          name: s.contact.name.isEmpty ? null : s.contact.name,
        ),
    ];
  }

  /// 0 — the name or address starts with the query;
  /// 1 — a word of the name, or a dot/dash-separated part of the local part,
  ///     starts with it ("hob" → "David Hobley", "david.hobley@…");
  /// 2 — it matched somewhere else in the middle.
  static int _matchTier(CachedContact c, String query) {
    final name = c.name.toLowerCase();
    if (name.startsWith(query) || c.address.startsWith(query)) return 0;
    for (final word in name.split(_wordBreak)) {
      if (word.startsWith(query)) return 1;
    }
    final at = c.address.indexOf('@');
    final localPart = at > 0 ? c.address.substring(0, at) : c.address;
    for (final part in localPart.split(_wordBreak)) {
      if (part.startsWith(query)) return 1;
    }
    return 2;
  }

  static final _wordBreak = RegExp(r'[\s._\-+]+');
}
