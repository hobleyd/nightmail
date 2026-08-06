import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/remote/graph_api_datasource_impl.dart';
import 'package:nightmail/infrastructure/auth/auth_service.dart';
import 'package:nightmail/infrastructure/auth/auth_token.dart';
import 'package:nightmail/infrastructure/auth/gmail_auth_service.dart';
import 'package:nightmail/infrastructure/auth/microsoft_auth_service.dart';
import 'package:nightmail/infrastructure/auth/token_refresh_error.dart';
import 'package:nightmail/infrastructure/auth/token_storage.dart';
import 'package:nightmail/infrastructure/http/auth_interceptor.dart';

/// Being offline is not a credential problem. A token refresh that never
/// reached the OAuth endpoint must surface as [NetworkException], because an
/// [AuthException] out of a refresh is what makes `AuthInterceptor` flag the
/// account for re-authentication and `AuthBloc` discard the stored token.
///
/// The shape that motivated this: a laptop resuming before its network is up
/// produced `AuthException: Token refresh failed: The connection errored:
/// Failed host lookup: 'oauth2.googleapis.com'`, and asked the user to sign in
/// again to fix a DNS lookup.
void main() {
  /// The DioException Dio raises for a DNS failure, message template included.
  DioException dnsFailure([String host = 'oauth2.googleapis.com']) =>
      DioException.connectionError(
        requestOptions: RequestOptions(path: '/token'),
        reason: "Failed host lookup: '$host'",
      );

  DioException timeout(DioExceptionType type) => DioException(
        requestOptions: RequestOptions(path: '/token'),
        type: type,
      );

  DioException rejected(String error, String description) => DioException(
        requestOptions: RequestOptions(path: '/token'),
        type: DioExceptionType.badResponse,
        response: Response(
          statusCode: 400,
          requestOptions: RequestOptions(path: '/token'),
          data: {'error': error, 'error_description': description},
        ),
      );

  group('tokenRefreshFailure', () {
    test('a DNS failure is a transport failure, not a credential one', () {
      final result = tokenRefreshFailure(dnsFailure(), 'no dns');

      expect(result, isA<NetworkException>());
      expect(result, isNot(isA<AuthException>()));
    });

    test('every flavour of not-getting-there is a transport failure', () {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      ]) {
        expect(tokenRefreshFailure(timeout(type), 'slow'), isA<NetworkException>(),
            reason: '$type should not accuse the credentials');
      }
    });

    test('a rejection from the token endpoint stays a credential failure — the '
        'endpoint saw the refresh token and refused it', () {
      final result = tokenRefreshFailure(
        rejected('invalid_grant', 'Token has been expired or revoked.'),
        'Token has been expired or revoked.',
      );

      expect(result, isA<AuthException>());
      expect((result as AuthException).message, contains('Token refresh failed'));
    });

    test('an unclassifiable failure stays a credential failure, so a genuinely '
        'revoked token is never mistaken for a network blip', () {
      expect(
        tokenRefreshFailure(
          DioException(
            requestOptions: RequestOptions(path: '/token'),
            type: DioExceptionType.unknown,
          ),
          'something else',
        ),
        isA<AuthException>(),
      );
    });
  });

  group('GmailAuthService.refreshToken', () {
    test('throws NetworkException when the token endpoint cannot be resolved',
        () async {
      final storage = _FakeTokenStorage('gmail_dns', _staleToken());
      final service = GmailAuthService(
        clientId: 'id',
        clientSecret: 'secret',
        redirectUri: 'http://localhost',
        tokenStorage: storage,
        httpClient: _dioThrowing(dnsFailure()),
      );

      await expectLater(
        service.refreshToken(_staleToken()),
        throwsA(isA<NetworkException>()),
      );
      // The refresh token was never spent, so it must still be there to retry.
      expect((await storage.loadToken())?.refreshToken, 'refresh-me');
    });

    test('throws AuthException when Google rejects the refresh token', () async {
      final service = GmailAuthService(
        clientId: 'id',
        clientSecret: 'secret',
        redirectUri: 'http://localhost',
        tokenStorage: _FakeTokenStorage('gmail_revoked', _staleToken()),
        httpClient: _dioResponding(
          400,
          {'error': 'invalid_grant', 'error_description': 'Token revoked.'},
        ),
      );

      await expectLater(
        service.refreshToken(_staleToken()),
        throwsA(isA<AuthException>()),
      );
    });
  });

  group('MicrosoftAuthService.refreshToken', () {
    test('throws NetworkException when the token endpoint cannot be resolved',
        () async {
      final service = MicrosoftAuthService(
        clientId: 'id',
        tenantId: 'common',
        redirectUri: 'http://localhost',
        tokenStorage: _FakeTokenStorage('graph_dns', _staleToken()),
        httpClient: _dioThrowing(dnsFailure('login.microsoftonline.com')),
      );

      await expectLater(
        service.refreshToken(_staleToken()),
        throwsA(isA<NetworkException>()),
      );
    });

    test('throws AuthException when Azure rejects the refresh token', () async {
      final service = MicrosoftAuthService(
        clientId: 'id',
        tenantId: 'common',
        redirectUri: 'http://localhost',
        tokenStorage: _FakeTokenStorage('graph_revoked', _staleToken()),
        httpClient: _dioResponding(
          400,
          {'error': 'invalid_grant', 'error_description': 'Token revoked.'},
        ),
      );

      await expectLater(
        service.refreshToken(_staleToken()),
        throwsA(isA<AuthException>()),
      );
    });
  });

  group('AuthInterceptor', () {
    /// A Dio wired the way every account's client is, with [refresh] standing in
    /// for the auth service's refresh call.
    ({Dio dio, List<String> events}) client({
      required AuthToken stored,
      required Future<AuthToken> Function() refresh,
      int responseStatus = 200,
    }) {
      final events = <String>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://graph.microsoft.com/v1.0'));
      dio.httpClientAdapter = _StubAdapter(
        (_) async => ResponseBody.fromString(
          '{}',
          responseStatus,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      dio.interceptors.add(AuthInterceptor(
        authService: _FakeAuthService(stored: stored, onRefresh: refresh),
        dio: dio,
        onAuthFailure: () => events.add('failure'),
        onAuthSuccess: () => events.add('success'),
      ));
      return (dio: dio, events: events);
    }

    test('does not flag the account when the proactive refresh finds no network',
        () async {
      final c = client(
        stored: _staleToken(),
        refresh: () async =>
            throw const NetworkException(message: 'no dns'),
      );

      await expectLater(c.dio.get<void>('/me'), throwsA(isA<DioException>()));
      expect(c.events, isEmpty);
    });

    test('flags the account when the proactive refresh is rejected', () async {
      final c = client(
        stored: _staleToken(),
        refresh: () async => throw const AuthException(message: 'invalid_grant'),
      );

      await expectLater(c.dio.get<void>('/me'), throwsA(isA<DioException>()));
      expect(c.events, ['failure']);
    });

    test('does not flag the account when the refresh a 401 triggers finds no '
        'network — the 401 may simply be the stale token we could not renew',
        () async {
      final c = client(
        stored: _freshToken(),
        responseStatus: 401,
        refresh: () async => throw const NetworkException(message: 'no dns'),
      );

      await expectLater(c.dio.get<void>('/me'), throwsA(isA<DioException>()));
      expect(c.events, isEmpty);
    });

    test('flags the account when the refresh a 401 triggers is rejected',
        () async {
      final c = client(
        stored: _freshToken(),
        responseStatus: 401,
        refresh: () async => throw const AuthException(message: 'invalid_grant'),
      );

      await expectLater(c.dio.get<void>('/me'), throwsA(isA<DioException>()));
      expect(c.events, ['failure']);
    });
  });

  group('datasource mapping', () {
    test('a NetworkException thrown by the interceptor reaches the caller as '
        'itself, not as a ServerException carrying Dio boilerplate', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://graph.microsoft.com/v1.0'));
      dio.interceptors.add(AuthInterceptor(
        authService: _FakeAuthService(
          stored: _staleToken(),
          onRefresh: () async =>
              throw const NetworkException(message: 'Could not reach it'),
        ),
        dio: dio,
      ));

      await expectLater(
        GraphApiDatasourceImpl.withDio(dio).deleteServerDraft(draftId: 'x'),
        throwsA(isA<NetworkException>()),
      );
    });
  });
}

/// A token due for renewal: `isAboutToExpire`, so a request triggers a
/// proactive refresh, but not yet expired.
AuthToken _staleToken() => AuthToken(
      accessToken: 'stale',
      expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      refreshToken: 'refresh-me',
    );

/// A token with plenty of life left, so only a 401 can trigger a refresh.
AuthToken _freshToken() => AuthToken(
      accessToken: 'fresh',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      refreshToken: 'refresh-me',
    );

Dio _dioThrowing(DioException error) => Dio()
  ..httpClientAdapter = _StubAdapter((_) async => throw error);

Dio _dioResponding(int status, Map<String, dynamic> body) => Dio()
  ..httpClientAdapter = _StubAdapter(
    (_) async => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    ),
  );

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

/// [TokenStorage] without the keychain (or the legacy-file migration, which
/// needs a path_provider binding the test has no use for).
class _FakeTokenStorage extends TokenStorage {
  _FakeTokenStorage(String key, this._token)
      : super(const FlutterSecureStorage(), storageKey: key);

  AuthToken? _token;

  @override
  Future<AuthToken?> loadToken() async => _token;

  @override
  Future<void> saveToken(AuthToken token) async => _token = token;

  @override
  Future<void> clearToken() async => _token = null;
}

class _FakeAuthService implements AuthService {
  _FakeAuthService({required this.stored, required this.onRefresh});

  final AuthToken stored;
  final Future<AuthToken> Function() onRefresh;

  @override
  Future<AuthToken?> getStoredToken() async => stored;

  @override
  Future<AuthToken> refreshToken(AuthToken currentToken) => onRefresh();

  @override
  Future<AuthToken> signIn() => throw UnimplementedError();

  @override
  Future<void> signOut() async {}
}
