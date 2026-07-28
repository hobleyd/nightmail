/// Where a cached contact came from. Persisted by [name] in
/// `cached_contacts.source`, so the identifiers are part of the on-disk format
/// — rename one and existing rows stop ranking correctly until the next sync.
enum ContactSource {
  /// Someone who has emailed this account before (the `known_senders` table).
  sender,

  /// The user's own address book on the provider (Google "connections",
  /// Graph `/me/contacts`).
  personal,

  /// The OS address book (macOS `CNContactStore`).
  system,

  /// The organisation directory / GAL (Workspace domain profiles, Entra users).
  directory,

  /// Auto-saved interaction addresses the provider keeps outside the real
  /// address book (Google "other contacts", Graph `/me/people`).
  other;

  /// Lower sorts first in the typeahead. People you have actually corresponded
  /// with beat directory entries, which beat provider-inferred addresses.
  int get rank => switch (this) {
        ContactSource.sender => 0,
        ContactSource.personal => 1,
        ContactSource.system => 2,
        ContactSource.directory => 3,
        ContactSource.other => 4,
      };

  static ContactSource parse(String value) => ContactSource.values.firstWhere(
        (s) => s.name == value,
        orElse: () => ContactSource.other,
      );
}

/// One row of the address-book cache.
class CachedContact {
  const CachedContact({
    required this.address,
    required this.name,
    required this.source,
  });

  /// Always lower-cased.
  final String address;

  /// Display name, or empty when the source had none.
  final String name;

  final ContactSource source;

  /// The single column the typeahead's `LIKE` runs against — see
  /// `CachedContacts.searchText`.
  String get searchText => '${name.toLowerCase()} $address'.trim();

  @override
  String toString() => 'CachedContact($address, $name, ${source.name})';
}
