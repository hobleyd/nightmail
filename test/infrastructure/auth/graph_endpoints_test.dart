import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/contact_bulk_parser.dart';
import 'package:nightmail/data/datasources/remote/graph_api_datasource_impl.dart';
import 'package:nightmail/data/datasources/remote/graph_message_parser.dart';
import 'package:nightmail/domain/entities/graph_endpoints.dart';
import 'package:nightmail/infrastructure/auth/auth_token.dart';
import 'package:nightmail/infrastructure/auth/microsoft_auth_service.dart';
import 'package:nightmail/infrastructure/auth/signed_in_mailbox_lookup.dart';
import 'package:nightmail/infrastructure/auth/token_storage.dart';
import 'package:nightmail/infrastructure/http/graph_http_client.dart';

/// A Graph account's endpoints are configurable so it can live on a NightMail
/// Server — and the Microsoft default must stay exactly what was hardcoded
/// before, or every existing Microsoft 365 account changes under its user.
void main() {
  const server = GraphEndpoints(
    graphBaseUrl: 'https://mail.example.com/graph/v1.0',
    graphBetaBaseUrl: 'https://mail.example.com/graph/beta',
    authorizationEndpoint: 'https://mail.example.com/oauth2/authorize',
    tokenEndpoint: 'https://mail.example.com/oauth2/token',
    clientId: 'nightmail',
    scopes: ['openid', 'email', 'profile', 'offline_access'],
    serverUrl: 'https://mail.example.com',
  );

  group('withPublishedFeaturesFrom', () {
    GraphEndpoints rediscovered({
      String tokenEndpoint = 'https://mail.example.com/oauth2/token',
      List<String>? scopes = const [
        'openid',
        'email',
        'profile',
        'offline_access',
      ],
      List<String> files = const ['https://cloud.example.com'],
    }) =>
        GraphEndpoints(
          graphBaseUrl: server.graphBaseUrl,
          graphBetaBaseUrl: server.graphBetaBaseUrl,
          authorizationEndpoint: server.authorizationEndpoint,
          tokenEndpoint: tokenEndpoint,
          clientId: server.clientId,
          scopes: scopes,
          serverUrl: 'https://other-input.example.com',
          filesBaseUrls: files,
        );

    test('adopts the file sites and keeps everything else as stored', () {
      final updated = server.withPublishedFeaturesFrom(rediscovered());

      expect(updated.filesBaseUrls, ['https://cloud.example.com']);
      expect(updated.serverUrl, server.serverUrl);
      expect(updated.tokenEndpoint, server.tokenEndpoint);
    });

    test('a server that stopped publishing file sites turns them off', () {
      final withSites = server.withPublishedFeaturesFrom(rediscovered());

      expect(
          withSites
              .withPublishedFeaturesFrom(rediscovered(files: const []))
              .filesBaseUrls,
          isEmpty);
    });

    test('returns itself when nothing changed or the server moved', () {
      expect(
          identical(
              server.withPublishedFeaturesFrom(rediscovered(files: const [])), server),
          isTrue);
      expect(
          identical(
              server.withPublishedFeaturesFrom(
                  rediscovered(tokenEndpoint: 'https://elsewhere/token')),
              server),
          isTrue);
      expect(
          identical(server.withPublishedFeaturesFrom(rediscovered(scopes: null)),
              server),
          isTrue);
    });
  });

  group('GraphEndpoints.microsoft', () {
    test('is the previously hardcoded Graph and authority URLs', () {
      final ms = GraphEndpoints.microsoft(tenantId: 'contoso-tenant');
      expect(ms.graphBaseUrl, 'https://graph.microsoft.com/v1.0');
      expect(ms.graphBetaBaseUrl, 'https://graph.microsoft.com/beta');
      expect(ms.authorizationEndpoint,
          'https://login.microsoftonline.com/contoso-tenant/oauth2/v2.0/authorize');
      expect(ms.tokenEndpoint,
          'https://login.microsoftonline.com/contoso-tenant/oauth2/v2.0/token');
      expect(ms.clientId, isNull);
      expect(ms.scopes, isNull);
      expect(ms.isMicrosoft, isTrue);
    });

    test('defaults to the common tenant', () {
      expect(GraphEndpoints.microsoft().tokenEndpoint,
          'https://login.microsoftonline.com/common/oauth2/v2.0/token');
    });

    test('a server configuration is not Microsoft', () {
      expect(server.isMicrosoft, isFalse);
    });
  });

  group('MicrosoftAuthService endpoints', () {
    MicrosoftAuthService service({
      GraphEndpoints? endpoints,
      List<String> extraScopes = const [],
      Dio? http,
      TokenStorage? storage,
    }) =>
        MicrosoftAuthService(
          clientId: 'client',
          tenantId: 'contoso-tenant',
          redirectUri: 'nightmail://auth-callback',
          tokenStorage: storage ?? _RecordingTokenStorage(),
          extraScopes: extraScopes,
          endpoints: endpoints,
          httpClient: http,
        );

    test('with no endpoints given, signs in at Microsoft for its tenant', () {
      final svc = service(
          extraScopes: const [MicrosoftAuthService.filesReadScope]);
      expect(svc.endpoints, GraphEndpoints.microsoft(tenantId: 'contoso-tenant'));
      final uri = svc.buildAuthorizationUri(codeChallenge: 'cc', state: 'st');
      expect('${uri.scheme}://${uri.host}${uri.path}',
          'https://login.microsoftonline.com/contoso-tenant/oauth2/v2.0/authorize');
      expect(uri.queryParameters['scope'], [
        ...MicrosoftAuthService.baseScopes,
        MicrosoftAuthService.filesReadScope,
      ].join(' '));
      expect(uri.queryParameters['client_id'], 'client');
      expect(uri.queryParameters['state'], 'st');
      expect(uri.queryParameters['code_challenge_method'], 'S256');
      expect(uri.queryParameters['response_mode'], 'query');
    });

    test('a server account opens the server\'s authorization endpoint and '
        'asks for exactly the published scopes', () {
      final svc = service(
        endpoints: server,
        // Graph-only incremental scopes have no meaning there.
        extraScopes: const [MicrosoftAuthService.filesReadScope],
      );
      final uri = svc.buildAuthorizationUri(codeChallenge: 'cc', state: 'st');
      expect('${uri.scheme}://${uri.host}${uri.path}',
          'https://mail.example.com/oauth2/authorize');
      expect(uri.queryParameters['scope'],
          'openid email profile offline_access');
      expect(uri.queryParameters['state'], 'st');
      expect(uri.queryParameters['code_challenge'], 'cc');
    });

    test('the code is exchanged at the configured token endpoint', () async {
      final seen = <RequestOptions>[];
      await service(endpoints: server, http: _tokenEndpoint(seen))
          .exchangeCodeForToken(code: 'code', codeVerifier: 'verifier');
      expect(seen.single.uri.toString(), server.tokenEndpoint);
      expect((seen.single.data as Map)['grant_type'], 'authorization_code');
    });

    test('the Microsoft default still exchanges at login.microsoftonline.com',
        () async {
      final seen = <RequestOptions>[];
      await service(http: _tokenEndpoint(seen))
          .exchangeCodeForToken(code: 'code', codeVerifier: 'verifier');
      expect(seen.single.uri.toString(),
          'https://login.microsoftonline.com/contoso-tenant/oauth2/v2.0/token');
    });

    test('a refresh goes to the configured token endpoint with the '
        'published scopes only', () async {
      final seen = <RequestOptions>[];
      final svc = service(
        endpoints: server,
        http: _tokenEndpoint(seen),
        storage: _RecordingTokenStorage(key: 'token_refresh_server'),
      );
      // A token that somehow claims a Graph incremental scope still refreshes
      // with only what the server published.
      await svc.refreshToken(_token('openid Files.Read.All'));
      expect(seen.single.uri.toString(), server.tokenEndpoint);
      final data = seen.single.data as Map;
      expect(data['grant_type'], 'refresh_token');
      expect(data['scope'], 'openid email profile offline_access');
      expect(svc.refreshScopesFor(_token('Files.Read.All')), server.scopes);
    });

    test('the Microsoft refresh scopes are unchanged', () {
      expect(service().refreshScopesFor(_token('Mail.Read Files.Read.All')), [
        ...MicrosoftAuthService.baseScopes,
        MicrosoftAuthService.filesReadScope,
      ]);
    });
  });

  group('GraphHttpClient base URL', () {
    MicrosoftAuthService auth() => MicrosoftAuthService(
          clientId: 'c',
          tenantId: 'common',
          redirectUri: 'nightmail://auth-callback',
          tokenStorage: _RecordingTokenStorage(),
        );

    test('defaults to Microsoft Graph v1.0', () {
      expect(GraphHttpClient(authService: auth()).dio.options.baseUrl,
          'https://graph.microsoft.com/v1.0');
    });

    test('takes the account\'s Graph root', () {
      expect(
        GraphHttpClient(authService: auth(), baseUrl: server.graphBaseUrl)
            .dio
            .options
            .baseUrl,
        'https://mail.example.com/graph/v1.0',
      );
    });

    test('the datasource reports both roots', () {
      final ds = GraphApiDatasourceImpl(
        client: GraphHttpClient(
            authService: auth(), baseUrl: server.graphBaseUrl),
        betaBaseUrl: server.graphBetaBaseUrl,
      );
      expect(ds.graphRoots,
          (v1: server.graphBaseUrl, beta: server.graphBetaBaseUrl));
      final ms = GraphApiDatasourceImpl(client: GraphHttpClient(authService: auth()));
      expect(ms.graphRoots, (
        v1: 'https://graph.microsoft.com/v1.0',
        beta: 'https://graph.microsoft.com/beta',
      ));
    });
  });

  group('beta calls use the account\'s beta root', () {
    test('findRooms falls back to <beta>/me/findRooms', () async {
      final seen = <String>[];
      final dio = Dio(BaseOptions(baseUrl: server.graphBaseUrl));
      dio.httpClientAdapter = _StubAdapter((options) async {
        seen.add(options.uri.toString());
        if (options.uri.path.endsWith('/findRooms')) {
          return _json({
            'value': [
              {'name': 'Board', 'address': 'board@example.com'},
            ],
          });
        }
        return _json({'error': 'forbidden'}, status: 403);
      });
      final ds = GraphApiDatasourceImpl.withDio(dio,
          graphBaseUrl: server.graphBaseUrl,
          betaBaseUrl: server.graphBetaBaseUrl);
      final rooms = await ds.getMeetingRooms();
      expect(rooms.single.email, 'board@example.com');
      expect(seen, contains('https://mail.example.com/graph/beta/me/findRooms'));
      expect(seen.where((u) => u.contains('graph.microsoft.com')), isEmpty);
    });

    test('a threat submission posts to <beta>/security/...', () async {
      final seen = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: server.graphBaseUrl));
      dio.httpClientAdapter = _StubAdapter((options) async {
        seen.add(options);
        return _json({'id': 'user-guid', 'mail': 'me@example.com'});
      });
      final ds = GraphApiDatasourceImpl.withDio(dio,
          graphBaseUrl: server.graphBaseUrl,
          betaBaseUrl: server.graphBetaBaseUrl);
      await ds.submitPhishingReport('m1');
      final post = seen.singleWhere((o) => o.method == 'POST');
      expect(post.uri.toString(),
          'https://mail.example.com/graph/beta/security/threatSubmission/emailThreats');
      expect((post.data as Map)['messageUrl'],
          'https://mail.example.com/graph/beta/users/user-guid/messages/m1');
    });
  });

  group('GraphMailboxLookup asks the account\'s own Graph', () {
    test('a server account\'s token goes to the server, never Microsoft',
        () async {
      final seen = <String>[];
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter((options) async {
        seen.add(options.uri.toString().split('?').first);
        return _json({'mail': 'me@example.com'});
      });
      final addresses = await GraphMailboxLookup(
              http: dio, graphBaseUrl: server.graphBaseUrl)
          .addressesFor(_token('openid'));
      expect(addresses, ['me@example.com']);
      expect(seen, ['https://mail.example.com/graph/v1.0/me']);
    });

    test('defaults to Microsoft Graph', () async {
      final seen = <String>[];
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter((options) async {
        seen.add(options.uri.toString().split('?').first);
        return _json({'mail': 'me@contoso.com'});
      });
      await GraphMailboxLookup(http: dio).addressesFor(_token('openid'));
      expect(seen, ['https://graph.microsoft.com/v1.0/me']);
    });
  });

  group('continuation links are trusted only on the account\'s own origin', () {
    test('Microsoft rule is unchanged with no trusted base', () {
      expect(isGraphUrl('https://graph.microsoft.com/v1.0/me'), isTrue);
      expect(isGraphUrl('https://mail.example.com/graph/v1.0/me'), isFalse);
      expect(
          isGraphUrl('https://graph.microsoft.com/v1.0/me',
              trustedBaseUrl: 'https://graph.microsoft.com/v1.0'),
          isTrue);
      expect(isGraphUrl('https://graph.microsoft.com/v1.0/me',
          trustedBaseUrl: ''), isTrue);
    });

    test('a server account follows links back to itself only', () {
      const base = 'https://mail.example.com/graph/v1.0';
      expect(isGraphUrl('https://mail.example.com/graph/v1.0/me/x?a=1',
          trustedBaseUrl: base), isTrue);
      expect(isGraphUrl('https://graph.microsoft.com/v1.0/me',
          trustedBaseUrl: base), isFalse,
          reason: 'a server token must not be sent to Microsoft');
      expect(isGraphUrl('https://evil.example/graph/v1.0/me',
          trustedBaseUrl: base), isFalse);
      expect(isGraphUrl('http://mail.example.com/graph/v1.0/me',
          trustedBaseUrl: base), isFalse, reason: 'scheme downgrade');
      expect(isGraphUrl('https://mail.example.com:8443/graph/v1.0/me',
          trustedBaseUrl: base), isFalse, reason: 'another port');
    });

    test('next and delta links are read against the trusted base', () {
      const base = 'http://localhost:5000/graph/v1.0';
      const page = '{"value":[],'
          r'"@odata.nextLink":"http:\/\/localhost:5000\/graph\/v1.0\/me\/messages?$skip=10",'
          r'"@odata.deltaLink":"http:\/\/localhost:5000\/graph\/v1.0\/me\/delta?token=x"}';
      expect(graphNextLink(page, trustedBaseUrl: base),
          r'http://localhost:5000/graph/v1.0/me/messages?$skip=10');
      expect(graphDeltaLink(page, trustedBaseUrl: base),
          'http://localhost:5000/graph/v1.0/me/delta?token=x');
      expect(graphNextLink(page), isNull);
      expect(graphDeltaLink(page), isNull);
    });
  });
}

AuthToken _token(String scope) => AuthToken(
      accessToken: 'a',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      refreshToken: 'r',
      scope: scope,
    );

ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

Dio _tokenEndpoint(List<RequestOptions> seen) {
  final dio = Dio();
  dio.httpClientAdapter = _StubAdapter((options) async {
    seen.add(options);
    return _json({
      'access_token': 'fresh',
      'expires_in': 3600,
      'refresh_token': 'r2',
      'token_type': 'Bearer',
      'scope': 'openid',
    });
  });
  return dio;
}

class _RecordingTokenStorage extends TokenStorage {
  _RecordingTokenStorage({String key = 'token_test'})
      : super(const FlutterSecureStorage(), storageKey: key);

  @override
  Future<AuthToken?> loadToken() async => null;

  @override
  Future<void> saveToken(AuthToken token) async {}
}

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this._respond);

  final Future<ResponseBody> Function(RequestOptions) _respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      _respond(options);

  @override
  void close({bool force = false}) {}
}
