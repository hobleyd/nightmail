import 'dart:convert';

import '../../../domain/entities/cached_contact.dart';

/// Isolate-side parsing for the daily address-book refresh.
///
/// The bulk endpoints return whole pages of a directory at a time — a large
/// Workspace or Entra tenant is tens of thousands of people — so decoding and
/// normalising them on the UI isolate visibly janks the app. Everything here is
/// therefore written as top-level functions over plain, isolate-transferable
/// data (raw response bodies in, [CachedContact]s out) so the sync service can
/// hand them to `compute()`, matching the `_buildDraftRawBase64` pattern in
/// `gmail_datasource_impl.dart`.
///
/// The fetchers deliberately request `ResponseType.plain` and pass the
/// undecoded body strings through — letting Dio call `jsonDecode` would put the
/// expensive half of the work back on the caller's isolate.

/// A bulk fetch that is allowed to come back incomplete.
///
/// Address-book sources fail independently and routinely: a consumer Gmail
/// account has no directory, an Entra tenant may withhold `User.Read.All`, an
/// account authorised before a scope was added 403s until it is signed in
/// again. Losing one collection should degrade the cache, not abort the sync,
/// so failures travel alongside the data instead of as an exception — and are
/// recorded in `contact_sync_states.detail` so a thin cache is diagnosable
/// rather than silent.
class BulkFetchResult<T> {
  const BulkFetchResult({
    required this.data,
    this.failures = const [],
    this.truncated = false,
  });

  final T data;

  /// One entry per collection that could not be fetched, already summarised
  /// for logging (e.g. `directory: HTTP 403`).
  final List<String> failures;

  /// True when a page cap was hit, i.e. the address book is larger than what
  /// was fetched.
  final bool truncated;

  bool get isComplete => failures.isEmpty && !truncated;

  /// Null when complete, otherwise a one-line summary for the sync-state row.
  String? get detail {
    final parts = [
      ...failures,
      if (truncated) 'page cap reached — directory partially cached',
    ];
    return parts.isEmpty ? null : parts.join('; ');
  }
}

/// Raw page bodies from the three Google People API collections.
class GooglePeoplePages {
  const GooglePeoplePages({
    required this.connections,
    required this.otherContacts,
    required this.directory,
  });

  /// `people/me/connections` — the user's own address book.
  final List<String> connections;

  /// `otherContacts` — addresses Google auto-saved from interactions.
  final List<String> otherContacts;

  /// `people:listDirectoryPeople` — Workspace domain profiles (the GAL).
  final List<String> directory;
}

/// Raw page bodies from the three Microsoft Graph collections.
class GraphContactPages {
  const GraphContactPages({
    required this.personalContacts,
    required this.directoryUsers,
    required this.people,
  });

  /// `/me/contacts` — the user's own Outlook contacts.
  final List<String> personalContacts;

  /// `/users` — the Entra directory.
  final List<String> directoryUsers;

  /// `/me/people` — relevance-ranked people, including frequent correspondents
  /// who are in neither of the above.
  final List<String> people;
}

/// Parses and merges the Google pages. Safe to run under `compute`.
List<CachedContact> parseGooglePeoplePages(GooglePeoplePages pages) {
  final out = <CachedContact>[];
  for (final body in pages.connections) {
    _readGooglePersons(body, 'connections', ContactSource.personal, out);
  }
  for (final body in pages.directory) {
    _readGooglePersons(body, 'people', ContactSource.directory, out);
  }
  for (final body in pages.otherContacts) {
    _readGooglePersons(body, 'otherContacts', ContactSource.other, out);
  }
  return mergeContacts(out);
}

/// Parses and merges the Graph pages. Safe to run under `compute`.
List<CachedContact> parseGraphContactPages(GraphContactPages pages) {
  final out = <CachedContact>[];
  for (final body in pages.personalContacts) {
    _readGraphOutlookContacts(body, out);
  }
  for (final body in pages.directoryUsers) {
    _readGraphDirectoryUsers(body, out);
  }
  for (final body in pages.people) {
    _readGraphPeople(body, out);
  }
  return mergeContacts(out);
}

/// Normalises the `{address, name}` maps the macOS contacts channel returns.
/// Safe to run under `compute`.
List<CachedContact> parseSystemContacts(List<Map<String, String>> raw) {
  final out = <CachedContact>[];
  for (final m in raw) {
    _add(out, m['address'], m['name'], ContactSource.system);
  }
  return mergeContacts(out);
}

/// Collapses duplicate addresses, keeping the entry from the most trustworthy
/// source and, among equally trustworthy ones, the richest display name.
///
/// The same person routinely appears in all three collections of a provider —
/// once in the directory, once in the user's own contacts, once as an
/// auto-saved address — usually with a name in only some of them.
List<CachedContact> mergeContacts(List<CachedContact> contacts) {
  final byAddress = <String, CachedContact>{};
  for (final c in contacts) {
    final existing = byAddress[c.address];
    if (existing == null) {
      byAddress[c.address] = c;
      continue;
    }
    // A better source wins outright; otherwise only upgrade a missing or
    // shorter name, so "D Hobley" never replaces "David Hobley".
    if (c.source.rank < existing.source.rank) {
      byAddress[c.address] = CachedContact(
        address: c.address,
        name: c.name.isNotEmpty ? c.name : existing.name,
        source: c.source,
      );
    } else if (c.name.length > existing.name.length) {
      byAddress[c.address] = CachedContact(
        address: existing.address,
        name: c.name,
        source: existing.source,
      );
    }
  }
  return byAddress.values.toList();
}

// --- Google -----------------------------------------------------------------

/// All three Google collections return a list of `Person` objects, differing
/// only in the key holding them ([listKey]).
void _readGooglePersons(
  String body,
  String listKey,
  ContactSource source,
  List<CachedContact> out,
) {
  final data = _decodeObject(body);
  if (data == null) return;
  final people = data[listKey];
  if (people is! List) return;
  for (final p in people) {
    if (p is! Map) continue;
    final names = p['names'];
    final name = (names is List && names.isNotEmpty && names.first is Map)
        ? (names.first as Map)['displayName'] as String?
        : null;
    final emails = p['emailAddresses'];
    if (emails is! List) continue;
    for (final e in emails) {
      if (e is! Map) continue;
      _add(out, e['value'] as String?, name, source);
    }
  }
}

// --- Microsoft Graph --------------------------------------------------------

void _readGraphOutlookContacts(String body, List<CachedContact> out) {
  final items = _graphValue(body);
  for (final c in items) {
    final name = c['displayName'] as String?;
    final emails = c['emailAddresses'];
    if (emails is! List) continue;
    for (final e in emails) {
      if (e is! Map) continue;
      // Outlook contacts carry a per-address name that is often better than the
      // contact's own displayName (which can be a company or a nickname).
      _add(out, e['address'] as String?, (e['name'] as String?) ?? name,
          ContactSource.personal);
    }
  }
}

void _readGraphDirectoryUsers(String body, List<CachedContact> out) {
  for (final u in _graphValue(body)) {
    final address =
        (u['mail'] as String?) ?? (u['userPrincipalName'] as String?);
    _add(out, address, u['displayName'] as String?, ContactSource.directory);
  }
}

void _readGraphPeople(String body, List<CachedContact> out) {
  for (final p in _graphValue(body)) {
    final name = p['displayName'] as String?;
    final scored = p['scoredEmailAddresses'];
    if (scored is! List) continue;
    for (final e in scored) {
      if (e is! Map) continue;
      _add(out, e['address'] as String?, name, ContactSource.other);
    }
  }
}

/// Graph collections all wrap their items in a top-level `value` array.
List<Map<String, dynamic>> _graphValue(String body) {
  final data = _decodeObject(body);
  final value = data?['value'];
  if (value is! List) return const [];
  return value.whereType<Map<String, dynamic>>().toList();
}

// --- pagination (runs on the fetching isolate, not under compute) -----------

// Paging is inherently sequential — the next request needs the previous page's
// token — so it cannot move into the isolate with the rest of the parsing.
// These two scan the raw body for just the continuation token instead of
// decoding the whole page, which would put the cost this class exists to avoid
// straight back onto the caller.

final _googleTokenPattern = RegExp(r'"nextPageToken"\s*:\s*"([^"\\]+)"');
final _graphNextLinkPattern =
    RegExp(r'"@odata\.nextLink"\s*:\s*"((?:[^"\\]|\\.)+)"');

/// The `nextPageToken` in a raw Google People API page, or null on the last
/// page. Google's tokens are URL-safe base64, so they never contain an escape.
String? googleNextPageToken(String body) =>
    _googleTokenPattern.firstMatch(body)?.group(1);

/// The absolute `@odata.nextLink` URL in a raw Graph page, or null on the last
/// page. Graph escapes the separators inside that URL as JSON string escapes -
/// a slash as `\/` and an ampersand as `\u0026` - so both are unescaped here.
/// Following the link verbatim otherwise 400s on the request for the next page.
String? graphNextLink(String body) {
  // Written as two adjacent literals so the sequence is not itself read as a
  // Dart escape.
  const ampersandEscape = '\\' 'u0026';
  final raw = _graphNextLinkPattern.firstMatch(body)?.group(1);
  if (raw == null) return null;
  return raw.replaceAll(r'\/', '/').replaceAll(ampersandEscape, '&');
}

// --- shared -----------------------------------------------------------------

Map<String, dynamic>? _decodeObject(String body) {
  try {
    final decoded = jsonDecode(body);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    // A truncated or non-JSON page (an HTML error interstitial, say) loses that
    // page rather than the whole sync.
    return null;
  }
}

void _add(
  List<CachedContact> out,
  String? address,
  String? name,
  ContactSource source,
) {
  final a = address?.trim().toLowerCase();
  // Entra service principals and Google resource entries frequently have a
  // userPrincipalName that is not a routable address; requiring an @ with
  // something either side drops them.
  if (a == null || a.length < 3) return;
  final at = a.indexOf('@');
  if (at <= 0 || at == a.length - 1) return;
  out.add(CachedContact(
    address: a,
    name: (name ?? '').trim(),
    source: source,
  ));
}
