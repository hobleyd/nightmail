import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import 'auth_token.dart';

/// Asks the provider which mailbox a token answers for.
///
/// Used on every sign-in for an account that already exists, *before* the
/// token is stored (see `sign_in_identity.dart`), and once when a Gmail
/// account is added, to learn its address. Both implementations talk to the
/// provider with the token under test itself rather than through the
/// account's HTTP client — that client reads whatever token is currently
/// stored, which is the old one, and would vouch for it.
abstract interface class SignedInMailboxLookup {
  /// The addresses this mailbox receives mail at: its primary address first,
  /// then any aliases the provider lists. Empty when the provider could not
  /// say — a network failure, a token without the scope — which callers must
  /// read as "unknown", never as "nobody".
  Future<List<String>> addressesFor(AuthToken token);

  /// The same answer, asked through [http]: a client that signs its own
  /// requests from the account's stored credentials (an `AuthInterceptor`
  /// pipeline), so no token is passed. For learning a stored account's
  /// addresses after the fact — see `AccountManager.ensureEmailPopulated` —
  /// where the token on disk may first need the refresh that client knows
  /// how to do.
  Future<List<String>> addressesWith(Dio http);
}

/// Gmail: `users.getProfile` for the primary address, `settings.sendAs` for
/// the aliases. Both accept the `gmail.modify` scope every account holds.
class GmailMailboxLookup implements SignedInMailboxLookup {
  GmailMailboxLookup({Dio? http}) : _http = http ?? Dio();

  final Dio _http;

  static const _base = 'https://gmail.googleapis.com/gmail/v1/users/me';

  @override
  Future<List<String>> addressesFor(AuthToken token) =>
      _addresses(_http, _bearer(token));

  @override
  Future<List<String>> addressesWith(Dio http) => _addresses(http, null);

  Future<List<String>> _addresses(Dio http, Options? options) async {
    final addresses = <String>[];
    try {
      final response = await http.get<Map<String, dynamic>>(
        '$_base/profile',
        options: options,
      );
      _add(addresses, response.data?['emailAddress']);
    } catch (e) {
      debugPrint('[SignIn] Gmail profile lookup failed: $e');
      return const [];
    }
    if (addresses.isEmpty) return const [];

    // Aliases are a nicety — an account recorded under one must still match
    // — so a failure here costs nothing but that.
    try {
      final response = await http.get<Map<String, dynamic>>(
        '$_base/settings/sendAs',
        options: options,
      );
      for (final entry
          in response.data?['sendAs'] as List<dynamic>? ?? const []) {
        if (entry is Map) _add(addresses, entry['sendEmail']);
      }
    } catch (e) {
      debugPrint('[SignIn] Gmail sendAs lookup failed: $e');
    }
    return addresses;
  }
}

/// Microsoft: `/me`. `mail` is the mailbox's primary SMTP address and
/// `userPrincipalName` is what the user signs in with — the two differ in
/// many tenants, and either may be what an account was recorded under —
/// while `proxyAddresses` carries the aliases as `smtp:` entries.
class GraphMailboxLookup implements SignedInMailboxLookup {
  GraphMailboxLookup({Dio? http}) : _http = http ?? Dio();

  final Dio _http;

  static const _url = 'https://graph.microsoft.com/v1.0/me';

  @override
  Future<List<String>> addressesFor(AuthToken token) =>
      _addresses(_http, _bearer(token));

  @override
  Future<List<String>> addressesWith(Dio http) => _addresses(http, null);

  Future<List<String>> _addresses(Dio http, Options? options) async {
    try {
      final response = await http.get<Map<String, dynamic>>(
        _url,
        queryParameters: {
          r'$select': 'mail,userPrincipalName,proxyAddresses',
        },
        options: options,
      );
      final data = response.data ?? const <String, dynamic>{};
      final addresses = <String>[];
      _add(addresses, data['mail']);
      _add(addresses, data['userPrincipalName']);
      for (final entry
          in data['proxyAddresses'] as List<dynamic>? ?? const []) {
        // `smtp:alias@contoso.com`. The prefix is the address type — SIP and
        // X500 entries ride in the same list and are not mail addresses.
        if (entry is! String) continue;
        final colon = entry.indexOf(':');
        if (colon == -1) continue;
        if (entry.substring(0, colon).toLowerCase() != 'smtp') continue;
        _add(addresses, entry.substring(colon + 1));
      }
      return addresses;
    } catch (e) {
      debugPrint('[SignIn] Graph profile lookup failed: $e');
      return const [];
    }
  }
}

Options _bearer(AuthToken token) => Options(
      headers: {'Authorization': '${token.tokenType} ${token.accessToken}'},
    );

/// Appends [value] when it is a non-empty string not already present,
/// compared case-insensitively.
void _add(List<String> into, Object? value) {
  if (value is! String) return;
  final address = value.trim();
  if (address.isEmpty) return;
  final lower = address.toLowerCase();
  if (into.any((a) => a.toLowerCase() == lower)) return;
  into.add(address);
}
