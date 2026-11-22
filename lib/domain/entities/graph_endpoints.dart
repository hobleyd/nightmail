import 'package:equatable/equatable.dart';

/// Where a Microsoft Graph account sends its API calls and signs in: Microsoft
/// itself, or a NightMail Server (Nightware) that speaks the same subset of
/// Graph and runs its own OAuth authorization server.
///
/// One per account. A Microsoft 365 account stores none and is given
/// [GraphEndpoints.microsoft] built from its tenant — the default is derived
/// rather than persisted, so an account saved before this existed loads, and
/// saves again, exactly as it always did. A NightMail Server account stores
/// the configuration its server published at `/.well-known/nightware` (see
/// `NightwareDiscoveryDatasource`), and behaves like any other Graph account
/// apart from where its requests go and what it asks for at sign-in.
class GraphEndpoints extends Equatable {
  const GraphEndpoints({
    required this.graphBaseUrl,
    required this.graphBetaBaseUrl,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.clientId,
    this.scopes,
    this.serverUrl,
    this.filesBaseUrls = const [],
    this.changesUrl,
  });

  /// Microsoft's own endpoints for [tenantId] — byte-for-byte what was
  /// hardcoded before endpoints were configurable. [clientId] and [scopes]
  /// stay null: the account (or `AppConfig`) supplies the client, and
  /// `MicrosoftAuthService` keeps the Graph scope list, with the incremental
  /// scopes that only make sense against Microsoft.
  factory GraphEndpoints.microsoft({String tenantId = 'common'}) {
    final authority = microsoftAuthority(tenantId);
    return GraphEndpoints(
      graphBaseUrl: microsoftGraphBaseUrl,
      graphBetaBaseUrl: microsoftGraphBetaBaseUrl,
      authorizationEndpoint: '$authority/authorize',
      tokenEndpoint: '$authority/token',
    );
  }

  /// Microsoft Graph's host — what a continuation link on a Microsoft
  /// account must be on (`isGraphUrl`).
  static const microsoftGraphHost = 'graph.microsoft.com';
  static const microsoftGraphBaseUrl = 'https://$microsoftGraphHost/v1.0';
  static const microsoftGraphBetaBaseUrl = 'https://$microsoftGraphHost/beta';

  /// The Microsoft identity platform's v2.0 authority for a tenant (`common`,
  /// `organizations`, a tenant GUID or domain).
  static String microsoftAuthority(String tenantId) =>
      'https://login.microsoftonline.com/$tenantId/oauth2/v2.0';

  /// Graph v1.0 root, no trailing slash — the `GraphHttpClient`'s base URL.
  final String graphBaseUrl;

  /// Graph beta root, no trailing slash. A few calls only exist there (threat
  /// submission, `findRooms`).
  final String graphBetaBaseUrl;

  /// OAuth 2.0 authorization endpoint the PKCE sign-in opens in the browser.
  final String authorizationEndpoint;

  /// OAuth 2.0 token endpoint for the code exchange and every refresh.
  final String tokenEndpoint;

  /// The client id the server issued, or null for Microsoft, whose client id
  /// is per account (`MicrosoftAccount.clientId`) or compiled in.
  final String? clientId;

  /// Exactly what a sign-in and a refresh ask for, or null for Microsoft's
  /// own Graph scope list.
  final List<String>? scopes;

  /// The address of the NightMail Server these came from, as the user's input
  /// was normalised; null for Microsoft.
  final String? serverUrl;

  /// Public base URLs of the NightMail Server's file sites (its Nextcloud,
  /// e.g. `https://cloud.example.com`), no trailing slash. A
  /// `{base}/s/{token}` or `{base}/f/{fileId}` link in a message body is
  /// previewed through this server's `/shares` — the same route a
  /// SharePoint link takes on Microsoft — but only on these hosts, so the
  /// link scanner never claims a Nextcloud it was not told about. Empty for
  /// Microsoft, for a server that does not publish any, and for an account
  /// discovered before servers could (the feature is simply off there).
  final List<String> filesBaseUrls;

  /// The NightMail Server's change stream (nightware ADR 0007): a
  /// Server-Sent Events URL that says when this account's mail or calendar
  /// changed, so the poller syncs then rather than at its next tick. Null for
  /// Microsoft, for a server that does not publish one, and for an account
  /// discovered before servers could — the poller's timer alone then, as
  /// always. Only ever on [graphBaseUrl]'s scheme, host and port, because it
  /// is opened with the account's bearer token
  /// (`GraphEndpointsModel.fromDiscoveryJson` drops any other).
  final String? changesUrl;

  /// These endpoints with the optional features [rediscovered] now publishes
  /// — its file sites and its change stream — when it is still the same
  /// sign-in and sync configuration; otherwise these, unchanged. Only those
  /// are adopted: a server that moved its Graph root, token endpoint, client
  /// or scopes needs a fresh sign-in, which a silent rewrite of stored
  /// endpoints would only turn into a confusing 401.
  GraphEndpoints withPublishedFeaturesFrom(GraphEndpoints rediscovered) {
    if (signInChangeFrom(rediscovered) != null ||
        (_sameList(filesBaseUrls, rediscovered.filesBaseUrls) &&
            changesUrl == rediscovered.changesUrl)) {
      return this;
    }
    return GraphEndpoints(
      graphBaseUrl: graphBaseUrl,
      graphBetaBaseUrl: graphBetaBaseUrl,
      authorizationEndpoint: authorizationEndpoint,
      tokenEndpoint: tokenEndpoint,
      clientId: clientId,
      scopes: scopes,
      serverUrl: serverUrl,
      filesBaseUrls: List.unmodifiable(rediscovered.filesBaseUrls),
      changesUrl: rediscovered.changesUrl,
    );
  }

  /// The first sign-in or sync setting [rediscovered] no longer agrees with
  /// these on, by its discovery field name, or null when it is the same
  /// configuration. Non-null is why [withPublishedFeaturesFrom] adopts
  /// nothing.
  String? signInChangeFrom(GraphEndpoints rediscovered) {
    if (graphBaseUrl != rediscovered.graphBaseUrl) return 'graphBaseUrl';
    if (graphBetaBaseUrl != rediscovered.graphBetaBaseUrl) {
      return 'graphBetaBaseUrl';
    }
    if (authorizationEndpoint != rediscovered.authorizationEndpoint) {
      return 'authorizationEndpoint';
    }
    if (tokenEndpoint != rediscovered.tokenEndpoint) return 'tokenEndpoint';
    if (clientId != rediscovered.clientId) return 'clientId';
    if (!_sameList(scopes, rediscovered.scopes)) return 'scopes';
    return null;
  }

  static bool _sameList(List<String>? a, List<String>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Whether these are Microsoft's endpoints. Features that only exist there —
  /// threat submission, SharePoint/OneDrive previews, incremental Graph
  /// consent — check this.
  bool get isMicrosoft => serverUrl == null;

  @override
  List<Object?> get props => [
        graphBaseUrl,
        graphBetaBaseUrl,
        authorizationEndpoint,
        tokenEndpoint,
        clientId,
        scopes,
        serverUrl,
        filesBaseUrls,
        changesUrl,
      ];
}
