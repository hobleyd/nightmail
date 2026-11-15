import '../../core/error/exceptions.dart';
import '../../domain/entities/graph_endpoints.dart';

/// JSON for [GraphEndpoints]: the discovery document a NightMail Server
/// publishes, and the copy kept on the account.
///
/// The two are parsed differently on purpose. Discovery is input from a
/// server the user just typed the address of, so it is validated strictly and
/// every problem is a [ServerException] the add-account screen can show.
/// Storage is our own output, read inside `AccountStorage.loadAccounts` —
/// whose catch-all returns *no accounts at all* on any throw — so it never
/// throws, and validation there would only turn one odd field into every
/// account vanishing.
abstract final class GraphEndpointsModel {
  /// Where a server publishes its configuration, relative to its address.
  static const discoveryPath = '/.well-known/nightware';

  /// Parses and validates a `/.well-known/nightware` document fetched from
  /// [serverUrl]. Every field is required:
  ///
  /// ```json
  /// {
  ///   "graphBaseUrl": "https://mail.example.com/graph/v1.0",
  ///   "graphBetaBaseUrl": "https://mail.example.com/graph/beta",
  ///   "authorizationEndpoint": "https://mail.example.com/oauth2/authorize",
  ///   "tokenEndpoint": "https://mail.example.com/oauth2/token",
  ///   "clientId": "nightmail",
  ///   "scopes": ["openid", "email", "profile", "offline_access"],
  ///   "filesBaseUrls": ["https://cloud.example.com"]
  /// }
  /// ```
  ///
  /// `filesBaseUrls` is the one optional field (see
  /// [GraphEndpoints.filesBaseUrls]), and it is read leniently: an entry that
  /// is not an absolute http(s) URL is dropped rather than refusing the whole
  /// document, because a server's file sites are a preview nicety and must
  /// never be the reason an account cannot be added.
  ///
  /// URLs must be absolute `https` — or `http` to a loopback host, for a
  /// server on the same machine — because every one of them is handed the
  /// account's tokens. Unknown fields are ignored so a server can add more.
  static GraphEndpoints fromDiscoveryJson(
    Object? json, {
    required String serverUrl,
  }) {
    if (json is! Map<String, dynamic>) {
      throw const ServerException(
          message: 'The server did not return a NightMail Server '
              'configuration (expected a JSON object).');
    }

    String url(String field) {
      final value = json[field];
      if (value is! String || value.trim().isEmpty) {
        throw ServerException(
            message: 'The server configuration is missing "$field".');
      }
      final trimmed = _stripTrailingSlash(value.trim());
      if (!isAcceptableEndpoint(trimmed)) {
        throw ServerException(
            message: 'The server configuration\'s "$field" must be an '
                'absolute https URL: $trimmed');
      }
      return trimmed;
    }

    final clientId = json['clientId'];
    if (clientId is! String || clientId.trim().isEmpty) {
      throw const ServerException(
          message: 'The server configuration is missing "clientId".');
    }

    final rawScopes = json['scopes'];
    if (rawScopes is! List ||
        rawScopes.isEmpty ||
        rawScopes.any((s) => s is! String || s.trim().isEmpty)) {
      throw const ServerException(
          message: 'The server configuration\'s "scopes" must be a '
              'non-empty list of strings.');
    }

    return GraphEndpoints(
      graphBaseUrl: url('graphBaseUrl'),
      graphBetaBaseUrl: url('graphBetaBaseUrl'),
      authorizationEndpoint: url('authorizationEndpoint'),
      tokenEndpoint: url('tokenEndpoint'),
      clientId: clientId.trim(),
      scopes: List.unmodifiable(rawScopes.cast<String>().map((s) => s.trim())),
      serverUrl: serverUrl,
      filesBaseUrls: _filesBaseUrls(json['filesBaseUrls']),
    );
  }

  /// The usable entries of an optional `filesBaseUrls` list: absolute http(s)
  /// URLs with a host and no query or fragment, trailing slashes stripped.
  /// No tokens are ever sent to them — they only decide which links in a body
  /// are this server's — so plain `http` is as acceptable as the server says.
  static List<String> _filesBaseUrls(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final entry in raw) {
      if (entry is! String) continue;
      final trimmed = _stripTrailingSlash(entry.trim());
      final uri = Uri.tryParse(trimmed);
      if (uri == null ||
          !uri.isAbsolute ||
          uri.host.isEmpty ||
          !(uri.isScheme('https') || uri.isScheme('http')) ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.userInfo.isNotEmpty) {
        continue;
      }
      if (!out.contains(trimmed)) out.add(trimmed);
    }
    return List.unmodifiable(out);
  }

  /// What a user typed as a server address, as the address discovery is
  /// fetched from: trimmed, `https://` assumed when no scheme is given, no
  /// trailing slash. Null when it cannot be a server address at all — no
  /// host, a scheme other than http(s), or plain `http` to anything but this
  /// machine.
  static String? normaliseServerUrl(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.hasQuery || uri.hasFragment) return null;
    final normalised = _stripTrailingSlash(uri.toString());
    return isAcceptableEndpoint(normalised) ? normalised : null;
  }

  /// Whether [url] may be sent this account's tokens: absolute `https`, or
  /// `http` to a loopback host.
  static bool isAcceptableEndpoint(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isAbsolute || uri.host.isEmpty) return false;
    if (uri.scheme == 'https') return true;
    return uri.scheme == 'http' && _isLoopback(uri.host);
  }

  static bool _isLoopback(String host) {
    final h = host.toLowerCase();
    return h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '[::1]';
  }

  static String _stripTrailingSlash(String s) {
    var out = s;
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  /// The copy stored on the account (`MicrosoftAccount.server`).
  static Map<String, dynamic> toStorageJson(GraphEndpoints endpoints) => {
        if (endpoints.serverUrl != null) 'serverUrl': endpoints.serverUrl,
        'graphBaseUrl': endpoints.graphBaseUrl,
        'graphBetaBaseUrl': endpoints.graphBetaBaseUrl,
        'authorizationEndpoint': endpoints.authorizationEndpoint,
        'tokenEndpoint': endpoints.tokenEndpoint,
        if (endpoints.clientId != null) 'clientId': endpoints.clientId,
        if (endpoints.scopes != null) 'scopes': endpoints.scopes,
        if (endpoints.filesBaseUrls.isNotEmpty)
          'filesBaseUrls': endpoints.filesBaseUrls,
      };

  /// Reads [toStorageJson]'s output back. Never throws — see the class doc.
  static GraphEndpoints fromStorageJson(Map<String, dynamic> json) {
    String str(String key) => json[key] is String ? json[key] as String : '';
    final scopes = json['scopes'];
    return GraphEndpoints(
      serverUrl: json['serverUrl'] is String ? json['serverUrl'] as String : '',
      graphBaseUrl: str('graphBaseUrl'),
      graphBetaBaseUrl: str('graphBetaBaseUrl'),
      authorizationEndpoint: str('authorizationEndpoint'),
      tokenEndpoint: str('tokenEndpoint'),
      clientId: json['clientId'] is String ? json['clientId'] as String : null,
      scopes: scopes is List ? scopes.whereType<String>().toList() : null,
      filesBaseUrls: _filesBaseUrls(json['filesBaseUrls']),
    );
  }
}
