import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/infrastructure/auth/auth_token.dart';
import 'package:nightmail/infrastructure/auth/gmail_auth_service.dart';
import 'package:nightmail/infrastructure/auth/microsoft_auth_service.dart';
import 'package:nightmail/infrastructure/auth/token_storage.dart';

/// Exchange, verify, *then* store. A token refused by `verifySignIn` must never
/// reach storage — not even briefly — because the poller builds a fresh
/// datasource for every account every cycle, and a wrong token stored for a
/// moment is a wrong mailbox fetched into this account's cache.
void main() {
  const jsonHeaders = {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  };

  /// A token endpoint that always issues the same fresh token.
  Dio tokenEndpoint() {
    final dio = Dio();
    dio.httpClientAdapter = _StubAdapter((_) async => ResponseBody.fromString(
          jsonEncode({
            'access_token': 'fresh',
            'expires_in': 3600,
            'refresh_token': 'r',
            'token_type': 'Bearer',
            'scope': 'openid',
          }),
          200,
          headers: jsonHeaders,
        ));
    return dio;
  }

  /// Both services, built the same way, so each case runs against each.
  final services = <String,
      Future<AuthToken> Function(
    _RecordingTokenStorage storage,
    Future<void> Function(AuthToken)? verify,
  )>{
    'GmailAuthService': (storage, verify) => GmailAuthService(
          clientId: 'client',
          clientSecret: 'secret',
          redirectUri: 'nightmail://google-auth-callback',
          tokenStorage: storage,
          httpClient: tokenEndpoint(),
          verifySignIn: verify,
        ).exchangeCodeForToken(code: 'code', codeVerifier: 'verifier'),
    'MicrosoftAuthService': (storage, verify) => MicrosoftAuthService(
          clientId: 'client',
          tenantId: 'common',
          redirectUri: 'nightmail://auth-callback',
          tokenStorage: storage,
          httpClient: tokenEndpoint(),
          verifySignIn: verify,
        ).exchangeCodeForToken(code: 'code', codeVerifier: 'verifier'),
  };

  for (final entry in services.entries) {
    group(entry.key, () {
      final exchange = entry.value;

      test('a refused token is never stored', () async {
        final storage = _RecordingTokenStorage();

        await expectLater(
          exchange(storage, (_) async {
            throw const AuthException(message: 'wrong mailbox');
          }),
          throwsA(isA<AuthException>()
              .having((e) => e.message, 'message', 'wrong mailbox')),
        );

        expect(storage.saved, isEmpty);
      });

      test('an accepted token is verified before it is stored, then stored',
          () async {
        final storage = _RecordingTokenStorage();
        AuthToken? verified;

        final token = await exchange(storage, (candidate) async {
          verified = candidate;
          // The whole point: at verification time nothing is on disk yet.
          expect(storage.saved, isEmpty);
        });

        expect(verified?.accessToken, 'fresh');
        expect(storage.saved.single.accessToken, 'fresh');
        expect(token.accessToken, 'fresh');
      });

      test('with no verifier the token is stored as before', () async {
        final storage = _RecordingTokenStorage();

        await exchange(storage, null);

        expect(storage.saved.single.accessToken, 'fresh');
      });
    });
  }
}

/// [TokenStorage] without the keychain: records what would have been written.
class _RecordingTokenStorage extends TokenStorage {
  _RecordingTokenStorage()
      : super(const FlutterSecureStorage(), storageKey: 'token_test');

  final saved = <AuthToken>[];

  @override
  Future<void> saveToken(AuthToken token) async {
    saved.add(token);
  }
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
